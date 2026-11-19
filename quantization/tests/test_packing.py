"""Deployment encodings must be compact, self-contained and checked."""
import json

import numpy as np
import pytest

from quantization.export import (export_golden, export_operator_vectors, load_profile,
                                 pack_int4, save_profile, unpack_int4)
from quantization.hardware import describe_profile
from quantization.integer import IntegerEncoder, build_profile, configure_profile


def _mixed_encoder():
    rng = np.random.RandomState(34)
    weights = {}
    for name, shape in (("q", (64, 64)), ("k", (64, 64)), ("v", (64, 64)),
                        ("proj", (64, 64)), ("fc1", (64, 256)), ("fc2", (256, 64))):
        weights["b00." + name + ".weight"] = rng.normal(0, .05, shape)
        weights["b00." + name + ".bias"] = np.zeros(shape[1])
    for name in ("ln1", "ln2"):
        weights["b00." + name + ".gamma"] = np.ones(64)
        weights["b00." + name + ".beta"] = np.zeros(64)
    names = "input q k v score softmax context proj res1 ln1 fc1 gelu fc2 res2 output".split()
    stats = {"b00." + name: {"max": 8., "p9999": 8.} for name in names}
    p, a = build_profile(weights, stats, 8, 8, "max", accumulator_bits=32)
    p, a = configure_profile(p, a, weights, {
        "weight_bits_by_linear": {"b00.fc1": 4}, "gelu": "middle",
        "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": 11},
        "layernorm": {"norm_frac": 12, "gamma_frac": 16},
    })
    return IntegerEncoder(p, a)


def test_signed_nibble_codes_and_odd_tail():
    all_codes = np.arange(-8, 8, dtype=np.int8).reshape(4, 4)
    packed = pack_int4(all_codes)
    np.testing.assert_array_equal(packed, [0x98, 0xba, 0xdc, 0xfe, 0x10, 0x32, 0x54, 0x76])
    np.testing.assert_array_equal(unpack_int4(packed, all_codes.shape), all_codes)
    odd = np.array([-8, 7, -1], dtype=np.int8)
    np.testing.assert_array_equal(pack_int4(odd), [0x78, 0x0f])
    np.testing.assert_array_equal(unpack_int4(pack_int4(odd), odd.shape), odd)
    with pytest.raises(ValueError, match="tail"):
        unpack_int4(np.array([0x78, 0xff]), (3,))
    with pytest.raises(ValueError, match="size"):
        unpack_int4(np.array([0]), (3,))
    with pytest.raises(ValueError, match="W4"):
        pack_int4(np.array([-9, 8]))


def test_compact_profile_roundtrip_and_binary_only_loader(tmp_path):
    encoder = _mixed_encoder()
    folder = save_profile(tmp_path, "profile", encoder.params, encoder.arrays)
    meta = json.loads((folder / "profile.json").read_text())
    fc1 = meta["arrays"]["b00.fc1.weight"]
    assert fc1["logical_bits"] == 4
    assert fc1["dtype"] == "int8"
    assert (folder / fc1["binary"]).stat().st_size == 64 * 256 // 2
    assert np.load(folder / fc1["file"]).dtype == np.int8
    assert meta["arrays"]["b00.q.bias"]["dtype"] == "int32"
    _, decoded = load_profile(folder)
    for key in encoder.arrays:
        np.testing.assert_array_equal(decoded[key], encoder.arrays[key])
    for spec in meta["arrays"].values():
        (folder / spec["file"]).unlink()
    restored = IntegerEncoder(*load_profile(folder))
    x = np.random.RandomState(7).randint(-20, 21, (99, 64))
    np.testing.assert_array_equal(encoder.run(x)[0], restored.run(x)[0])


@pytest.mark.parametrize("corruption", ["content", "size", "numpy"])
def test_corruption_is_rejected(tmp_path, corruption):
    encoder = _mixed_encoder()
    folder = save_profile(tmp_path, "profile", encoder.params, encoder.arrays)
    meta = json.loads((folder / "profile.json").read_text())
    spec = meta["arrays"]["b00.fc1.weight"]
    if corruption == "numpy":
        value = np.load(folder / spec["file"])
        value[0, 0] ^= 1
        np.save(folder / spec["file"], value)
    else:
        path = folder / spec["binary"]
        value = bytearray(path.read_bytes())
        if corruption == "content":
            value[0] ^= 1
        else:
            value.append(0)
        path.write_bytes(value)
    with pytest.raises(ValueError, match="checksum|size"):
        load_profile(folder)


def test_bias_overflow_refuses_truncation(tmp_path):
    encoder = _mixed_encoder()
    encoder.arrays["b00.q.bias"][0] = 1 << 31
    with pytest.raises(OverflowError, match="bias"):
        save_profile(tmp_path, "profile", encoder.params, encoder.arrays)


def test_v3_golden_traces_and_operator_binary_reload(tmp_path):
    encoder = _mixed_encoder()
    e = encoder.exponents["b00.input"]
    manifest = export_golden(tmp_path / "golden", np.zeros((1, 99, 64)), encoder, {}, e,
                             layer_traces=True)
    assert manifest["status"] == "verified"
    assert manifest["dtype"] == "int8"
    assert manifest["weight_bits_by_linear"]["b00.fc1"] == 4
    assert len(manifest["samples"][0]["layer_traces"]) == 15
    assert (tmp_path / "golden" / "sample_00_input_int.bin").stat().st_size == 99 * 64
    vectors = export_operator_vectors(tmp_path / "operators", encoder)
    assert vectors["status"] == "verified"
    assert vectors["count"] == 9
    assert vectors["reload_bit_exact"]
    gelu_input = vectors["vectors"][0]["tensors"]["input"]
    np.testing.assert_array_equal(np.fromfile(tmp_path / "operators" / gelu_input["binary"], dtype="i1"),
                                  np.arange(-128, 128))


def test_hardware_report_counts_physical_storage_without_fake_area(tmp_path):
    encoder = _mixed_encoder()
    report = describe_profile(encoder.params, encoder.arrays)
    assert report["estimated_area"] is None
    assert report["resource_sharing"]["cycles_per_task"] is None
    assert report["softmax"]["b00"]["division_numerator_unsigned_bits"] == 27
    assert report["softmax"]["b00"]["probability_bits"] == 12
    capacities = report["probability_storage_comparison"]
    assert capacities["16"]["full_matrix"]["tightly_packed_bytes"] == 19602
    assert capacities["8"]["full_matrix"]["tightly_packed_bytes"] == 9801
    assert capacities["12"]["full_matrix"]["word16_aligned_bytes"] == 19602
    folder = save_profile(tmp_path, "profile", encoder.params, encoder.arrays)
    meta = json.loads((folder / "profile.json").read_text())
    deployment = sum((folder / spec["binary"]).stat().st_size
                     for spec in meta["arrays"].values() if not spec["diagnostic"])
    assert report["deployment_binary_bytes"] == deployment
    assert report["weight_binary_bytes"] == 4 * 4096 + 8192 + 16384
    assert report["multiply_accumulate_operations_per_task"] == 99 * 49152 + 2 * 99 * 99 * 64
    observed = describe_profile(encoder.params, encoder.arrays, {
        "mac_required_bits": {"qk": 23},
        "wide_required_bits": {"ln.affine": 28, "ln.rsqrt.mantissa_product": 52}})
    assert observed["observed_width_summary"]["maximum_wide_temporary_signed_bits"] == 52
    assert observed["observed_width_summary"]["newton_and_rsqrt_operators"] == {"ln.rsqrt.mantissa_product": 52}
    json.dumps(report)
