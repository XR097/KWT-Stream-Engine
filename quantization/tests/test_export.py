"""Self-contained golden packages must reproduce their saved integer tensors."""
import json

import numpy as np
import pytest

from quantization.export import export_golden, load_profile
from quantization.integer import IntegerEncoder, build_profile, quantize


def _encoder():
    rng = np.random.RandomState(4)
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
    return IntegerEncoder(*build_profile(weights, stats, 8, 8, "max", accumulator_bits=32))


def test_self_contained_golden_integer_inputs_and_binary_roundtrip(tmp_path):
    encoder = _encoder()
    exponent = encoder.exponents["b00.input"]
    samples = np.random.RandomState(8).normal(0, 1, (2, 99, 64)).astype(np.float32)
    # Force clipping, and ties-to-even at positive and negative half-integers.
    samples[0, 0, :6] = np.array([1e4, -1e4, .5, 1.5, -.5, -1.5]) * np.exp2(exponent)
    manifest = export_golden(tmp_path, samples, encoder, {}, exponent)
    assert manifest["status"] == "verified"
    assert manifest["verified_sample_count"] == 2
    assert manifest["reload_bit_exact"] and manifest["repeat_bit_exact"]
    assert manifest["numpy_binary_bit_exact"]
    assert manifest["mac_accumulator_bits"] == 32
    restored = IntegerEncoder(*load_profile(tmp_path / "profile"))
    profile_meta = json.loads((tmp_path / "profile" / "profile.json").read_text())
    for key, spec in profile_meta["arrays"].items():
        binary = np.fromfile(tmp_path / "profile" / spec["binary"], dtype=spec["binary_dtype"]).reshape(spec["shape"])
        np.testing.assert_array_equal(binary, restored.arrays[key])
    for record in manifest["samples"]:
        i = record["index"]
        tensors = {}
        for name, spec in record["tensors"].items():
            a = np.load(tmp_path / spec["npy"], allow_pickle=False)
            b = np.fromfile(tmp_path / spec["binary"], dtype=spec["dtype"]).reshape(spec["shape"])
            np.testing.assert_array_equal(a, b)
            tensors[name] = b
        np.testing.assert_array_equal(tensors["input_int"], quantize(samples[i], exponent, 8))
        actual, _ = restored.run(tensors["input_int"])
        np.testing.assert_array_equal(actual, tensors["output"])
    qi = np.load(tmp_path / "sample_00_input_int.npy")
    np.testing.assert_array_equal(qi[0, :6], [127, -128, 0, 2, 0, -2])


def test_failed_repeat_never_claims_verified(tmp_path, monkeypatch):
    encoder = _encoder()
    original = encoder.run
    calls = [0]

    def nondeterministic(*args, **kwargs):
        output, traces = original(*args, **kwargs)
        calls[0] += 1
        if calls[0] == 2:
            output = output.copy()
            output[0, 0] += 1
        return output, traces

    monkeypatch.setattr(encoder, "run", nondeterministic)
    with pytest.raises(AssertionError, match="repeat mismatch"):
        export_golden(tmp_path, np.zeros((1, 99, 64)), encoder, {}, encoder.exponents["b00.input"])
    manifest = json.loads((tmp_path / "golden_manifest.json").read_text())
    assert manifest["reload_bit_exact"] is False
    assert manifest["status"] == "verification_pending"


def test_rejects_wrong_encoder_boundary_exponent(tmp_path):
    encoder = _encoder()
    with pytest.raises(ValueError, match="exponent"):
        export_golden(tmp_path, np.zeros((1, 99, 64)), encoder, {}, encoder.exponents["b00.input"] + 1)
