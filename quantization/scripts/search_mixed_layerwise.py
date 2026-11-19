"""Coverage-correct joint search using the frozen numerical experiment engine.

This changes search scheduling only. It never changes quantization source or
uses the testing partition to select candidates.
"""
import argparse
import copy
import hashlib
import json
import os
from pathlib import Path
import sys

for _name in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_name, "1")
os.environ.setdefault("CUDA_VISIBLE_DEVICES", "-1")
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

import numpy as np

from quantization.experiments import (
    Experiment, canonical, config_id, pareto_results, _resource_vector, _good,
    _precision_rank, validate_saved_identity, write_report,
)


ACTIONS = ("softmax", "ln1", "ln2")
MAX_LAYERWISE = 64
POLICY = {
    "beam_width": 4, "rounds": 4, "max_new_configurations_per_branch": MAX_LAYERWISE,
    "primary_schedule": "Each round: one action for each of 12 blocks; parent=(block+round)%beam_size; action=(block+round)%3.",
    "supplementary_schedule": "Up to four additional distinct single-operator changes per round.",
    "selection": "Complete validation only; mandatory weight branches and best accuracy before truncation; numerical hardware Pareto requirements, not area.",
    "testing_used_for_selection": False,
}


def _read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _write(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def _weight_map(config):
    return canonical(config.get("weight_bits_by_linear", {}))


def changed_blocks(config):
    result = set(config.get("softmax_by_block", {}))
    result.update(key.split(".")[0] for key in config.get("layernorm_by_op", {}))
    return sorted(result)


def mutate_one(config, block, action):
    """Change exactly one resolved operator, retaining all other overrides."""
    trial = copy.deepcopy(config)
    if action == "softmax":
        current = dict(config.get("softmax", {}))
        current.update(config.get("softmax_by_block", {}).get(block, {}))
        fraction = int(current.get("prob_frac", 15))
        current["prob_frac"] = {7: 11, 11: 15, 15: 7}[fraction]
        trial.setdefault("softmax_by_block", {})[block] = current
    elif action in ("ln1", "ln2"):
        key = block + "." + action
        current = dict(config.get("layernorm", {}))
        current.update(config.get("layernorm_by_op", {}).get(key, {}))
        was_reference = current.get("method", "reference") == "reference"
        was_full = current.get("norm_frac", 20) == 20 and current.get("gamma_frac", 20) == 20
        current.update(method="reference", norm_frac=12 if was_reference and was_full else 20,
                       gamma_frac=12 if was_reference and was_full else 20)
        trial.setdefault("layernorm_by_op", {})[key] = current
    else:
        raise ValueError("unknown layerwise action: " + action)
    return trial


def choose_beam(experiment, population):
    complete = {r["config_id"]: r for r in population if r["status"] == "complete"}
    good = [r for r in complete.values() if _good(r, 2.)]
    candidates = good or list(complete.values())
    if not candidates:
        raise RuntimeError("no numerically valid candidate to seed layerwise search")
    selected = pareto_results(experiment, candidates)[:2] + sorted(candidates, key=_precision_rank)[:2]
    selected += sorted(candidates, key=_precision_rank)
    return list({r["config_id"]: r for r in selected}.values())[:4]


def collect_existing(experiment, branch, result_files):
    """Count prior completed attempts, including jobs interrupted before report."""
    entries, origins = {}, {}
    stage_path = experiment.folder / "reports" / ("joint_" + branch["branch"] + ".json")
    if stage_path.exists():
        values = _read(stage_path)
        try:
            matching = bool(validate_saved_identity(values, experiment.identity))
        except ValueError:
            matching = False
        if matching:
            for value in values:
                if _weight_map(value["config"]) == _weight_map(branch["base"]["config"]):
                    entries[value["config_id"]] = value
                    origins[value["config_id"]] = {"origin": "joint_report", "path": str(stage_path)}
    for path in result_files:
        value = _read(path)
        config = value.get("config", {})
        if (value.get("identity") != experiment.identity or value.get("split") != "validation"
                or value.get("count") != 500 or value.get("status") not in ("complete", "failed")
                or not changed_blocks(config)
                or _weight_map(config) != _weight_map(branch["base"]["config"])):
            continue
        ident = value.get("config_id", config_id(config))
        if ident != config_id(config):
            raise ValueError("cached configuration ID mismatch: " + str(path))
        entries.setdefault(ident, value)
        origins.setdefault(ident, {"origin": "legacy_result_file", "path": str(path)})
    if len(entries) > MAX_LAYERWISE:
        raise RuntimeError("existing layerwise configurations already exceed the 64-configuration budget")
    return list(entries.values()), origins


def propose_round(beam, seen, turn, limit):
    """Cover all blocks first; extras never displace a primary block."""
    proposals, events = [], []

    def add(block_index, action_index, parent_index, purpose):
        block = "b%02d" % block_index
        # Duplicate combinations are skipped; try another action/parent while
        # keeping this block covered before allocating supplementary work.
        for action_offset in range(3):
            for parent_offset in range(len(beam)):
                parent = beam[(parent_index + parent_offset) % len(beam)]
                action = ACTIONS[(action_index + action_offset) % 3]
                trial = mutate_one(parent["config"], block, action)
                ident = config_id(trial)
                if ident in seen:
                    continue
                seen.add(ident)
                proposals.append(trial)
                events.append({"config_id": ident, "parent_config_id": parent["config_id"],
                               "block": block, "action": action, "round": turn,
                               "origin": "coverage_helper", "purpose": purpose})
                return

    for block in range(12):
        if len(proposals) >= limit:
            break
        add(block, (block + turn) % 3, (block + turn) % len(beam), "block_coverage")
    for extra in range(4):
        if len(proposals) >= limit:
            break
        block = (turn * 3 + extra * 3) % 12
        add(block, (block + turn + 1) % 3, (extra + turn) % len(beam), "supplementary")
    return proposals, events


def search_branch(experiment, branch, result_files, helper_hash):
    existing, origins = collect_existing(experiment, branch, result_files)
    initial = [r for r in branch["global"] if r["status"] == "complete"]
    tried = list(existing)
    seen = {r["config_id"] for r in initial + tried}
    events = []
    coverage_path = experiment.folder / "reports" / ("joint_coverage_" + branch["branch"] + ".json")
    if coverage_path.exists():
        saved = _read(coverage_path)
        if saved.get("identity") == experiment.identity and saved.get("helper_sha256") == helper_hash:
            events = saved.get("events", [])
    beam = choose_beam(experiment, initial + tried)
    for turn in range(4):
        remaining = MAX_LAYERWISE - len(tried)
        if not remaining:
            break
        proposals, proposed_events = propose_round(beam, seen, turn, min(16, remaining))
        if not proposals:
            continue
        results = experiment.evaluate(proposals, "validation")
        if len(results) != len(proposals):
            raise RuntimeError("evaluation returned an incomplete proposal set")
        for result in results:
            if result.get("identity") != experiment.identity:
                raise ValueError("evaluation identity mismatch")
            origins.setdefault(result["config_id"], {"origin": "coverage_helper", "round": turn})
        tried.extend(results)
        events.extend(proposed_events)
        tried = list({r["config_id"]: r for r in tried}.values())
        if len(tried) > MAX_LAYERWISE:
            raise AssertionError("layerwise budget exceeded")
        experiment.record("joint_" + branch["branch"], tried)
        covered = set(b for r in tried for b in changed_blocks(r["config"]))
        _write(coverage_path, {"identity": experiment.identity, "helper_sha256": helper_hash,
                              "branch": branch["branch"], "events": events, "origins": origins,
                              "attempted_configurations": len(tried), "budget": MAX_LAYERWISE,
                              "covered_blocks": sorted(covered), "policy": POLICY})
        beam = choose_beam(experiment, initial + tried)
    covered = set(b for r in tried for b in changed_blocks(r["config"]))
    if covered != {"b%02d" % b for b in range(12)}:
        raise RuntimeError("layerwise budget exhausted before all 12 blocks were covered: " + branch["branch"])
    return initial + tried + [branch["base"]["result"]], {
        "branch": branch["branch"], "attempted_configurations": len(tried),
        "budget": MAX_LAYERWISE, "covered_blocks": sorted(covered),
        "events": events, "origins": origins,
    }


def freeze_candidates(experiment, records, combined, coverage, helper_hash):
    good = [r for r in combined if _good(r, 2.)]
    if not good:
        raise RuntimeError("no candidate passes validation-subset accuracy gate")
    mandatory = [min(good, key=_precision_rank)]
    for branch in records:
        group = [r for r in good if _weight_map(r["config"]) == _weight_map(branch["base"]["config"])]
        if group:
            mandatory.extend([min(group, key=_precision_rank),
                              min(group, key=lambda r: (_resource_vector(experiment, r["config"]), -r["correct"]))])
    nominated = mandatory + pareto_results(experiment, good)[:6] + sorted(good, key=_precision_rank)[:3]
    nominated = list({r["config_id"]: r for r in nominated}.values())[:12]
    full = experiment.evaluate([r["config"] for r in nominated], "validation_full")
    if (len(full) != len(nominated)
            or {r["config_id"] for r in full} != {r["config_id"] for r in nominated}
            or any(r.get("identity") != experiment.identity or r.get("split") != "validation_full" for r in full)
            or any(r.get("status") == "complete" and r.get("count") != 4445 for r in full)):
        raise RuntimeError("complete validation must evaluate every candidate on all 4445 samples")
    full_good = [r for r in full if _good(r, 2.)]
    if not full_good:
        raise RuntimeError("no candidate passes complete validation; no formal test acceptance is possible")
    finalists = [min(full_good, key=_precision_rank)]
    for branch in records:
        group = [r for r in full_good if _weight_map(r["config"]) == _weight_map(branch["base"]["config"])]
        if group:
            finalists.append(min(group, key=lambda r: (_resource_vector(experiment, r["config"]), -r["correct"])))
    finalists += pareto_results(experiment, full_good)[:3]
    finalists = list({r["config_id"]: r for r in finalists}.values())[:6]
    frozen = {"status": "frozen_before_test", "selection_split": "validation_full",
              "full_validation": full, "finalists": finalists, "identity": experiment.identity,
              "helper_sha256": helper_hash, "helper": str(Path(__file__).resolve()),
              "coverage": coverage, "selection_policy": POLICY,
              "equivalent_gelu_structures": ["direct", "middle"],
              "scope": "software Pareto requirements; not synthesized area"}
    experiment.record("frozen_candidates", frozen)
    return frozen


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    parser.add_argument("--workers", type=int, default=4, choices=range(1, 9))
    parser.add_argument("--resume", action="store_true")
    args = parser.parse_args(argv)
    experiment = Experiment(args)
    try:
        helper_hash = hashlib.sha256(Path(__file__).read_bytes()).hexdigest()
        branches = _read(experiment.folder / "reports" / "weight_branches.json")
        if not validate_saved_identity(branches, experiment.identity):
            raise ValueError("weight branch report has no identity")
        records = [_read(experiment.folder / "reports" / ("nonlinear_" + branch["name"] + ".json")) for branch in branches]
        if not validate_saved_identity(records, experiment.identity):
            raise ValueError("nonlinear reports have no identity")
        if len(records) != 3:
            raise ValueError("expected three completed weight branches")
        with np.load(experiment.folder / "cache" / "validation_full.npz") as data:
            if len(data["labels"]) != 4445:
                raise ValueError("full validation cache must contain 4445 samples")
        result_files = sorted((experiment.folder / "results").glob("*.json"))
        experiment.record("frozen_candidates", {"status": "searching", "finalists": [],
                          "identity": experiment.identity, "helper_sha256": helper_hash})
        combined, coverage = [], []
        for record in records:
            values, summary = search_branch(experiment, record, result_files, helper_hash)
            combined.extend(values); coverage.append(summary)
        freeze_candidates(experiment, records, combined, coverage, helper_hash)
    finally:
        write_report(experiment)
        experiment.close()


if __name__ == "__main__":
    main()
