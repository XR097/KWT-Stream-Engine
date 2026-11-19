"""External audit for frozen mixed-precision experiments (does not alter numerics).

Prepare sample choices before formal testing; audit completed artifacts afterwards.
Only Python/NumPy are required. No training, profile construction, or selection
using test predictions occurs here.
"""
import os
import argparse
import hashlib
import json
from pathlib import Path
import shutil
import subprocess
import sys

import numpy as np


def read_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def write_json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def config_id(config):
    text = json.dumps(config, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()[:20]


def require(condition, message):
    if not condition:
        raise AssertionError(message)


def select_per_class(labels, count):
    labels = np.asarray(labels)
    require(labels.ndim == 1 and np.all((labels >= 0) & (labels < 12)), "invalid source labels")
    selected = []
    for label in range(12):
        indices = np.flatnonzero(labels == label)[:count]
        require(len(indices) == count, "insufficient source samples for class %d" % label)
        selected.extend(indices.tolist())
    return selected


def _experiment(root):
    return Path(root) / "experiments" / "w4w8_nonlinear_v1"


def prepare(root):
    root = Path(root).resolve()
    experiment = _experiment(root)
    identity = read_json(experiment / "reports" / "run_identity.json")
    selections = {}
    # Deliberately access labels only: no test predictions/logits influence choices.
    for name, split, count in (("golden", "validation", 2), ("local600", "testing", 50)):
        path = root / "cache" / (split + ".npz")
        digest = sha256(path)
        require(digest == identity["datasets"][split], "source cache changed: " + split)
        with np.load(path, allow_pickle=False) as archive:
            labels = archive["labels"]
        if split == "testing":
            require(len(labels) == 4890, "formal testing source must contain 4890 samples")
        indices = select_per_class(labels, count)
        selections[name] = {"split": split, "per_class": count, "count": len(indices),
                            "indices": indices, "labels": labels[indices].tolist(),
                            "source_cache": str(path), "source_cache_sha256": digest}
    record = {"schema_version": 1, "identity": identity, "selection_policy": "first indices per class in frozen source order; labels only",
              "testing_predictions_used_for_selection": False, "selections": selections,
              "local600_scope": "local diagnostic only; not the unpublished official 600; formal acceptance uses all 4890"}
    path = experiment / "reports" / "audit_selections.json"
    if path.exists():
        require(read_json(path) == record, "prepared selection/identity changed; refusing to overwrite")
    else:
        write_json(path, record)
    return record


def _matching_identity(record, identity, context):
    require(record.get("identity") == identity, "identity mismatch: " + context)


def validate_frozen(frozen, identity):
    _matching_identity(frozen, identity, "frozen candidates")
    require(frozen.get("status") == "frozen_before_test", "candidates are not frozen before test")
    require(frozen.get("selection_split") == "validation_full", "selection must use complete validation")
    finalists = frozen.get("finalists", [])
    require(bool(finalists), "no frozen finalists")
    full = {}
    for result in frozen.get("full_validation", []):
        require(result.get("config_id") == config_id(result["config"]), "full-validation configuration hash mismatch")
        _matching_identity(result, identity, "full validation")
        full[result["config_id"]] = result
    seen = set()
    for finalist in finalists:
        ident = finalist.get("config_id")
        require(ident == config_id(finalist["config"]), "finalist configuration hash mismatch")
        require(ident not in seen, "duplicate frozen finalist")
        seen.add(ident)
        result = full.get(ident)
        require(result is not None and finalist == result, "finalist is not its matching full-validation record")
        require(result.get("status") == "complete" and result.get("split") == "validation_full"
                and result.get("count") == 4445, "finalist did not complete all 4445 validation samples")
        require(result.get("overflow_count") == 0 and result.get("finite_outputs") is True,
                "finalist validation is not numerically valid")
        require(float(result["drop_pp"]) <= 2. + 1e-10, "finalist failed complete-validation accuracy gate")
    return seen


def _metric(result, labels, float_logits, required_count):
    predictions = np.asarray(result.get("predictions", []))
    logits = np.asarray(result.get("logits", []), dtype=np.float64)
    require(predictions.shape == (required_count,) and predictions.dtype.kind in "iu", "prediction count/type mismatch")
    require(logits.shape == (required_count, 12) and np.all(np.isfinite(logits)), "invalid/nonfinite classifier logits")
    require(np.array_equal(predictions, np.argmax(logits, axis=1)), "predictions disagree with saved logits")
    require(np.all((predictions >= 0) & (predictions < 12)), "invalid prediction class")
    correct = int(np.count_nonzero(predictions == labels))
    top1 = correct / required_count
    float_top1 = float(np.mean(np.argmax(float_logits, axis=1) == labels))
    require(result.get("correct") == correct, "saved correct count mismatch")
    require(abs(float(result["top1"]) - top1) < 1e-12, "saved top1 mismatch")
    require(abs(float(result["float_top1"]) - float_top1) < 1e-12, "saved float top1 mismatch")
    require(abs(float(result["drop_pp"]) - (float_top1 - top1) * 100) < 1e-10, "saved drop mismatch")
    return predictions, top1, float_top1


def validate_acceptance(acceptance, frozen, identity, labels, float_logits):
    ids = validate_frozen(frozen, identity)
    _matching_identity(acceptance, identity, "acceptance")
    require(acceptance.get("status") == "complete" and acceptance.get("count_per_candidate") == 4890,
            "formal acceptance is not complete")
    results = acceptance.get("results", [])
    require(len(results) == len(ids) and {r.get("config_id") for r in results} == ids,
            "formal result set does not match frozen candidates")
    expected_passed, metrics = [], []
    by_id = {r["config_id"]: r for r in frozen["finalists"]}
    for result in results:
        ident = result["config_id"]
        _matching_identity(result, identity, "testing result")
        require(result.get("config") == by_id[ident]["config"] and ident == config_id(result["config"]),
                "testing configuration differs from frozen candidate")
        require(result.get("status") == "complete" and result.get("split") == "testing"
                and result.get("count") == len(labels) == 4890, "formal result does not contain all 4890 samples")
        require(result.get("overflow_count") == 0 and result.get("finite_outputs") is True,
                "formal numeric checks failed")
        require(result.get("partial_encoder_timing") is False, "formal test used a partial encoder")
        require(result.get("diagnostic") is True and len(result.get("trace_errors", {})) == 180,
                "formal per-layer error report incomplete")
        require(bool(result.get("mac_required_bits")) and max(result["mac_required_bits"].values()) <= 32,
                "formal MAC exceeded int32")
        predictions, top1, float_top1 = _metric(result, labels, float_logits, 4890)
        expected = top1 >= float_top1 - .02
        require(result.get("pass") is expected, "formal pass flag is inconsistent with full-test accuracy")
        confusion = np.zeros((12, 12), dtype=np.int64)
        np.add.at(confusion, (labels, predictions), 1)
        require(np.array_equal(result.get("confusion_matrix"), confusion), "formal confusion matrix mismatch")
        if expected:
            expected_passed.append(ident)
        metrics.append((ident, predictions, top1, float_top1))
    require(sorted(acceptance.get("passed", [])) == sorted(expected_passed), "acceptance passed list is inconsistent")
    return metrics


def _tensor(folder, spec):
    path = Path(folder) / spec["binary"]
    require(path.is_file(), "tensor binary missing: " + str(path))
    dtype, shape = np.dtype(spec["dtype"]), tuple(spec["shape"])
    require(path.stat().st_size == int(np.prod(shape)) * dtype.itemsize, "tensor byte count mismatch")
    require(spec.get("byte_order") == "little" and dtype.byteorder != ">", "tensor is not little endian")
    require(sha256(path) == spec.get("binary_sha256"), "tensor checksum mismatch: " + str(path))
    value = np.fromfile(path, dtype=dtype).reshape(shape)
    mirrored = np.load(Path(folder) / spec["npy"], allow_pickle=False)
    require(mirrored.dtype == value.dtype and mirrored.shape == value.shape
            and np.array_equal(mirrored, value), "tensor NumPy/binary mismatch")
    return value


def audit_package(package, golden_selection, validation_boundary, identity):
    folder = Path(package["golden"])
    manifest = read_json(folder / "golden_manifest.json")
    require(manifest == package.get("manifest"), "acceptance embeds stale golden manifest")
    require(manifest.get("status") == "verified" and manifest.get("count") == 24
            and manifest.get("verified_sample_count") == 24, "24 golden samples were not verified")
    for flag in ("layer_traces", "numpy_binary_bit_exact", "repeat_bit_exact", "reload_bit_exact"):
        require(manifest.get(flag) is True, "golden verification flag missing: " + flag)
    require(manifest.get("mac_accumulator_bits") == 32, "golden MAC is not int32")
    samples = manifest.get("samples", [])
    require(len(samples) == 24 and [r.get("index") for r in samples] == list(range(24)), "golden sample ordering mismatch")
    expected_traces = {"b%02d.%s" % (block, name) for block in range(12)
                       for name in "input q k v score softmax context proj res1 ln1 fc1 gelu fc2 res2 output".split()}
    for sample, source_index in zip(samples, golden_selection["indices"]):
        require(set(sample.get("layer_traces", {})) == expected_traces, "golden requires all 180 key traces")
        tensors = {name: _tensor(folder, spec) for name, spec in sample["tensors"].items()}
        require(set(tensors) == {"input", "input_int", "output"}, "golden boundary tensors incomplete")
        require(np.array_equal(tensors["input"], validation_boundary[source_index]), "golden source selection mismatch")
        for value in tensors.values():
            require(value.shape == (99, 64) and np.all(np.isfinite(value)), "invalid golden boundary tensor")
        for spec in sample["layer_traces"].values():
            _tensor(folder, spec)
    vectors_folder = folder / "operator_vectors"
    vectors = read_json(vectors_folder / "operator_manifest.json")
    require(vectors == package.get("operator_vectors"), "acceptance embeds stale operator manifest")
    require(vectors.get("status") == "verified" and vectors.get("count") == len(vectors.get("vectors", [])) == 108,
            "operator vectors must contain 108 cases")
    for flag in ("numpy_binary_bit_exact", "reload_bit_exact"):
        require(vectors.get(flag) is True, "operator verification flag missing: " + flag)
    cases = set()
    for vector in vectors["vectors"]:
        cases.add((vector["key"], vector["case"]))
        for spec in vector["tensors"].values():
            _tensor(vectors_folder, spec)
    expected_cases = set()
    for block in range(12):
        prefix = "b%02d" % block
        expected_cases.add((prefix + ".gelu", "gelu_all_int8"))
        expected_cases.update((prefix + ".softmax", name) for name in ("softmax_uniform", "softmax_extreme"))
        expected_cases.update((prefix + "." + norm, norm + "_" + case)
                              for norm in ("ln1", "ln2") for case in ("zero", "constant", "pattern"))
    require(cases == expected_cases, "operator cases are duplicate or incomplete")
    return {"status": "verified", "identity": identity, "config_id": package["config_id"],
            "golden_selection": golden_selection, "gelu_structure": package["gelu_structure"],
            "source_indices_match_exported_float_inputs": True,
            "golden_manifest_sha256": sha256(folder / "golden_manifest.json"),
            "operator_manifest_sha256": sha256(vectors_folder / "operator_manifest.json")}


RUNTIME_VERIFY = '''"""Verify a golden package using NumPy and copied frozen runtime only."""
import json
from pathlib import Path
import sys
import numpy as np
from quantization.integer import IntegerEncoder
from quantization.export import load_profile

folder = Path(sys.argv[1]).resolve()
manifest = json.loads((folder / "golden_manifest.json").read_text())
encoder = IntegerEncoder(*load_profile(folder / "profile"))
for sample in manifest["samples"]:
    def tensor(spec):
        return np.fromfile(folder / spec["binary"], dtype=spec["dtype"]).reshape(spec["shape"])
    actual, traces = encoder.run(tensor(sample["tensors"]["input_int"]), trace=True)
    np.testing.assert_array_equal(actual, tensor(sample["tensors"]["output"]))
    again, _ = encoder.run(tensor(sample["tensors"]["input_int"]))
    np.testing.assert_array_equal(actual, again)
    for key, spec in sample["layer_traces"].items():
        np.testing.assert_array_equal(traces[key], tensor(spec))
print("Verified %d golden outputs and all layer traces from package binary data" % len(manifest["samples"]))
'''


def _runtime(experiment, repo, identity):
    # Copy, never edit, the exact frozen NumPy implementation. No TF imports.
    digest = hashlib.sha256()
    for path in sorted((Path(repo) / "quantization").glob("*.py")):
        digest.update(path.name.encode()); digest.update(path.read_bytes())
    require(digest.hexdigest() == identity["code"], "current runtime no longer matches frozen source fingerprint")
    runtime = experiment / "runtime"
    package = runtime / "quantization"
    package.mkdir(parents=True, exist_ok=True)
    sources = {}
    for name in ("__init__.py", "integer.py", "export.py"):
        source = Path(repo) / "quantization" / name
        shutil.copyfile(source, package / name)
        sources[name] = sha256(source)
    (runtime / "verify_golden.py").write_text(RUNTIME_VERIFY, encoding="utf-8")
    (runtime / "requirements.txt").write_text("numpy==%s\n" % identity["numpy"], encoding="utf-8")
    (runtime / "README.md").write_text(
        "Frozen integer runtime; requires Python 3.8 and NumPy %s. No TensorFlow or original checkpoint.\n\n"
        "Run `python verify_golden.py <absolute golden package directory>` from this runtime directory.\n"
        "The classification head remains outside the encoder package.\n" % identity["numpy"], encoding="utf-8")
    return runtime, sources


def audit(root, repo):
    root, repo = Path(root).resolve(), Path(repo).resolve()
    experiment = _experiment(root)
    selection_path = experiment / "reports" / "audit_selections.json"
    require(selection_path.is_file(), "run --prepare before formal testing")
    prior = read_json(selection_path)
    selections = prepare(root)  # Rechecks hashes and refuses any changed choice.
    require(prior == selections, "selection changed since prepare")
    identity = selections["identity"]
    require(np.__version__ == identity["numpy"], "audit NumPy version differs from frozen runtime")
    frozen_path, acceptance_path = [experiment / "reports" / (name + ".json")
                                    for name in ("frozen_candidates", "acceptance")]
    frozen, acceptance = read_json(frozen_path), read_json(acceptance_path)
    with np.load(root / "cache" / "testing.npz", allow_pickle=False) as source:
        labels, float_logits = source["labels"], source["float_logits"]
    with np.load(root / "cache" / "validation.npz", allow_pickle=False) as source:
        boundary = source["boundary"]
    full_path = experiment / "cache" / "validation_full.npz"
    require(sha256(full_path) == identity["validation_full"], "complete validation cache changed")
    validate_frozen(frozen, identity)
    with np.load(full_path, allow_pickle=False) as source:
        require(len(source["labels"]) == 4445, "complete validation cache count changed")
        for finalist in frozen["finalists"]:
            _metric(finalist, source["labels"], source["float_logits"], 4445)
    metrics = validate_acceptance(acceptance, frozen, identity, labels, float_logits)
    expected_packages = {(ident, structure) for ident in acceptance["passed"] for structure in ("direct", "middle")}
    packages = acceptance.get("packages", [])
    require(len(packages) == len(expected_packages) and
            {(p["config_id"], p["gelu_structure"]) for p in packages} == expected_packages,
            "passing candidates need direct and middle golden packages")
    by_id = {r["config_id"]: r["config"] for r in acceptance["results"]}
    for package in packages:
        expected_config = dict(by_id[package["config_id"]], gelu=package["gelu_structure"])
        profile = read_json(Path(package["golden"]) / "profile" / "profile.json")
        require(profile.get("nonlinear") == expected_config and
                package["manifest"].get("nonlinear") == expected_config,
                "golden deployment profile differs from frozen candidate/declared GELU structure")
        require(profile.get("accumulator_bits") == 32 and profile.get("activation_bits") == 8,
                "golden deployment profile changed A8/int32 semantics")
    provenance = [(Path(p["golden"]), audit_package(p, selections["selections"]["golden"], boundary, identity))
                  for p in packages]
    runtime, sources = _runtime(experiment, repo, identity)
    # Run from copied source so package replay has no dependency on repository imports.
    for folder, record in provenance:
        subprocess.run([sys.executable, str(runtime / "verify_golden.py"), str(folder)],
                       cwd=str(runtime), check=True)
        record.update(runtime=str(runtime), runtime_source_sha256=sources,
                      copied_runtime_replay_bit_exact=True)
    local_indices = selections["selections"]["local600"]["indices"]
    addendum = []
    for ident, predictions, top1, float_top1 in metrics:
        def subset(indices):
            actual, expected = predictions[indices], labels[indices]
            fp = np.argmax(float_logits[indices], axis=1)
            return {"count": len(expected), "correct": int(np.count_nonzero(actual == expected)),
                    "top1": float(np.mean(actual == expected)), "float_top1": float(np.mean(fp == expected)),
                    "drop_pp": float((np.mean(fp == expected) - np.mean(actual == expected)) * 100),
                    "prediction_agreement_float": float(np.mean(actual == fp))}
        addendum.append({"config_id": ident, "formal4890": subset(np.arange(4890)),
                         "historical_first4800": subset(np.arange(4800)),
                         "local600": subset(np.asarray(local_indices)),
                         "formal_pass": top1 >= float_top1 - .02})
    report = {"status": "verified", "identity": identity, "results": addendum,
              "formal_acceptance_count": 4890, "accuracy_pass": bool(acceptance["passed"]),
              "local600_scope": selections["local600_scope"],
              "selection_manifest_sha256": sha256(selection_path),
              "frozen_candidates_sha256": sha256(frozen_path), "acceptance_sha256": sha256(acceptance_path),
              "runtime": str(runtime), "runtime_source_sha256": sources,
              "packages_verified": len(provenance)}
    # No success artifacts are emitted until every candidate/package check passes.
    for folder, record in provenance:
        write_json(folder / "provenance.json", record)
    write_json(experiment / "reports" / "testing_metrics_addendum.json", report)
    return report


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    parser.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    action = parser.add_mutually_exclusive_group(required=True)
    action.add_argument("--prepare", action="store_true")
    action.add_argument("--audit", action="store_true")
    args = parser.parse_args(argv)
    result = prepare(args.data_root) if args.prepare else audit(args.data_root, args.repo_root)
    print(json.dumps({"status": result.get("status", "selection_prepared"),
                      "accuracy_pass": result.get("accuracy_pass"),
                      "packages_verified": result.get("packages_verified")}, sort_keys=True))


if __name__ == "__main__":
    main()
