import os
"""Select genuine W4/W8 validation branches without changing numerical code."""
import argparse
import copy
import hashlib
import json
from pathlib import Path


PATHS = (("conservative", 0, 1.0), ("compressed", 1, 1.5))
LINEARS = {"b%02d.%s" % (block, name) for block in range(12)
           for name in ("q", "k", "v", "proj", "fc1", "fc2")}


def _canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def _config_id(config):
    return hashlib.sha256(_canonical(config).encode()).hexdigest()[:20]


def _sha256(contents):
    return hashlib.sha256(contents).hexdigest()


def _load(path):
    return json.loads(path.read_text(encoding="utf-8"))


def _json_bytes(value):
    return (json.dumps(value, indent=2, sort_keys=True, ensure_ascii=False) + "\n").encode("utf-8")


def _write_atomic(path, contents):
    if path.exists() and path.read_bytes() == contents:
        return False
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_bytes(contents)
    temporary.replace(path)
    return True


def _w4(config):
    mapping = config.get("weight_bits_by_linear", {})
    if set(mapping) - LINEARS or any(bits not in (4, 8) for bits in mapping.values()):
        raise ValueError("Unsupported matrix name or weight precision")
    return sorted(name for name, bits in mapping.items() if bits == 4)


def _validate_result(result, identity):
    if result.get("identity") != identity:
        raise ValueError("Stale validation result: " + str(result.get("config_id")))
    if result.get("config_id") != _config_id(result["config"]):
        raise ValueError("Result config_id does not match its configuration")
    _w4(result["config"])


def _validate_branches(branches, identity):
    if not isinstance(branches, list):
        raise ValueError("weight_branches.json must contain a list")
    for branch in branches:
        _validate_result(branch["result"], identity)
        if branch["config"] != branch["result"]["config"]:
            raise ValueError("Branch configuration differs from its result")


