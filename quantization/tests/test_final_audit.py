"""Audit gating, source-only selections and saved-result consistency checks."""
import copy
import json

import numpy as np
import pytest

from quantization.scripts import audit_final_mixed as audit


def _result(config, identity, split, count, mistakes=0):
    labels = np.arange(count) % 12
    predictions = labels.copy()
    predictions[:mistakes] = (predictions[:mistakes] + 1) % 12
    logits = np.eye(12)[predictions]
    correct = int(np.count_nonzero(predictions == labels))
    confusion = np.zeros((12, 12), np.int64)
    np.add.at(confusion, (labels, predictions), 1)
    value = {"config": config, "config_id": audit.config_id(config), "identity": identity,
             "split": split, "count": count, "status": "complete", "overflow_count": 0,
             "finite_outputs": True, "correct": correct, "top1": correct / count,
             "float_top1": 1., "drop_pp": (1. - correct / count) * 100,
             "predictions": predictions.tolist(), "logits": logits.tolist(),
             "confusion_matrix": confusion.tolist(), "partial_encoder_timing": False,
             "diagnostic": True, "trace_errors": {str(i): {} for i in range(180)},
             "mac_required_bits": {"b00.q.matmul": 20},
             "pass": bool(split == "testing" and count == 4890 and mistakes / count <= .02)}
    return value, labels, np.eye(12)[labels]


def _formal(mistakes=1):
    identity = {"code": "frozen"}
    config = {"gelu": "direct", "softmax": {"prob_frac": 11}}
    validation, _, _ = _result(config, identity, "validation_full", 4445)
    frozen = {"identity": identity, "status": "frozen_before_test", "selection_split": "validation_full",
              "full_validation": [validation], "finalists": [copy.deepcopy(validation)],
              "helper_sha256": "external-helper", "coverage": []}
    result, labels, logits = _result(config, identity, "testing", 4890, mistakes)
    acceptance = {"identity": identity, "status": "complete", "count_per_candidate": 4890,
                  "results": [result], "passed": [result["config_id"]] if result["pass"] else []}
    return frozen, acceptance, identity, labels, logits


def test_prepare_is_fixed_labels_only_and_refuses_identity_change(tmp_path):
    cache = tmp_path / "cache"
    cache.mkdir()
    # No predictions or logits exist; source selection needs neither.
    np.savez(cache / "validation.npz", labels=np.repeat(np.arange(12), 2))
    np.savez(cache / "testing.npz", labels=np.arange(4890) % 12)
    identity = {"code": "frozen", "datasets": {
        split: audit.sha256(cache / (split + ".npz")) for split in ("validation", "testing")}}
    identity_path = audit._experiment(tmp_path) / "reports" / "run_identity.json"
    audit.write_json(identity_path, identity)
    record = audit.prepare(tmp_path)
    assert record["testing_predictions_used_for_selection"] is False
    assert record["selections"]["golden"]["count"] == 24
    assert record["selections"]["local600"]["count"] == 600
    assert record["selections"]["local600"]["indices"][:50] == list(range(0, 600, 12))
    assert audit.prepare(tmp_path) == record
    identity["code"] = "changed"
    audit.write_json(identity_path, identity)
    with pytest.raises(AssertionError, match="refusing to overwrite"):
        audit.prepare(tmp_path)


def test_prepare_rejects_insufficient_or_invalid_classes():
    with pytest.raises(AssertionError, match="insufficient"):
        audit.select_per_class(np.arange(11), 1)
    with pytest.raises(AssertionError, match="invalid"):
        audit.select_per_class(np.array([12]), 1)


def test_complete_frozen_validation_and_formal_results_are_accepted():
    frozen, acceptance, identity, labels, logits = _formal()
    metrics = audit.validate_acceptance(acceptance, frozen, identity, labels, logits)
    assert len(metrics) == 1
    assert metrics[0][2] == 4889 / 4890
    assert metrics[0][3] == 1.


