"""Synthetic audit cases; reporting must not require TensorFlow or inference."""
import copy
import hashlib
import json
from pathlib import Path

import pytest

from quantization.scripts import report_hardware_candidates as report


def write(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(value), encoding="utf-8")


def read(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def _macro(words):
    allocated = (words + 127) // 128 * 128
    return {"required_words": words, "allocated_words": allocated,
            "allocated_bytes": allocated * 2, "macros": {"16x128": allocated // 128},
            "port_configuration": "unspecified; capacity example only"}


def _buffer(count, bits):
    return {"elements": count, "logical_bits_per_element": bits,
            "tightly_packed_bytes": (count * bits + 7) // 8,
            "packed_macro_example": _macro((count * bits + 15) // 16),
            "word16_macro_example": _macro(count)}


def _source_tree(tmp_path):
    data, repo = tmp_path / "data", tmp_path / "repo"
    root = data / report.EXPERIMENT
    code = repo / "quantization" / "encoder.py"
    code.parent.mkdir(parents=True)
    code.write_bytes(b"# frozen numerical implementation\n")
    digest = hashlib.sha256(code.name.encode() + code.read_bytes()).hexdigest()
    identity = {"code": digest, "numpy": "1.19.5", "datasets": {}}
    for split in ("training", "validation", "testing"):
        path = data / "cache" / (split + ".npz")
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(("source-" + split).encode())
        identity["datasets"][split] = report.sha256(path)
    for key, path in (("weights", root / "cache" / "weights.npz"),
                      ("validation_full", root / "cache" / "validation_full.npz"),
                      ("calibration", data / "cache" / "calibration.json")):
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_bytes(key.encode())
        identity[key] = report.sha256(path)
    base = data / "profiles" / "W8A8_integer" / "base.bin"
    base.parent.mkdir(parents=True)
    base.write_bytes(b"frozen-base-profile")
    identity["base_profile"] = hashlib.sha256(base.name.encode() + report.sha256(base).encode()).hexdigest()
    write(root / "reports" / "run_identity.json", identity)
    return data, root, repo, identity


def _result(identity, correct=4750, w4=False):
    config = {"gelu": "direct", "weight_bits_by_linear": {"b00.q": 4} if w4 else {},
              "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": 7},
              "layernorm": {"method": "rsqrt", "norm_frac": 12, "gamma_frac": 12}}
    matrix = [[0] * 12 for _ in range(12)]
    matrix[0][0], matrix[0][1] = correct, 4890 - correct
    baseline = 4777 / 4890
    return {"identity": identity, "config": config, "config_id": report.config_id(config),
            "status": "complete", "split": "testing", "count": 4890, "correct": correct,
            "top1": correct / 4890, "float_top1": baseline, "drop_pp": (baseline - correct / 4890) * 100,
            "pass": correct / 4890 >= baseline - .02, "overflow_count": 0,
            "finite_outputs": True, "partial_encoder_timing": False,
            "mac_required_bits": {"b00.q.matmul": 23}, "confusion_matrix": matrix}


def _package(root, result, structure):
    folder = root / "profiles" / (result["config_id"] + "_" + structure)
    folder.mkdir(parents=True)
    entries = 256 if structure == "direct" else 96
    bits = 4 if result["config"]["weight_bits_by_linear"] else 8
    arrays, records = {}, {}
    for key, count, logical_bits, category in (("b00.q.weight", 4, bits, "weights"),
                                                ("gelu.table", entries, 8, "lut"),
                                                ("softmax.exp", 257, 16, "lut")):
        size = (count * logical_bits + 7) // 8
        binary = key + ".bin"
        (folder / binary).write_bytes(bytes(size))
        spec = {"binary": binary, "binary_sha256": report.sha256(folder / binary),
                "binary_bytes": size, "logical_bits": logical_bits, "shape": [count],
                "physical_encoding": "signed_twos_complement_nibbles_low_first" if logical_bits == 4 else "plain",
                "byte_order": "little", "diagnostic": False}
        arrays[key] = spec
        records[key] = dict(spec, category=category, elements=count, deployment=True)
    cfg = {"method": structure, "input_exponent": -4, "output_exponent": -5,
           "minimum_input": -42, "maximum_input": 53, "table_key": "gelu.table"}
    profile = {"format_version": 3, "nonlinear": dict(result["config"], gelu=structure),
               "weight_bits": 8, "weight_bits_by_linear": result["config"]["weight_bits_by_linear"],
               "activation_bits": 8, "accumulator_bits": 32, "residual_accumulator_bits": 32,
               "gelu_configs": {"b00.gelu": cfg}, "arrays": arrays}
    write(folder / "profile.json", profile)
    softmax = {"division_numerator_unsigned_bits": 23, "denominator_unsigned_bits": 22,
               "probability_bits": 8, "full_matrix": _buffer(99 * 99, 8), "one_row": _buffer(99, 8)}
    norm = {"normalization_fraction_bits": 12, "gamma_fraction_bits": 12,
            "gamma_observed_signed_bits": 14, "normalized_domain_bound_signed_bits": 16,
            "affine_product_exact_normalization_signed_bits": 30,
            "variable_denominator_divisions": 0, "integer_square_roots": 0,
            "newton_multiplications": 0, "rsqrt_normalization_multiplications": 6336,
            "affine_multiplications": 6336, "rsqrt_intermediate_domain_bounds": {"mantissa_q30_signed_bits": 33}}
    hw = {"observed": result, "storage": {"arrays": records}, "residual": {}, "mac_operators": [],
          "deployment_binary_bytes": sum(s["binary_bytes"] for s in arrays.values()),
          "weight_binary_bytes": arrays["b00.q.weight"]["binary_bytes"],
          "lut_binary_bytes": arrays["gelu.table"]["binary_bytes"] + arrays["softmax.exp"]["binary_bytes"],
          "softmax": {"b00": softmax}, "layernorm": {"b00.ln1": norm},
          "gelu": {"b00.gelu": {"method": structure, "table_key": "gelu.table", "table_entries": entries,
                                  "online_interpolation_multiplications": 0,
                                  "tail_comparisons_per_element": 2 if structure == "middle" else 0}},
          "resource_sharing": {"one_shared_mac_max_left_bits": 8, "one_shared_mac_max_right_bits": 8,
                               "operand_mode_count": 2 if bits == 4 else 1,
                               "dedicated_operand_types": [{"left_bits": 8, "left_signed": True,
                                                             "right_bits": bits, "right_signed": True}],
                               "arithmetic_instance_count": None, "cycles_per_task": None},
          "observed_width_summary": {"maximum_mac_signed_bits": 23, "maximum_wide_temporary_signed_bits": 44}}
    write(folder / "hardware_requirements.json", hw)
    golden = root / "golden" / (result["config_id"] + "_" + structure)
    manifest = {"status": "verified", "count": 24, "verified_sample_count": 24,
                "reload_bit_exact": True, "repeat_bit_exact": True, "numpy_binary_bit_exact": True,
                "nonlinear": profile["nonlinear"]}
    write(golden / "golden_manifest.json", manifest)
    write(golden / "profile" / "profile.json", profile)
    vectors = {"status": "verified", "count": 8}
    write(golden / "operator_vectors" / "operator_manifest.json", vectors)
    return {"config_id": result["config_id"], "gelu_structure": structure,
            "profile": str(folder), "golden": str(golden), "manifest": manifest, "operator_vectors": vectors}


def fixture(tmp_path, extra=False, correct=4750):
    data, root, repo, identity = _source_tree(tmp_path)
    results = [_result(identity, correct=correct)]
    if extra:
        results.append(_result(identity, correct=4749, w4=True))
    passed = [r for r in results if r["pass"]]
    packages = [_package(root, result, structure) for result in passed for structure in ("direct", "middle")]
    acceptance = {"status": "complete", "identity": identity, "count_per_candidate": 4890,
                  "results": results, "passed": [r["config_id"] for r in passed], "packages": packages}
    write(root / "reports" / "acceptance.json", acceptance)
    return data, root, repo, acceptance


def test_pending_is_not_a_recommendation(tmp_path):
    output = report.generate_report(tmp_path)
    assert output["status"] == "pending"
    assert output["candidates"] == output["representatives"] == []
    assert (tmp_path / report.EXPERIMENT / "reports" / "hardware_candidates.md").is_file()


def test_verified_packages_keep_gelu_table_comparator_tradeoff(tmp_path):
    data, root, repo, acceptance = fixture(tmp_path)
    original = (root / "reports" / "acceptance.json").read_bytes()
    output = report.generate_report(data, repo_root=repo)
    assert output["status"] == "verified", output["errors"]
    assert len(output["candidates"]) == len(output["pareto_candidate_ids"]) == 2
    direct, middle = output["candidates"]
    assert direct["storage"]["gelu_table_binary_bytes"] == 256
    assert middle["storage"]["gelu_table_binary_bytes"] == 96
    assert direct["requirement_axes"]["gelu_tail_comparisons_per_element"] == 0
    assert middle["requirement_axes"]["gelu_tail_comparisons_per_element"] == 2
    assert middle["gelu"]["b00.gelu"]["positive_tail_bypass"]["right_shift"] == -1
    assert direct["accuracy"]["correct"] == 4750
    assert direct["storage"]["lut_logical_bits"] == 256 * 8 + 257 * 16
    assert direct["layernorm"]["maximum_affine_exact_domain_signed_bits"] == 30
    assert direct["observed_widths"]["maximum_wide_temporary_signed_bits"] == 44
    assert direct["softmax"]["per_block"]["b00"]["one_row"]["packed_macro_example"]["macros"]
    assert all(len(r["synthesize_paired_gelu_structures"]) == 2 for r in output["representatives"])
    assert all(c["synthesized_area_mm2"] is None for c in output["candidates"])
    assert (root / "reports" / "acceptance.json").read_bytes() == original
    assert str(Path(acceptance["packages"][0]["profile"]) / "hardware_requirements.json") in output["source_files"]
    md = (root / "reports" / "hardware_candidates.md").read_text(encoding="utf-8")
    assert "150 MHz" in md and "2.25 mm²" in md and "中段表" in md


def test_accuracy_weight_representatives_are_not_one_area_ranking(tmp_path):
    data, root, repo, _ = fixture(tmp_path, extra=True)
    output = report.generate_report(data, repo_root=repo)
    assert output["status"] == "verified", output["errors"]
    rows = {r["candidate_id"]: r for r in output["candidates"]}
    reps = {r["purpose"]: rows[r["selected"]] for r in output["representatives"]}
    assert reps["low_weight_capacity"]["storage"]["weight_binary_bytes"] == 2
    assert reps["higher_accuracy"]["accuracy"]["correct"] == 4750
    assert len(output["pareto_candidate_ids"]) == 4


@pytest.mark.parametrize("mutation,message", [
    (lambda a: a["identity"].update(code="stale"), "identity"),
    (lambda a: a["results"][0].update(count=256), "4890"),
    (lambda a: a["results"][0].update(correct=4751), "correct count"),
    (lambda a: a["results"][0].update({"pass": False}), "pass flag"),
    (lambda a: a["results"][0].update(overflow_count=1), "numeric"),
    (lambda a: a["results"][0]["mac_required_bits"].update({"bad": 33}), "int32"),
    (lambda a: a["packages"].pop(), "package count"),
    (lambda a: a["packages"].append(copy.deepcopy(a["packages"][0])), "package count"),
    (lambda a: a.update(passed=[]), "passed list"),
])
def test_invalid_acceptance_is_rejected(tmp_path, mutation, message):
    data, root, repo, acceptance = fixture(tmp_path)
    mutation(acceptance)
    write(root / "reports" / "acceptance.json", acceptance)
    output = report.generate_report(data, repo_root=repo)
    assert output["status"] == "rejected"
    assert output["candidates"] == output["representatives"] == []
    assert message in output["errors"][0]


@pytest.mark.parametrize("damaged", ["cache", "code", "binary", "hardware", "golden"])
def test_changed_source_sha_and_stale_package_are_rejected(tmp_path, damaged):
    data, root, repo, acceptance = fixture(tmp_path)
    folder = Path(acceptance["packages"][0]["profile"])
    if damaged == "cache":
        (data / "cache" / "testing.npz").write_bytes(b"changed")
    elif damaged == "code":
        (repo / "quantization" / "encoder.py").write_bytes(b"changed")
    elif damaged == "binary":
        (folder / "b00.q.weight.bin").write_bytes(b"\1\0\0\0")
    elif damaged == "hardware":
        path = folder / "hardware_requirements.json"
        hw = read(path)
        hw["observed"]["correct"] += 1
        write(path, hw)
    else:
        path = Path(acceptance["packages"][0]["golden"]) / "golden_manifest.json"
        value = read(path)
        value["reload_bit_exact"] = False
        write(path, value)
    output = report.generate_report(data, repo_root=repo)
    assert output["status"] == "rejected", damaged
    assert output["candidates"] == []


def test_no_accuracy_qualified_configuration_is_explicit(tmp_path):
    data, root, repo, _ = fixture(tmp_path, correct=4600)
    output = report.generate_report(data, repo_root=repo)
    assert output["status"] == "complete_no_qualified_candidates", output["errors"]
    assert output["representatives"] == output["candidates"] == []


def test_pareto_uses_every_axis_and_keeps_equal_requirements():
    first = {"requirement_axes": {key: 2 for key in report.AXES}}
    equal = copy.deepcopy(first)
    worse = {"requirement_axes": {key: 3 for key in report.AXES}}
    assert report.pareto([first, equal, worse]) == [first, equal]
    assert not worse["requirement_pareto"]
