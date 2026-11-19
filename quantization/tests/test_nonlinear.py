"""Mixed W4/W8 and fixed-point nonlinear configuration boundaries."""
import copy
import numpy as np
import pytest

from quantization.integer import (IntegerEncoder, build_profile, configure_profile,
    checked_matmul, dequantize, saturate, shift_rne, _maxabs, signed_bits)


def fixture_profile():
    rng = np.random.RandomState(17)
    weights = {}
    for name, shape in (("q", (64, 64)), ("k", (64, 64)), ("v", (64, 64)),
                        ("proj", (64, 64)), ("fc1", (64, 256)), ("fc2", (256, 64))):
        weights["b00." + name + ".weight"] = rng.normal(0, .03, shape)
        weights["b00." + name + ".bias"] = rng.normal(0, .005, shape[-1])
    for name in ("ln1", "ln2"):
        weights["b00." + name + ".gamma"] = rng.uniform(.8, 1.2, 64)
        weights["b00." + name + ".beta"] = rng.normal(0, .01, 64)
    stats = {"b00." + name: {"max": 7., "p9999": 7.} for name in
             "input q k v score softmax context proj res1 ln1 fc1 gelu fc2 res2 output".split()}
    params, arrays = build_profile(weights, stats, 8, 8)
    params["exponents"]["b00.score"] = -4
    params["exponents"]["b00.fc1"] = -4
    params["exponents"]["b00.gelu"] = -4
    return params, arrays, weights


def configured(config):
    p, a, w = fixture_profile()
    p, a = configure_profile(p, a, w, config)
    return IntegerEncoder(p, a)


def test_mac_cancellation_fallback_checks_every_prefix():
    m = (1 << 31) - 1
    np.testing.assert_array_equal(checked_matmul(np.array([[m, -m]]),
        np.ones((2, 1), dtype=np.int64), bits=32), [[0]])
    with pytest.raises(OverflowError, match="prefix"):
        checked_matmul(np.array([[m, m, -m]]), np.ones((3, 1), dtype=np.int64), bits=32)
    a = np.array([[[m, -m]], [[-m, m]]])
    np.testing.assert_array_equal(checked_matmul(a, np.ones((2, 1), np.int64), bits=32), [[[0]], [[0]]])


def test_int32_minimum_absolute_and_signed_width_diagnostics():
    minimum = np.array([-(1 << 31)], dtype=np.int32)
    assert _maxabs(minimum) == 1 << 31
    assert signed_bits(minimum) == 32
    assert _maxabs(np.array([-(1 << 31), (1 << 31) - 1], np.int32)) == 1 << 31
    assert signed_bits(np.array([-(1 << 31), (1 << 31) - 1], np.int32)) == 32


def test_int32_minimum_linear_and_residual_statistics():
    enc = configured({})
    enc.arrays["b00.q.weight"] = np.ones((64, 64), np.int64)
    enc.arrays["b00.q.bias"] = np.zeros(64, np.int64)
    x = np.zeros((1, 64), np.int64)
    x[0, 0] = -(1 << 31)
    enc._linear(x, "b00.q", None)
    assert enc.last_mac_required_bits["b00.q.matmul"] == 32
    assert enc.last_mac_required_bits["b00.q.accumulator"] == 32
    assert enc.last_stats["b00.q.accumulator"]["maximum_abs"] == 1 << 31
    enc.exponents.update({"edge_x": 0, "edge_y": 0, "edge_sum": 0})
    enc._residual(np.array([-(1 << 31)], np.int32), "edge_x",
                  np.array([0], np.int32), "edge_y", "edge_sum", None)
    stats = enc.last_residual_stats["edge_sum"]["sum"]
    assert stats["maximum_abs"] == 1 << 31
    assert stats["required_signed_bits"] == 32
    assert enc.last_overflow_count == 0


