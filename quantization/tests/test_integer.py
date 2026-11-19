"""Arithmetic edge cases and portable integer encoder invariants."""
import json
import math
import numpy as np
import pytest
from quantization.integer import (IntegerEncoder, build_profile, checked_matmul,
                                  integer_sqrt, quantize, dequantize,
                                  round_divide, saturate, shift_rne, _checked_add)


def profile(bits=16):
    weights = {}
    rng = np.random.RandomState(4)
    for name, shape in (("q", (64, 64)), ("k", (64, 64)), ("v", (64, 64)),
                        ("proj", (64, 64)), ("fc1", (64, 256)), ("fc2", (256, 64))):
        weights["b00." + name + ".weight"] = rng.normal(0, 0.05, shape)
        weights["b00." + name + ".bias"] = np.zeros(shape[1])
    for name in ("ln1", "ln2"):
        weights["b00." + name + ".gamma"] = np.ones(64)
        weights["b00." + name + ".beta"] = np.zeros(64)
    names = ("input q k v score softmax context proj res1 ln1 fc1 gelu fc2 res2 output").split()
    stats = {"b00." + name: {"max": 8.0, "p9999": 8.0} for name in names}
    params, arrays = build_profile(weights, stats, 8, bits, "max")
    return IntegerEncoder(json.loads(json.dumps(params)), arrays)


def test_signed_nearest_even_and_per_channel_shifts():
    a = np.arange(-13, 14, dtype=np.int64)
    np.testing.assert_array_equal(shift_rne(a, 1), np.rint(a / 2).astype(np.int64))
    np.testing.assert_array_equal(round_divide(a, np.int64(4)), np.rint(a / 4).astype(np.int64))
    np.testing.assert_array_equal(shift_rne(np.array([[3, -3, 3]]), np.array([1, 1, -2])), [[2, -2, 12]])
    np.testing.assert_array_equal(saturate(np.array([-129, -128, 127, 128]), 8), [-128, -128, 127, 127])


def test_overflow_is_detected_before_arithmetic():
    with pytest.raises(OverflowError):
        shift_rne(np.array([1 << 62], dtype=np.int64), -1)
    with pytest.raises(OverflowError):
        checked_matmul(np.full((1, 2), 1 << 32, np.int64), np.full((2, 1), 1 << 32, np.int64))
    # W8A8 uses a checked int32 MAC accumulator.  The bound check must happen
    # before NumPy performs the product, even when the input arrays are held
    # in int64 for the portable implementation.
    with pytest.raises(OverflowError, match="int32"):
        checked_matmul(np.full((1, 2), 1 << 30, np.int64),
                       np.full((2, 1), 1 << 30, np.int64),
                       bits=32, label="w8a8.boundary")
    with pytest.raises(TypeError):
        shift_rne(np.array([1.0]), 1)


def test_int32_mac_bounds_and_overflow():
    safe = checked_matmul(np.full((1, 64), 127, np.int64),
                          np.full((64, 1), 127, np.int64), bits=32,
                          label="w8a8")
    assert safe.dtype == np.int32
    assert int(safe[0, 0]) == 64 * 127 * 127
    with pytest.raises(OverflowError, match="int32"):
        checked_matmul(np.full((1, 140000), 127, np.int64),
                       np.full((140000, 1), 127, np.int64), bits=32,
                       label="w8a8_overflow")


def test_int32_signed_edges_and_bias_add():
    for value in (-(1 << 31), (1 << 31) - 1):
        actual = checked_matmul(np.array([[value]], np.int64),
                                np.array([[1]], np.int64), bits=32)
        assert int(actual[0, 0]) == value
    np.testing.assert_array_equal(_checked_add(np.array([-(1 << 31)]), np.array([1]), bits=32),
                                  [-(1 << 31) + 1])
    for acc, bias in (((1 << 31) - 1, 1), (-(1 << 31), -1)):
        with pytest.raises(OverflowError, match="bias_add.*int32"):
            _checked_add(np.array([acc]), np.array([bias]), bits=32, label="b00.bias_add")


def test_int32_attention_mac_and_encoder_failure_counter():
    result = checked_matmul(np.full((1, 99), 32768, np.int64),
                            np.full((99, 1), -128, np.int64), bits=32, label="context")
    assert int(result[0, 0]) == 99 * 32768 * -128
    enc = profile(8)
    with pytest.raises(OverflowError, match="b00.score.matmul"):
        enc._mac(np.array([[1 << 30, 1 << 30]]), np.ones((2, 1), np.int64), "b00.score.matmul")
    assert enc.last_overflow_count == 1


def test_profile_declares_int32_mac_and_wide_statistics():
    enc = profile()
    assert enc.params["accumulator_bits"] == 32
    assert enc.params["wide_temporary_bits"] == 64


