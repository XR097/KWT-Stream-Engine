"""Orchestration gates must cover all samples and retain whole-run diagnostics."""
import copy
import json
from types import SimpleNamespace

import numpy as np
import pytest

from quantization import experiments as ex


def _fake_worker(monkeypatch, tmp_path, count):
    for name in ("results", "progress", "cache", "reports"):
        (tmp_path / name).mkdir()
    labels = np.arange(count) % 12
    data = {"boundary": labels[:, None, None].astype(np.float32), "labels": labels,
            "float_logits": np.eye(12)[labels]}
    params = {"blocks": ["b00", "b11"], "exponents": {"b00.input": 0, "b11.output": 0}}

    class Encoder:
        calls = 0

        def __init__(self, p, arrays):
            self.params = p

        def run(self, value, trace=False):
            Encoder.calls += 1
            self.last_mac_required_bits = {"linear": 23 if Encoder.calls == 1 else 20}
            self.last_wide_required_bits = {"ln.rsqrt.mantissa_product": 52 if Encoder.calls == 1 else 30}
            self.last_saturation = {"gelu": {"clipped": 2 if Encoder.calls == 1 else 0,
                                               "total": int(value.size)}}
            self.last_residual_stats = {"res1": {"sum": {"minimum": -17, "maximum": 15,
                                                          "required_signed_bits": 6}}}
            return value, {}

    monkeypatch.setattr(ex, "_WORKER", {"experiment": tmp_path, "root": tmp_path,
                                       "base": (params, {}), "weights": {}, "identity": {"code": "test"}})
    monkeypatch.setattr(ex, "_dataset", lambda split: data)
    monkeypatch.setattr(ex, "configure_profile", lambda *args: (copy.deepcopy(params), {}))
    monkeypatch.setattr(ex, "IntegerEncoder", Encoder)
    monkeypatch.setattr(ex, "forward_float", lambda weights, value, trace=False:
                        (value.copy(), {}) if trace else value.copy())
    monkeypatch.setattr(ex, "classify_float", lambda weights, value: np.eye(12)[value[:, 0, 0].astype(int)])
    return Encoder, data


def test_complete_testing_covers_final_short_batch_and_preserves_early_maxima(monkeypatch, tmp_path):
    encoder, _ = _fake_worker(monkeypatch, tmp_path, 4890)
    result = ex._evaluate_job({"config": {}, "split": "testing"})
    assert result["status"] == "complete"
    assert result["count"] == 4890
    assert len(result["predictions"]) == 4890
    assert sum(map(sum, result["confusion_matrix"])) == 4890
    assert result["correct"] == 4890
    assert result["pass"] is True
    assert result["saturation_count"] == 2
    assert result["mac_required_bits"]["linear"] == 23
    assert result["wide_required_bits"]["ln.rsqrt.mantissa_product"] == 52
    assert encoder.calls == 153
    state = json.loads(next((tmp_path / "progress").glob("*.json")).read_text())
    assert state["next_index"] == 4890
    assert len(result["output_hashes"]) == 153


def test_256_smoke_samples_cannot_be_formal_test(monkeypatch, tmp_path):
    encoder, _ = _fake_worker(monkeypatch, tmp_path, 256)
    with pytest.raises(AssertionError, match="4890"):
        ex._evaluate_job({"config": {}, "split": "testing"})
    assert encoder.calls == 0
    assert not list((tmp_path / "results").glob("*.json"))


def test_validation_subset_never_claims_formal_pass(monkeypatch, tmp_path):
    encoder, _ = _fake_worker(monkeypatch, tmp_path, 65)
    result = ex._evaluate_job({"config": {}, "split": "validation"})
    assert result["count"] == 65
    assert result["top1"] == 1
    assert result["pass"] is False
    assert encoder.calls == 3


def test_result_identity_changes_with_numeric_configuration(monkeypatch, tmp_path):
    encoder, _ = _fake_worker(monkeypatch, tmp_path, 1)
    first = ex._evaluate_job({"config": {"gelu": "direct"}, "split": "validation"})
    same = ex._evaluate_job({"config": {"gelu": "direct"}, "split": "validation"})
    assert same["id"] == first["id"]
    assert encoder.calls == 1
    changed = ex._evaluate_job({"config": {"gelu": "middle"}, "split": "validation"})
    assert changed["id"] != first["id"]
    assert encoder.calls == 2
    ex._WORKER["identity"]["code"] = "changed"
    third = ex._evaluate_job({"config": {"gelu": "direct"}, "split": "validation"})
    assert third["id"] != first["id"]
    assert encoder.calls == 3