def test_residual_checked_int32_and_legacy_default():
    enc = configured({})
    enc.exponents.update({"x": 0, "y": 0, "z": 0})
    np.testing.assert_array_equal(enc._residual(np.array([-128, 127]), "x",
        np.array([-128, 127]), "y", "z", None), [-128, 127])
    assert enc.last_residual_stats["z"]["sum"]["required_signed_bits"] == 9
    with pytest.raises(OverflowError, match="int32"):
        enc._residual(np.array([1 << 31]), "x", np.array([-(1 << 31)]), "y", "z", None)
    assert enc.last_overflow_count == 1
    p = copy.deepcopy(enc.params)
    p.pop("residual_accumulator_bits")
    assert IntegerEncoder(p, enc.arrays).residual_accumulator_bits == 64


def test_w4_builder_and_frozen_exponents_and_bias_reencoding():
    p, a, w = fixture_profile()
    cp, ca = configure_profile(p, a, w, {"weight_bits_by_linear": {"b00.fc1": 4}})
    assert cp["linears"]["b00.fc1"]["weight_bits"] == 4
    assert cp["linears"]["b00.q"]["weight_bits"] == 8
    assert ca["b00.fc1.weight"].min() >= -8
    assert ca["b00.fc1.weight"].max() <= 7
    np.testing.assert_array_equal(ca["b00.fc1.bias"], np.rint(
        w["b00.fc1.bias"] / np.exp2(ca["b00.fc1.weight_exponents"] + p["exponents"]["b00.ln1"])))
    assert p["format_version"] == 2
    assert cp["exponents"] == p["exponents"]
    for k in a:
        assert not np.shares_memory(a[k], ca[k])


@pytest.mark.parametrize("output_exp,expected_entries", [(-4, 71), (-5, 79)])
@pytest.mark.parametrize("method", ["direct", "middle"])
def test_gelu_exhaustive_equivalence_and_saturation(output_exp, expected_entries, method):
    p, a, w = fixture_profile()
    p["exponents"]["b00.gelu"] = output_exp
    reference = IntegerEncoder(p, a)
    cp, ca = configure_profile(p, a, w, {"gelu": method})
    enc = IntegerEncoder(cp, ca)
    x = np.arange(-128, 128, dtype=np.int64)
    raw = reference.gelu(x, -4, output_exp)
    final = enc.gelu(x, -4, output_exp, "b00.gelu")
    np.testing.assert_array_equal(final, saturate(raw, 8))
    enc._store("b00.gelu", final, None)
    assert enc.last_stats["b00.gelu"]["saturated"] == int(np.count_nonzero((raw < -128) | (raw > 127)))
    cfg = cp["gelu_configs"]["b00.gelu"]
    assert ca[cfg["table_key"]].size == (256 if method == "direct" else expected_entries)
    assert cfg["presat_key"] in cp["diagnostic_arrays"]


@pytest.mark.parametrize("exponent", [-2, -3, -4])
def test_softmax_compact_all_reachable_differences(exponent):
    p, a, w = fixture_profile()
    x = np.stack((np.zeros(256, np.int64), -np.arange(256, dtype=np.int64)), axis=-1)
    ref = IntegerEncoder(p, a).softmax(x, exponent)
    cp, ca = configure_profile(p, a, w, {"softmax": {"table": "compact"}})
    enc = IntegerEncoder(cp, ca)
    np.testing.assert_array_equal(enc.softmax(x, exponent, "b00.softmax"), ref)
    assert ca[cp["softmax_configs"]["b00"]["table_key"]].size == 257


@pytest.mark.parametrize("frac", [15, 11, 7])
def test_softmax_probability_endpoints_and_context_exponent(frac):
    enc = configured({"softmax": {"table": "compact", "exp_frac": 15, "prob_frac": frac}})
    y = enc.softmax(np.array([[127, -128, -128]], np.int64), -2, "b00.softmax")
    np.testing.assert_array_equal(y, [[1 << frac, 0, 0]])
    assert enc.exponents["b00.softmax"] == -frac
    table = enc.arrays[enc.params["softmax_configs"]["b00"]["table_key"]]
    assert int(table.max()) == 32768
    assert enc.last_wide_required_bits["b00.softmax.numerator"] <= 32