@pytest.mark.parametrize("length", [64, 256])
def test_w8a8_int32_mac_boundary(length):
    """The largest W8 x W8 dot products fit in int32 and retain exact sums."""
    a = np.full((1, length), 127, dtype=np.int64)
    b = np.full((length, 1), 127, dtype=np.int64)
    result = checked_matmul(a, b, bits=32, label="w8a8.mac")
    expected = 127 * 127 * length
    assert result.dtype == np.int32
    assert int(result[0, 0]) == expected
    assert expected < (1 << 31)


def test_w8a8_profile_declares_int32_mac():
    enc = profile(8)
    assert enc.params["weight_bits"] == 8
    assert enc.params["activation_bits"] == 8
    assert enc.params["accumulator_bits"] == 32
    assert enc.params["wide_temporary_bits"] >= 32


def test_exact_integer_sqrt():
    a = np.array([0, 1, 2, 3, 4, 15, 16, 17, (1 << 63) - 1], np.int64)
    np.testing.assert_array_equal(integer_sqrt(a), [math.isqrt(int(x)) for x in a])


def test_softmax_uniform_and_extreme():
    enc = profile()
    uniform = enc.softmax(np.zeros((1, 99), np.int64), -8)
    assert np.all(uniform == 331)
    extreme = enc.softmax(np.array([[0, -100000, -100000]], np.int64), -8)
    np.testing.assert_array_equal(extreme, [[32768, 0, 0]])
    with pytest.raises(TypeError):
        enc.softmax(np.zeros((1, 3), dtype=np.float32), -8)


def test_softmax_wide_temporary_does_not_count_as_mac_overflow():
    """Q24 exponent sums and Q15 normalization use wide temporaries."""
    enc = profile(8)
    # Equal logits maximize the LUT sum (99 * 2**24), which is wider than
    # an int32 value but remains well within the checked int64 domain.
    x = np.zeros((1, 99), dtype=np.int64)
    probabilities = enc.softmax(x, -8, stats_key="b00.softmax")
    assert probabilities.dtype.kind in "iu"
    assert int(probabilities.sum()) in (32767, 32768, 32769)
    assert enc.last_wide_required_bits["b00.softmax.total"] >= 32
    assert enc.last_wide_required_bits["b00.softmax.numerator"] > 32
    assert not enc.last_mac_required_bits


def test_gelu_interpolation_and_tails():
    enc = profile()
    x = np.linspace(-10, 10, 1001)
    q = quantize(x, -10, 16)
    result = dequantize(enc.gelu(q, -10, -16), -16)
    ref = np.array([0.5 * t * (1 + math.erf(t / math.sqrt(2))) for t in dequantize(q, -10)])
    np.testing.assert_allclose(result, ref, atol=1e-5, rtol=0)


def test_layernorm_constant_and_general():
    enc = profile()
    key = "b00.ln1"
    constant = np.full((2, 64), 1234, np.int64)
    np.testing.assert_array_equal(enc.layernorm(constant, key), np.zeros_like(constant))
    rng = np.random.RandomState(9)
    x = rng.randint(-2000, 2000, size=(3, 64)).astype(np.int64)
    y = dequantize(enc.layernorm(x, key), enc.exponents[key])
    xf = dequantize(x, enc.exponents["b00.res1"])
    expected = (xf - xf.mean(-1, keepdims=True)) / np.sqrt(xf.var(-1, keepdims=True) + 1e-6)
    np.testing.assert_allclose(y, expected, atol=0.001, rtol=0)


def test_layernorm_wide_statistics_do_not_use_int32_mac_limit():
    """Variance accumulation may exceed int32 while staying checked int64."""
    enc = profile(8)
    # Alternating +/-2**20 gives a centered sum of squares around 2**58,
    # which is above int32 but safely below int64.  It must not be rejected
    # as a matrix-product overflow.
    x = np.where(np.arange(64) & 1, -(1 << 20), 1 << 20).astype(np.int64)
    y = enc.layernorm(x, "b00.ln1")
    assert y.dtype.kind in "iu"
    assert np.all(np.isfinite(y))
    assert not enc.last_mac_required_bits


def test_encoder_repeat_batch_and_portable_arrays():
    enc = profile()
    x = np.random.RandomState(2).randint(-2000, 2000, (2, 99, 64)).astype(np.int64)
    y, trace = enc.run(x, trace=True)
    repeated, _ = IntegerEncoder(enc.params, {k: v.copy() for k, v in enc.arrays.items()}).run(x)
    single, _ = enc.run(x[0])
    np.testing.assert_array_equal(y, repeated)
    np.testing.assert_array_equal(y[0], single)
    assert len(trace) == 15
    assert all(a.dtype.kind in "iu" for a in trace.values())
    assert enc.last_stats["b00.output"]["saturated"] == 0


def test_zero_weight_channel_and_a8():
    enc = profile(8)
    enc.arrays["b00.fc1.weight"][:, 0] = 0
    x = np.zeros((99, 64), np.int64)
    output, trace = enc.run(x, trace=True)
    np.testing.assert_array_equal(output, np.zeros_like(output))
    assert np.all(trace["b00.fc1"][..., 0] == 0)
