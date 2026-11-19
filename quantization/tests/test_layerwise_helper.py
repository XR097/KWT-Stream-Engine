"""Search scheduling may change while the numerical encoder remains frozen."""
import copy
import json
from pathlib import Path
from types import SimpleNamespace

import pytest

from quantization.scripts import search_mixed_layerwise as search


def _config(weight_map=None, fraction=7):
    return {"gelu": "direct", "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": fraction},
            "layernorm": {"method": "rsqrt", "norm_frac": 12, "gamma_frac": 12,
                          "lut_entries": 64, "rsqrt_frac": 16, "iterations": 0},
            "weight_bits_by_linear": weight_map or {}}


def _row(config, identity, split="validation", count=500, correct=495, status="complete"):
    return {"config_id": search.config_id(config), "config": config, "identity": identity,
            "status": status, "split": split, "count": count,
            "correct": correct, "top1": correct / count, "drop_pp": 1., "nrmse": .1}


def _patch_ranking(monkeypatch):
    monkeypatch.setattr(search, "_resource_vector", lambda exp, config: (
        100 - 10 * len(config.get("weight_bits_by_linear", {})),
        config.get("softmax", {}).get("prob_frac", 15),
        len(config.get("softmax_by_block", {})) + len(config.get("layernorm_by_op", {}))))
    monkeypatch.setattr(search, "pareto_results", lambda exp, rows: sorted(rows, key=search._precision_rank))


def test_round_covers_all_12_blocks_before_extras_and_changes_one_operator():
    identity = {"code": "frozen"}
    configs = [_config(fraction=f) for f in (7, 11, 15)]
    configs.append(dict(_config(), gelu="middle"))
    beam = [_row(c, identity) for c in configs]
    original = copy.deepcopy(beam)
    proposals, events = search.propose_round(beam, {r["config_id"] for r in beam}, 0, 16)
    assert len(proposals) == len(events) == 16
    primary = [e for e in events if e["purpose"] == "block_coverage"]
    assert {e["block"] for e in primary} == {"b%02d" % b for b in range(12)}
    assert len({e["parent_config_id"] for e in primary}) == 4
    assert len({search.config_id(c) for c in proposals}) == 16
    parents = {r["config_id"]: r["config"] for r in beam}
    for trial, event in zip(proposals, events):
        parent = parents[event["parent_config_id"]]
        family = "softmax_by_block" if event["action"] == "softmax" else "layernorm_by_op"
        assert {k for k in set(parent) | set(trial) if parent.get(k) != trial.get(k)} == {family}
        assert len(trial[family]) == 1
    assert beam == original


def test_three_rounds_offer_softmax_and_both_norms_for_every_block():
    beam = [_row(_config(), {"code": "x"})]
    seen = {beam[0]["config_id"]}
    pairs = set()
    for turn in range(3):
        _, events = search.propose_round(beam, seen, turn, 16)
        pairs.update((e["block"], e["action"]) for e in events)
    assert pairs == {("b%02d" % b, action) for b in range(12) for action in search.ACTIONS}


def test_legacy_unreported_completions_count_against_64_budget(monkeypatch, tmp_path):
    _patch_ranking(monkeypatch)
    reports, results = tmp_path / "reports", tmp_path / "results"
    reports.mkdir(); results.mkdir()
    identity = {"code": "frozen", "dataset": "same"}
    base = _config()
    global_row = _row(base, identity)
    branch = {"branch": "W8A8", "base": {"config": base, "result": global_row}, "global": [global_row]}
    paths = []
    for block in range(6):
        c = search.mutate_one(base, "b%02d" % block, "softmax")
        path = results / (search.config_id(c) + ".json")
        path.write_text(json.dumps(_row(c, identity)))
        paths.append(path)
    # Stale runs and 256-example smoke tests must not consume this budget.
    for name, row in (("stale", _row(search.mutate_one(base, "b09", "ln1"), {"code": "old"})),
                      ("smoke", _row(search.mutate_one(base, "b10", "ln1"), identity, count=256))):
        path = results / (name + ".json"); path.write_text(json.dumps(row)); paths.append(path)
    evaluated = []

    def evaluate(configs, split):
        evaluated.extend(configs)
        return [_row(c, identity, split) for c in configs]

    experiment = SimpleNamespace(identity=identity, folder=tmp_path, evaluate=evaluate,
                                 record=lambda name, value: (reports / (name + ".json")).write_text(json.dumps(value)))
    all_rows, coverage = search.search_branch(experiment, branch, paths, "helper-sha")
    assert coverage["attempted_configurations"] == 64
    assert len(evaluated) == 58
    assert len({search.config_id(c) for c in evaluated}) == 58
    assert coverage["covered_blocks"] == ["b%02d" % b for b in range(12)]
    assert sum(o["origin"] == "legacy_result_file" for o in coverage["origins"].values()) == 6
    assert len({r["config_id"] for r in all_rows}) == 65  # 64 attempts + unchanged global
    # Matching saved reports now reuse all 64 attempts and evaluate nothing.
    evaluated.clear()
    _, resumed = search.search_branch(experiment, branch, paths, "helper-sha")
    assert resumed["attempted_configurations"] == 64
    assert not evaluated