@pytest.mark.parametrize("norm_frac", [20, 16, 12])
@pytest.mark.parametrize("gamma_frac", [20, 16, 12])
def test_layernorm_separate_precision_and_epsilon(norm_frac, gamma_frac):
    p, a, w = fixture_profile()
    cp, ca = configure_profile(p, a, w, {"layernorm": {"norm_frac": norm_frac, "gamma_frac": gamma_frac}})
    enc = IntegerEncoder(cp, ca)
    assert cp["norms"]["b00.ln1"]["epsilon_q24"] == 17
    x = np.random.RandomState(8).randint(-128, 128, (8, 64)).astype(np.int64)
    y = enc.layernorm(x, "b00.ln1")
    if norm_frac == gamma_frac == 20:
        np.testing.assert_array_equal(y, IntegerEncoder(p, a).layernorm(x, "b00.ln1"))
    constant = np.full((2, 64), 17, dtype=np.int64)
    np.testing.assert_array_equal(enc.layernorm(constant, "b00.ln1"),
        np.broadcast_to(ca["b00.ln1.beta"], constant.shape))


@pytest.mark.parametrize("entries", [64, 256])
@pytest.mark.parametrize("frac", [16, 20])
@pytest.mark.parametrize("iterations", [0, 1])
def test_rsqrt_layernorm_constant_low_variance_and_range(entries, frac, iterations):
    enc = configured({"layernorm": {"method": "rsqrt", "lut_entries": entries,
                       "rsqrt_frac": frac, "iterations": iterations, "norm_frac": 16, "gamma_frac": 16}})
    x = np.random.RandomState(8).randint(-128, 128, (8, 64)).astype(np.int64)
    x[0] = 10
    x[1] = 0
    x[1, 0] = 1
    y = enc.layernorm(x, "b00.ln1")
    np.testing.assert_array_equal(y[0], enc.arrays["b00.ln1.beta"])
    xf = dequantize(x, enc.exponents["b00.res1"])
    _, _, w = fixture_profile()
    expected = (xf - xf.mean(-1, keepdims=True)) / np.sqrt(xf.var(-1, keepdims=True) + 1e-6)
    expected = expected * w["b00.ln1.gamma"] + w["b00.ln1.beta"]
    # Preserve the reference variance path: an integer variance below 1/2
    # rounds to zero before Q24 conversion. Low-variance behavior is therefore
    # checked against that frozen path, not a silently improved float variance.
    np.testing.assert_allclose(dequantize(y[2:], enc.exponents["b00.ln1"]), expected[2:], atol=.08, rtol=0)
    original = configured({"layernorm": {"norm_frac": 16, "gamma_frac": 16}})
    np.testing.assert_allclose(y[1], original.layernorm(x[1], "b00.ln1"), atol=40, rtol=.05)
    assert all(v <= 64 for v in enc.last_wide_required_bits.values())


def test_profile_override_per_operator_and_encoder_repeat():
    enc = configured({"gelu": "middle", "softmax": {"table": "compact", "exp_frac": 15},
        "softmax_by_block": {"b00": {"prob_frac": 7}},
        "layernorm_by_op": {"b00.ln2": {"method": "rsqrt", "iterations": 1}}})
    x = np.random.RandomState(2).randint(-128, 128, (99, 64)).astype(np.int64)
    y, trace = enc.run(x, trace=True)
    repeated, _ = enc.run(x)
    np.testing.assert_array_equal(y, repeated)
    assert trace["b00.softmax"].max() <= 128
    assert len(enc.last_residual_stats) == 2


@pytest.mark.parametrize("iterations", [0, 1])
def test_rsqrt_normalization_against_independent_math(iterations):
    enc = configured({"layernorm": {"method": "rsqrt", "lut_entries": 64,
        "rsqrt_frac": 20, "iterations": iterations, "norm_frac": 20}})
    config = enc.params["layernorm_configs"]["b00.ln1"]
    variance = np.array([17, 63, 64, 255, 256, 1023, 1024,
                         (1 << 24) - 1, 1 << 24, (1 << 40) - 1], np.int64)[:, None]
    centered = np.tile(np.array([-64, -1, 0, 1, 64], np.int64), (len(variance), 1))
    result = enc._rsqrt_normalize(centered, variance, -4, 64, config, "test")
    expected = centered / 64. * (2. ** (-4 + 12 + 20)) / np.sqrt(variance)
    np.testing.assert_allclose(result, expected, atol=2, rtol=.012 if not iterations else .0003)