def select_branches(experiment_root, dry_run=False):
    root = Path(experiment_root).resolve()
    reports = root / "reports"
    identity = _load(reports / "run_identity.json")
    combinations_path = reports / "weight_combinations.json"
    branch_path = reports / "weight_branches.json"
    backup_path = reports / "weight_branches_control_selection.json"
    selection_path = reports / "weight_branch_selection.json"
    combination_bytes, branch_bytes = combinations_path.read_bytes(), branch_path.read_bytes()
    combinations = json.loads(combination_bytes.decode("utf-8"))
    branches = json.loads(branch_bytes.decode("utf-8"))
    if not isinstance(combinations, list) or len(combinations) != 64:
        raise ValueError("Expected all 64 alternating conservative/compressed combination results")
    for result in combinations:
        _validate_result(result, identity)
    _validate_branches(branches, identity)
    baseline = [branch for branch in branches if branch["name"] == "W8A8"]
    if len(baseline) != 1:
        raise ValueError("Expected exactly one W8A8 branch")
    baseline = copy.deepcopy(baseline[0])
    base_result = baseline["result"]
    if (_w4(baseline["config"]) or base_result.get("status") != "complete"
            or base_result.get("split") != "validation" or base_result.get("count") != 500):
        raise ValueError("W8A8 baseline must be a complete 500-sample validation result")
    baseline["role"] = "Frozen W8A8 reference; no W4 matrices."
    baseline["selected_paths"] = ["W8A8"]
    selected = [baseline]
    seen = {_config_id(baseline["config"]): baseline}
    choices = {}
    for name, parity, maximum_drop in PATHS:
        candidates = []
        for index in range(parity, len(combinations), 2):
            result = combinations[index]
            count = len(_w4(result["config"]))
            if (result.get("status") == "complete" and result.get("split") == "validation"
                    and result.get("count") == 500 and 0 < count < 72
                    and result.get("drop_pp", float("inf")) <= maximum_drop + 1e-10):
                if (not isinstance(result.get("weight_bytes"), int) or result["weight_bytes"] <= 0
                        or not isinstance(result.get("correct"), int) or not 0 <= result["correct"] <= 500):
                    raise ValueError("Malformed validation storage/accuracy fields")
                candidates.append((index, result))
        if not candidates:
            raise ValueError("No genuine mixed W4/W8 candidate passes the %s validation gate" % name)
        index, best = min(candidates, key=lambda item: (item[1]["weight_bytes"], -item[1]["correct"], item[1]["config_id"]))
        choices[name] = {"maximum_drop_percentage_points": maximum_drop,
                         "path_parity": parity, "path_result_count": len(combinations[parity::2]),
                         "eligible_result_count": len(candidates), "source_combination_index": index,
                         "config_id": best["config_id"], "weight_bytes": best["weight_bytes"],
                         "correct": best["correct"], "count": best["count"], "top1": best["top1"],
                         "drop_pp": best["drop_pp"], "w4_matrices": _w4(best["config"])}
        if best["config_id"] in seen:
            seen[best["config_id"]]["selected_paths"].append(name)
        else:
            branch = {"name": "mixed_" + name, "config": copy.deepcopy(best["config"]), "result": copy.deepcopy(best),
                      "role": "Genuine mixed W4/W8 branch selected only from validation combinations; controls are excluded.",
                      "selected_paths": [name]}
            selected.append(branch)
            seen[best["config_id"]] = branch
    backup_bytes = backup_path.read_bytes() if backup_path.exists() else branch_bytes
    original_branches = json.loads(backup_bytes.decode("utf-8"))
    _validate_branches(original_branches, identity)
    original_base = [b for b in original_branches if b["name"] == "W8A8"]
    if len(original_base) != 1 or original_base[0]["result"]["config_id"] != base_result["config_id"]:
        raise ValueError("Existing original-branch backup belongs to a different baseline")
    if len(selected) < 3:
        controls = [branch for branch in original_branches
                    if len(_w4(branch["config"])) == 72 and branch["result"].get("status") == "complete"
                    and branch["result"].get("split") == "validation" and branch["result"].get("count") == 500]
        if controls:
            control = copy.deepcopy(min(controls, key=lambda branch: (branch["result"]["weight_bytes"],
                                                                      -branch["result"]["correct"],
                                                                      branch["result"]["config_id"])))
            control.update(name="all_w4_control", selected_paths=["all_w4_control"],
                           role="All-W4 compression-extreme control from the original branch report; never replaces a genuine mixed branch.")
            if control["result"]["config_id"] not in seen:
                selected.append(control)
    metadata = {
        "status": "validation_only_branches_selected", "identity": identity,
        "script_sha256": _sha256(Path(__file__).read_bytes()),
        "selection_algorithm": {
            "input": "weight_combinations.json only; even indices conservative, odd indices compressed",
            "required_combination_results": 64, "required_split": "validation", "required_count": 500,
            "required_status": "complete", "allowed_w4_matrix_count": [1, 71],
            "path_drop_limits_percentage_points": {name: drop for name, _, drop in PATHS},
            "ranking": ["weight_bytes ascending", "correct descending", "config_id ascending"],
            "deduplication": "config_id, retaining W8A8 then mixed_conservative then mixed_compressed; selected_paths preserves aliases",
            "control_policy": "Controls never compete with mixed-path selection. When W8A8 plus unique mixed branches number fewer than three, preserve the original all-W4 result as all_w4_control. FFN-W4 and all-W4 measurements also remain in weight_single_validation.json.",
            "test_policy": "No testing result or scale adjustment is used by this selection.",
        },
        "inputs": {"weight_combinations_sha256": _sha256(combination_bytes),
                   "original_branch_backup": backup_path.name,
                   "original_branch_backup_sha256": _sha256(backup_bytes)},
        "path_selections": choices,
        "selected_branches": [{"name": branch["name"], "config_id": branch["result"]["config_id"],
                               "selected_paths": branch["selected_paths"], "w4_matrices": _w4(branch["config"]),
                               "role": branch["role"]} for branch in selected],
        "scope": "Validation branch correction only; numerical results and quantization source fingerprint are unchanged.",
    }
    if not dry_run:
        if not backup_path.exists():
            _write_atomic(backup_path, backup_bytes)
        _write_atomic(branch_path, _json_bytes(selected))
        _write_atomic(selection_path, _json_bytes(metadata))
    return {"dry_run": bool(dry_run), "branch_report": str(branch_path), "backup": str(backup_path),
            "selection_report": str(selection_path), "selected": [
                {"name": b["name"], "config_id": b["result"]["config_id"], "selected_paths": b["selected_paths"],
                 "w4_matrix_count": len(_w4(b["config"])), "weight_bytes": b["result"].get("weight_bytes"),
                 "top1": b["result"].get("top1"), "drop_pp": b["result"].get("drop_pp")}
                for b in selected]}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    parser.add_argument("--experiment-root")
    parser.add_argument("--dry-run", action="store_true")
    args = parser.parse_args()
    root = Path(args.experiment_root) if args.experiment_root else Path(args.data_root) / "experiments" / "w4w8_nonlinear_v1"
    print(json.dumps(select_branches(root, args.dry_run), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