def test_suffix_reads_saved_integer_prefix_and_marks_partial_timing(monkeypatch, tmp_path):
    encoder, data = _fake_worker(monkeypatch, tmp_path, 65)
    np.savez(tmp_path / "cache" / "prefix_validation.npz", **{
        "b01.input": data["boundary"].astype(np.int8)})
    result = ex._evaluate_job({"config": {}, "split": "validation", "start_block": 1})
    assert result["top1"] == 1
    assert result["partial_encoder_timing"] is True
    assert result["count"] == 65
    assert encoder.calls == 3


def test_softmax_matrix_is_complete_and_does_not_mutate_base():
    base = ex.baseline_config()
    frozen = copy.deepcopy(base)
    variants = ex._softmax_configs(base)
    assert len(variants) == 6
    assert {(c["softmax"]["exp_frac"], c["softmax"]["prob_frac"]) for c in variants} == {
        (ef, pf) for ef in (24, 15) for pf in (15, 11, 7)}
    assert base == frozen
    variants[0]["layernorm"]["norm_frac"] = 12
    assert variants[1]["layernorm"]["norm_frac"] == 20


def test_pareto_requires_all_hardware_axes_and_accuracy_dominance(monkeypatch):
    costs = {"a": (1, 8), "b": (2, 6), "c": (3, 9), "d": (1, 8), "e": (0, 0)}
    monkeypatch.setattr(ex, "_resource_vector", lambda exp, config: costs[config["name"]])
    rows = [{"config_id": name, "config": {"name": name}, "status": "complete", "correct": correct}
            for name, correct in (("a", 98), ("b", 97), ("c", 96), ("d", 99))]
    rows.append({"config_id": "e", "config": {"name": "e"}, "status": "failed", "correct": 100})
    front = ex.pareto_results(None, rows)
    assert {r["config_id"] for r in front} == {"b", "d"}


def test_accuracy_gate_is_two_percentage_points_not_relative_two_percent():
    assert ex._good({"status": "complete", "drop_pp": 2.0})
    assert not ex._good({"status": "complete", "drop_pp": 2.00001})
    assert not ex._good({"status": "failed", "drop_pp": 0.0})


def test_canonical_config_id_ignores_mapping_order():
    assert ex.config_id({"x": 1, "y": {"b": 2, "a": 1}}) == ex.config_id({"y": {"a": 1, "b": 2}, "x": 1})


def test_residual_extrema_merge_keeps_negative_minimum():
    merged = {}
    ex._merge_ranges(merged, {"res1": {"sum": {"minimum": -127, "maximum": 20, "required_signed_bits": 8}}})
    ex._merge_ranges(merged, {"res1": {"sum": {"minimum": -8, "maximum": 64, "required_signed_bits": 8}}})
    assert merged["res1"]["sum"] == {"minimum": -127, "maximum": 64, "required_signed_bits": 8}


def test_nested_stage_identity_rejects_any_stale_result():
    identity = {"code": "current", "data": "frozen"}
    assert ex.validate_saved_identity([{"base": {"result": {"identity": identity}}}], identity) == 1
    with pytest.raises(ValueError, match="identity changed"):
        ex.validate_saved_identity([{"identity": identity}, {"result": {"identity": {"code": "old"}}}], identity)
    assert ex.validate_saved_identity({"config": {"gelu": "direct"}}, identity) == 0


@pytest.mark.parametrize("status,old_identity", [("complete", True), ("running", False)])
def test_report_never_calls_stale_or_running_acceptance_complete(tmp_path, status, old_identity):
    reports = tmp_path / "reports"
    reports.mkdir()
    identity = {"code": "current"}
    (reports / "acceptance.json").write_text(json.dumps({"status": status, "results": [],
        "identity": {"code": "old"} if old_identity else identity}))
    experiment = SimpleNamespace(folder=tmp_path, identity=identity)
    content = ex.write_report(experiment).read_text()
    assert "Experiment is incomplete" in content
    assert "## Complete test results" not in content


def test_final_tests_refuses_empty_frozen_selection(tmp_path):
    (tmp_path / "cache").mkdir()
    np.savez(tmp_path / "cache" / "validation.npz", labels=np.repeat(np.arange(12), 2),
             boundary=np.zeros((24, 99, 64), dtype=np.float32))
    experiment = SimpleNamespace(identity={"code": "current"}, root=tmp_path, folder=tmp_path,
                                 record=lambda *args: None, evaluate=lambda *args, **kwargs: [])
    frozen = {"finalists": [], "identity": experiment.identity, "selection_split": "validation_full"}
    with pytest.raises((ValueError, RuntimeError, AssertionError), match="candidate|finalist|empty|nonempty"):
        ex.final_tests(experiment, frozen)