@pytest.mark.parametrize("mutation,message", [
    (lambda f: f.update(status="searching"), "not frozen"),
    (lambda f: f["finalists"][0].update(config_id="forged"), "hash mismatch"),
    (lambda f: [r.update(count=500) for r in f["finalists"] + f["full_validation"]], "4445"),
    (lambda f: [r.update(drop_pp=2.5) for r in f["finalists"] + f["full_validation"]], "accuracy gate"),
])
def test_frozen_gate_rejects_invalid_or_subset_records(mutation, message):
    frozen, _, identity, _, _ = _formal()
    mutation(frozen)
    with pytest.raises(AssertionError, match=message):
        audit.validate_frozen(frozen, identity)


@pytest.mark.parametrize("mutation,message", [
    (lambda r: r.update(count=256), "4890"),
    (lambda r: r.update(overflow_count=1), "numeric checks"),
    (lambda r: r.update(finite_outputs=False), "numeric checks"),
    (lambda r: r.update({"pass": False}), "pass flag"),
    (lambda r: r["logits"][0].__setitem__(0, float("nan")), "nonfinite"),
    (lambda r: r["mac_required_bits"].update({"b00.q.matmul": 33}), "int32"),
])
def test_formal_gate_rejects_partial_numeric_or_misleading_results(mutation, message):
    frozen, acceptance, identity, labels, logits = _formal()
    mutation(acceptance["results"][0])
    with pytest.raises(AssertionError, match=message):
        audit.validate_acceptance(acceptance, frozen, identity, labels, logits)


def test_accuracy_failure_is_not_turned_into_pass():
    frozen, acceptance, identity, labels, logits = _formal(mistakes=200)
    assert acceptance["passed"] == []
    assert audit.validate_acceptance(acceptance, frozen, identity, labels, logits)
    acceptance["passed"] = [acceptance["results"][0]["config_id"]]
    with pytest.raises(AssertionError, match="passed list"):
        audit.validate_acceptance(acceptance, frozen, identity, labels, logits)


def test_binary_checksum_and_numpy_mirror_are_checked(tmp_path):
    value = np.arange(12, dtype="<i2").reshape(3, 4)
    value.tofile(tmp_path / "value.bin")
    np.save(tmp_path / "value.npy", value)
    spec = {"binary": "value.bin", "npy": "value.npy", "dtype": "<i2", "shape": [3, 4],
            "byte_order": "little", "binary_sha256": audit.sha256(tmp_path / "value.bin")}
    np.testing.assert_array_equal(audit._tensor(tmp_path, spec), value)
    np.save(tmp_path / "value.npy", value + 1)
    with pytest.raises(AssertionError, match="NumPy/binary mismatch"):
        audit._tensor(tmp_path, spec)
    np.save(tmp_path / "value.npy", value)
    altered = value.copy(); altered[0, 0] = 1
    altered.tofile(tmp_path / "value.bin")
    with pytest.raises(AssertionError, match="checksum"):
        audit._tensor(tmp_path, spec)


def test_golden_gate_rejects_unverified_or_missing_layer_traces(tmp_path):
    manifest = {"status": "verified", "count": 24, "verified_sample_count": 24,
                "layer_traces": True, "numpy_binary_bit_exact": True,
                "repeat_bit_exact": True, "reload_bit_exact": True, "mac_accumulator_bits": 32,
                "samples": [{"index": i, "layer_traces": {}} for i in range(24)]}
    audit.write_json(tmp_path / "golden_manifest.json", manifest)
    package = {"golden": str(tmp_path), "manifest": manifest}
    with pytest.raises(AssertionError, match="180"):
        audit.audit_package(package, {"indices": list(range(24))}, np.zeros((24, 99, 64)), {})
    manifest["reload_bit_exact"] = False
    audit.write_json(tmp_path / "golden_manifest.json", manifest)
    with pytest.raises(AssertionError, match="reload_bit_exact"):
        audit.audit_package(package, {"indices": list(range(24))}, np.zeros((24, 99, 64)), {})