def test_freezing_retains_global_best_accuracy_and_every_weight_branch(monkeypatch, tmp_path):
    _patch_ranking(monkeypatch)
    identity = {"code": "frozen"}
    records, rows = [], []
    for branch_index in range(3):
        weight = {} if branch_index == 0 else {"b00.fc%d" % branch_index: 4}
        base = _config(weight)
        initial = _row(base, identity, correct=490 + branch_index)
        records.append({"base": {"config": base, "result": initial}})
        for index in range(5):
            c = search.mutate_one(base, "b%02d" % index, "softmax")
            rows.append(_row(c, identity, correct=480 + index + branch_index))
    best_id = rows[4]["config_id"]
    observed_splits = []

    def evaluate(configs, split):
        observed_splits.append(split)
        return [_row(c, identity, split, 4445, 4400 if search.config_id(c) == best_id else 4380)
                for c in configs]

    saved = {}
    experiment = SimpleNamespace(identity=identity, folder=tmp_path, evaluate=evaluate,
                                 record=lambda name, value: saved.update({name: value}))
    frozen = search.freeze_candidates(experiment, records, rows, [], "helper-sha")
    assert observed_splits == ["validation_full"]
    assert len(frozen["full_validation"]) <= 12
    assert 1 <= len(frozen["finalists"]) <= 6
    assert best_id in {r["config_id"] for r in frozen["finalists"]}
    assert {search._weight_map(r["config"]) for r in frozen["finalists"]} == {
        search._weight_map(r["base"]["config"]) for r in records}
    assert frozen["helper_sha256"] == "helper-sha"


def test_freezing_refuses_no_full_validation_pass(monkeypatch, tmp_path):
    _patch_ranking(monkeypatch)
    identity = {"code": "frozen"}
    row = _row(_config(), identity)

    def evaluate(configs, split):
        values = [_row(c, identity, split, 4445) for c in configs]
        for value in values:
            value["drop_pp"] = 3.
        return values

    experiment = SimpleNamespace(identity=identity, folder=tmp_path, evaluate=evaluate,
                                 record=lambda *args: None)
    with pytest.raises(RuntimeError, match="no candidate passes complete validation"):
        search.freeze_candidates(experiment, [{"base": {"config": row["config"]}}], [row], [], "sha")


@pytest.mark.parametrize("fault", ["count", "identity", "split", "missing"])
def test_freezing_rejects_partial_or_mismatched_validation(monkeypatch, tmp_path, fault):
    _patch_ranking(monkeypatch)
    identity = {"code": "frozen"}
    row = _row(_config(), identity)

    def evaluate(configs, split):
        values = [_row(c, identity, split, 4445) for c in configs]
        if fault == "missing":
            return []
        values[0][{"count": "count", "identity": "identity", "split": "split"}[fault]] = {
            "count": 500, "identity": {"code": "old"}, "split": "testing"}[fault]
        return values

    experiment = SimpleNamespace(identity=identity, folder=tmp_path, evaluate=evaluate,
                                 record=lambda *args: None)
    with pytest.raises(RuntimeError, match="all 4445"):
        search.freeze_candidates(experiment, [{"base": {"config": row["config"]}}], [row], [], "sha")
