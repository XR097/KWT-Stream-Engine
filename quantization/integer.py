"""Portable integer KWT encoder and offline power-of-two profile builder.

Real values equal stored integers times 2**exponent.  Only profile construction
and the explicit quantize/dequantize boundary helpers use floating point.
MAC accumulators use a profile-selected checked width (int32 for W8A8).
Statistics and nonlinear temporary values use checked int64.
"""
import math
import copy
import numpy as np


I64_MAX = (1 << 63) - 1
I32_MAX = (1 << 31) - 1


def _limit(bits):
    if bits == 24:
        # Hardware MAC width.  Keep values in int64 while enforcing the
        # signed 24-bit range at every checked operation.
        return (1 << 23) - 1
    if bits == 32:
        return I32_MAX
    if bits == 64:
        return I64_MAX
    raise ValueError("checked arithmetic supports 24, 32 or 64 bits")


def _integers(value):
    a = np.asarray(value)
    if a.dtype.kind not in "iu":
        raise TypeError("integer encoder requires integer tensors")
    if a.dtype.kind == "u" and a.size and int(a.max()) > I64_MAX:
        raise OverflowError("unsigned input exceeds int64")
    if a.size and int(a.min()) == -(1 << 63):
        raise OverflowError("INT64_MIN is outside checked arithmetic domain")
    return a.astype(np.int64, copy=False)


def _maxabs(a):
    a = np.asarray(a)
    # Convert extrema to Python integers before abs (INT32_MIN otherwise wraps).
    return max(abs(int(a.min())), abs(int(a.max()))) if a.size else 0


def signed_bits(a):
    """Smallest signed width covering the actual positive and negative extrema."""
    a = np.asarray(a)
    low, high = (int(a.min()), int(a.max())) if a.size else (0, 0)
    return max(1, max(high, 0).bit_length() + 1,
               (max(-low, 0) - 1).bit_length() + 1 if low < 0 else 1)


def round_divide(numerator, denominator):
    """Signed division, round nearest with ties to even, positive divisor."""
    n = _integers(numerator)
    d = _integers(denominator)
    if np.any(d <= 0):
        raise ValueError("division requires a positive denominator")
    q = n // d
    r = n % d
    # Comparing r to d-r avoids overflow from 2*r.
    return q + ((r > d - r) | ((r == d - r) & ((q & 1) != 0))).astype(np.int64)


def shift_rne(value, shift):
    """Positive shift divides, negative shift multiplies, with checked int64."""
    a = _integers(value)
    s = np.asarray(shift, dtype=np.int64)
    if np.any(np.abs(s) > 62):
        raise OverflowError("shift exceeds checked int64 range")
    left = np.maximum(-s, 0)
    if np.any(np.abs(a) > np.right_shift(np.int64(I64_MAX), left)):
        raise OverflowError("left shift would overflow int64")
    right = np.maximum(s, 0)
    q = np.right_shift(a, right)
    r = a - np.left_shift(q, right)
    half = np.left_shift(np.int64(1), np.maximum(right - 1, 0))
    inc = (right > 0) & ((r > half) | ((r == half) & ((q & 1) != 0)))
    rounded = q + inc.astype(np.int64)
    return np.where(s < 0, np.left_shift(a, left), rounded)


def saturate(value, bits, unsigned=False):
    if bits < 2 or bits > 32:
        raise ValueError("activation/weight bits must lie in [2,32]")
    low = 0 if unsigned else -(1 << (bits - 1))
    high = (1 << bits) - 1 if unsigned else (1 << (bits - 1)) - 1
    return np.clip(_integers(value), low, high).astype(np.int64)


def quantize(value, exponent, bits):
    """Offline/external float-to-integer boundary; never called by run()."""
    q = np.rint(np.asarray(value, dtype=np.float64) / np.exp2(exponent))
    if not np.all(np.isfinite(q)):
        raise ValueError("cannot quantize non-finite input")
    return np.clip(q, -(1 << (bits - 1)), (1 << (bits - 1)) - 1).astype(np.int64)


def dequantize(value, exponent):
    return np.asarray(value, dtype=np.float64) * np.exp2(exponent)


def _exponent(maximum, bits):
    if not math.isfinite(maximum) or maximum < 0:
        raise ValueError("calibration ranges must be finite and nonnegative")
    if maximum == 0:
        return -24
    return max(-24, int(math.ceil(math.log2(maximum / ((1 << (bits - 1)) - 1)))))


def _checked_add(a, b, bits=64, label="addition"):
    a, b = _integers(a), _integers(b)
    limit = _limit(bits)
    bound = _maxabs(a) + _maxabs(b)
    if bound > I64_MAX:
        raise OverflowError("%s bound exceeds int%d: max_abs=%d required_bits=%d" %
                            (label, bits, bound, bound.bit_length() + 1))
    result = a + b
    if result.size and (int(result.min()) < -limit - 1 or int(result.max()) > limit):
        raise OverflowError("%s shape=%s exceeds int%d: max_abs=%d required_bits=%d" %
                            (label, result.shape, bits, _maxabs(result), signed_bits(result)))
    return result.astype(np.int32 if bits == 32 else np.int64, copy=False)


def checked_matmul(a, b, bits=64, label="matmul", prefix_stats=None):
    a, b = _integers(a), _integers(b)
    bound = _maxabs(a) * _maxabs(b) * a.shape[-1]
    limit = _limit(bits)
    if bound > I64_MAX:
        raise OverflowError("%s shapes=%s,%s accumulator exceeds checked int64: bound=%d" %
                            (label, a.shape, b.shape, bound))
    native = None
    if bits == 24 and bound <= I32_MAX:
        from .native_mac import measured_matmul
        native = measured_matmul(a, b)
    if native is not None:
        result, extrema = native
        if int(extrema[0]) < -limit - 1 or int(extrema[1]) > limit:
            raise OverflowError("%s K-ordered prefix exceeds int%d" % (label, bits))
        if prefix_stats is not None:
            prefix_stats.update(minimum=int(extrema[0]), maximum=int(extrema[1]),
                                required_signed_bits=signed_bits(extrema))
        return result.astype(np.int64)
    if bound > limit + (bits == 32) or prefix_stats is not None:
        # A loose max-absolute bound need not reject cancellation-safe inputs.
        # Check every K-ordered prefix, including prefixes that later cancel.
        shape = np.broadcast(np.empty(a.shape[:-2]), np.empty(b.shape[:-2])).shape + (a.shape[-2], b.shape[-1])
        partial = np.zeros(shape, dtype=np.int64)
        low, high = 0, 0
        for k in range(a.shape[-1]):
            partial = _checked_add(partial, a[..., :, k, None] * b[..., k, None, :],
                                   bits, label=label + ".prefix[%d]" % k)
            low = min(low, int(partial.min()))
            high = max(high, int(partial.max()))
        if prefix_stats is not None:
            prefix_stats.update(minimum=low, maximum=high,
                                required_signed_bits=signed_bits(np.array([low, high])))
    result = np.matmul(a, b)
    if result.size and (int(result.min()) < -limit - 1 or int(result.max()) > limit):
        raise OverflowError("%s shapes=%s,%s exceeds int%d: max_abs=%d required_bits=%d" %
                            (label, a.shape, b.shape, bits, _maxabs(result), signed_bits(result)))
    return result.astype(np.int32 if bits == 32 else np.int64, copy=False)


def integer_sqrt(value):
    """Vectorized exact floor(sqrt(x)); Newton iteration has no float seed."""
    n = _integers(value)
    if np.any(n < 0):
        raise ValueError("integer sqrt requires nonnegative values")
    maximum = int(n.max()) if n.size else 0
    if maximum == 0:
        return np.zeros_like(n)
    x = np.full_like(n, 1 << ((maximum.bit_length() + 1) // 2))
    while True:
        y = (x + n // np.maximum(x, 1)) // 2
        update = y < x
        if not np.any(update):
            return x
        x = np.where(update, y, x)


def build_profile(weights, stats, weight_bits=8, activation_bits=16,
                  range_mode="max", accumulator_bits=32, weight_bits_by_linear=None,
                  residual_accumulator_bits=32):
    """Build JSON metadata plus integer arrays from float weights/calibration."""
    if weight_bits not in (4, 8, 16) or activation_bits not in (8, 16):
        raise ValueError("supported candidates are W4/W8/W16 and A8/A16")
    if accumulator_bits not in (24, 32, 64):
        raise ValueError("accumulator_bits must be 24, 32 or 64")
    if residual_accumulator_bits not in (24, 32, 64):
        raise ValueError("residual_accumulator_bits must be 24, 32 or 64")
    weight_bits_by_linear = dict(weight_bits_by_linear or {})
    if any(v not in (4, 8, 16) for v in weight_bits_by_linear.values()):
        raise ValueError("per-linear weight precision must be 4, 8 or 16")
    range_key = {"max": "max", "absmax": "max", "p9999": "p9999",
                 "percentile": "p9999"}.get(range_mode)
    if range_key is None:
        raise ValueError("range_mode must be max or p9999")
    exponents, arrays, linears, norms = {}, {}, {}, {}
    blocks = sorted(set(k.split(".")[0] for k in weights if k.endswith(".q.weight")))
    if not blocks:
        raise ValueError("no bNN.q.weight tensors found")
    tensor_names = ("input", "q", "k", "v", "score", "softmax", "context",
                    "proj", "res1", "ln1", "fc1", "gelu", "fc2", "res2", "output")
    for b in blocks:
        for name in tensor_names:
            key = b + "." + name
            if name == "softmax":
                exponents[key] = -15
            else:
                if key not in stats:
                    raise KeyError("missing calibration tensor " + key)
                exponents[key] = _exponent(float(stats[key][range_key]), activation_bits)
    # A block's input must be the exact previous output encoding.
    for previous, current in zip(blocks, blocks[1:]):
        exponents[current + ".input"] = exponents[previous + ".output"]
    for b in blocks:
        for name, source in (("q", "input"), ("k", "input"), ("v", "input"),
                             ("proj", "context"), ("fc1", "ln1"), ("fc2", "gelu")):
            key = b + "." + name
            wb = int(weight_bits_by_linear.get(key, weight_bits))
            w = np.asarray(weights[key + ".weight"], dtype=np.float64)
            if w.ndim != 2:
                raise ValueError("linear weights require [input,output]: " + key)
            ew = np.array([_exponent(float(m), wb) for m in np.max(np.abs(w), axis=0)], dtype=np.int64)
            arrays[key + ".weight"] = quantize(w, ew, wb)
            arrays[key + ".weight_exponents"] = ew
            bias = np.asarray(weights.get(key + ".bias", np.zeros(w.shape[1])), dtype=np.float64)
            bias_q = np.rint(bias / np.exp2(ew + exponents[b + "." + source]))
            if not np.all(np.isfinite(bias_q)) or np.any(np.abs(bias_q) > I64_MAX):
                raise OverflowError("bias cannot be encoded in int64: " + key)
            arrays[key + ".bias"] = bias_q.astype(np.int64)
            linears[key] = {"input": b + "." + source, "output": key,
                            "in_features": int(w.shape[0]), "out_features": int(w.shape[1]),
                            "weight_bits": wb}
        for name, source, destination in (("ln1", "res1", "ln1"), ("ln2", "res2", "output")):
            key = b + "." + name
            gamma = np.asarray(weights[key + ".gamma"], dtype=np.float64)
            beta = np.asarray(weights[key + ".beta"], dtype=np.float64)
            arrays[key + ".gamma"] = quantize(gamma, -20, 32)
            arrays[key + ".beta"] = quantize(beta, exponents[b + "." + destination], 32)
            count = int(gamma.size)
            epsilon_q24 = int(round(1e-6 * (1 << 24)))
            if epsilon_q24 > I64_MAX:
                raise OverflowError("LayerNorm epsilon exceeds int64: " + key)
            norms[key] = {"input": b + "." + source, "output": b + "." + destination,
                          "size": count, "epsilon_q24": max(1, epsilon_q24)}
    arrays["softmax.exp_q24"] = np.rint(np.exp(-np.arange(4097, dtype=np.float64) / 256.0) * (1 << 24)).astype(np.int64)
    grid = np.arange(-2048, 2049, dtype=np.float64) / 256.0
    erf = np.array([math.erf(float(x) / math.sqrt(2.0)) for x in grid])
    arrays["gelu.y_q20"] = np.rint(0.5 * grid * (1 + erf) * (1 << 20)).astype(np.int64)
    params = {"format_version": 2, "weight_bits": weight_bits, "activation_bits": activation_bits,
              "accumulator_bits": accumulator_bits, "wide_temporary_bits": 64,
              "residual_accumulator_bits": residual_accumulator_bits,
              "weight_bits_by_linear": {k: v["weight_bits"] for k, v in linears.items()},
              "range_mode": range_key, "blocks": blocks, "exponents": exponents,
              "linears": linears, "norms": norms, "rounding": "nearest_even",
              "saturation": "signed_twos_complement", "attention_scale_exponent": -3,
              "softmax_bits": 16, "softmax_exponent": -15,
              "gelu_lut": {"minimum_q8": -2048, "maximum_q8": 2048, "output_exponent": -20},
              "layernorm_gamma_exponent": -20, "layernorm_epsilon": 1e-6}
    return params, arrays


def configure_profile(params, arrays, weights, config):
    """Offline immutable configuration of a frozen quantization profile.

    Activations keep their calibrated exponents. Only the probability exponent
    follows its declared probability format. All runtime tables are exported.
    """
    p = copy.deepcopy(params)
    a = {k: np.asarray(v).copy() for k, v in arrays.items()}
    p["format_version"] = 3
    p["nonlinear"] = copy.deepcopy(config)
    if "accumulator_bits" in config:
        if int(config["accumulator_bits"]) not in (24, 32, 64):
            raise ValueError("accumulator_bits must be 24, 32 or 64")
        p["accumulator_bits"] = int(config["accumulator_bits"])
    p["residual_accumulator_bits"] = int(config.get("residual_accumulator_bits", 32))
    p["diagnostic_arrays"] = []
    weight_map = config.get("weight_bits_by_linear", {})
    for key, spec in p["linears"].items():
        bits = int(weight_map.get(key, spec.get("weight_bits", p["weight_bits"])))
        if bits not in (4, 8, 16):
            raise ValueError("invalid per-linear weight precision")
        previous = int(spec.get("weight_bits", p["weight_bits"]))
        if bits != previous:
            w = np.asarray(weights[key + ".weight"], dtype=np.float64)
            ew = np.array([_exponent(float(m), bits) for m in np.max(np.abs(w), axis=0)], np.int64)
            a[key + ".weight"] = quantize(w, ew, bits)
            a[key + ".weight_exponents"] = ew
            bias = np.asarray(weights.get(key + ".bias", np.zeros(w.shape[1])), dtype=np.float64)
            bq = np.rint(bias / np.exp2(ew + p["exponents"][spec["input"]]))
            if not np.all(np.isfinite(bq)) or np.any(np.abs(bq) > I64_MAX):
                raise OverflowError("bias encoding overflow: " + key)
            a[key + ".bias"] = bq.astype(np.int64)
        spec["weight_bits"] = bits
    unknown = set(weight_map) - set(p["linears"])
    if unknown:
        raise KeyError("unknown linear precision keys: " + str(sorted(unknown)))
    p["weight_bits_by_linear"] = {k: s["weight_bits"] for k, s in p["linears"].items()}
    p["softmax_configs"], p["layernorm_configs"], p["gelu_configs"] = {}, {}, {}
    for block in p["blocks"]:
        soft = {"table": "reference", "exp_frac": 24, "prob_frac": 15}
        soft.update(config.get("softmax", {}))
        soft.update(config.get("softmax_by_block", {}).get(block, {}))
        if soft["table"] not in ("reference", "compact") or soft["exp_frac"] not in (24, 15) or soft["prob_frac"] not in (15, 11, 8, 7):
            raise ValueError("unsupported Softmax configuration")
        table_key = "softmax.exp_q%d%s" % (soft["exp_frac"], "_compact" if soft["table"] == "compact" else "")
        if soft["exp_frac"] == 24:
            exp_table = np.asarray(a["softmax.exp_q24"], dtype=np.int64)
        else:
            exp_table = np.rint(np.exp(-np.arange(4097, dtype=np.float64) / 256.0) * (1 << 15)).astype(np.int64)
        a[table_key] = exp_table[::16].copy() if soft["table"] == "compact" else exp_table.copy()
        soft["table_key"] = table_key
        p["softmax_configs"][block] = soft
        p["exponents"][block + ".softmax"] = -int(soft["prob_frac"])
        for name in ("ln1", "ln2"):
            key = block + "." + name
            ln = {"norm_frac": 20, "gamma_frac": 20, "method": "reference",
                  "lut_entries": 64, "rsqrt_frac": 20, "iterations": 0}
            ln.update(config.get("layernorm", {}))
            ln.update(config.get("layernorm_by_op", {}).get(key, {}))
            if ln["norm_frac"] not in (20, 16, 12) or ln["gamma_frac"] not in (20, 16, 12) or ln["method"] not in ("reference", "rsqrt"):
                raise ValueError("unsupported LayerNorm precision")
            if ln["lut_entries"] not in (64, 256) or ln["rsqrt_frac"] not in (16, 20) or ln["iterations"] not in (0, 1):
                raise ValueError("unsupported inverse-square-root configuration")
            if key + ".gamma" not in weights:
                raise KeyError("frozen float gamma required: " + key)
            a[key + ".gamma"] = quantize(weights[key + ".gamma"], -ln["gamma_frac"], 32)
            if ln["method"] == "rsqrt":
                tkey = "layernorm.rsqrt_n%d_q%d" % (ln["lut_entries"], ln["rsqrt_frac"])
                grid = 1.0 + (np.arange(ln["lut_entries"], dtype=np.float64) + 0.5) * 3.0 / ln["lut_entries"]
                a[tkey] = np.rint((1 << ln["rsqrt_frac"]) / np.sqrt(grid)).astype(np.int64)
                ln["table_key"] = tkey
            p["layernorm_configs"][key] = ln
    # Use the unchanged reference encoder to generate the exact final A8 map.
    reference = IntegerEncoder(params, arrays)
    for block in p["blocks"]:
        key = block + ".gelu"
        method = config.get("gelu", "reference")
        if method not in ("reference", "direct", "middle"):
            raise ValueError("unsupported GELU implementation")
        ei, eo = p["exponents"][block + ".fc1"], p["exponents"][key]
        spec = {"method": method, "input_exponent": ei, "output_exponent": eo}
        if method != "reference":
            if int(p["activation_bits"]) != 8:
                raise ValueError("direct GELU maps require A8")
            x = np.arange(-128, 128, dtype=np.int64)
            raw = reference.gelu(x, ei, eo)
            final = saturate(raw, 8)
            linear = saturate(shift_rne(x, eo - ei), 8)
            low, high = -128, 127
            if method == "middle":
                while low <= high and final[low + 128] == 0:
                    low += 1
                while high >= low and final[high + 128] == linear[high + 128]:
                    high -= 1
            table_key = "gelu.%s.e%d.e%d" % (method, ei, eo)
            presat_key = "gelu.presat.e%d.e%d" % (ei, eo)
            a[table_key] = final[low + 128:high + 129].astype(np.int8)
            a[presat_key] = raw.copy()
            p["diagnostic_arrays"].append(presat_key)
            spec.update({"table_key": table_key, "presat_key": presat_key,
                         "minimum_input": low, "maximum_input": high})
        p["gelu_configs"][key] = spec
    p["diagnostic_arrays"] = sorted(set(p["diagnostic_arrays"]))
    used_tables = {s["table_key"] for s in p["softmax_configs"].values()}
    used_tables.update(s["table_key"] for s in p["layernorm_configs"].values() if "table_key" in s)
    used_tables.update(s["table_key"] for s in p["gelu_configs"].values() if "table_key" in s)
    if any(s["method"] == "reference" for s in p["gelu_configs"].values()):
        used_tables.add("gelu.y_q20")
    p["diagnostic_arrays"] = sorted(set(p["diagnostic_arrays"]) |
        {k for k in a if (k.startswith("softmax.exp_") or k.startswith("gelu.") or k.startswith("layernorm.rsqrt_")) and k not in used_tables})
    return p, a


class IntegerEncoder:
    """Integer-only batch encoder; parameters are the exported portable format."""

    def __init__(self, params, arrays):
        self.params = params
        self.arrays = {k: _integers(v) for k, v in arrays.items()}
        self.exponents = params["exponents"]
        self.bits = int(params["activation_bits"])
        self.accumulator_bits = int(params.get("accumulator_bits", 64))
        self.residual_accumulator_bits = int(params.get("residual_accumulator_bits", 64))
        self.last_stats = {}
        self.last_saturation = {}
        self.last_required_bits = {}
        self.last_mac_required_bits = {}
        self.last_wide_required_bits = {}
        self.last_overflow_count = 0
        self.last_residual_stats = {}
        self._gelu_pending = {}

    def _wide(self, key, value):
        self.last_wide_required_bits[key] = signed_bits(value)
        return value

    def _mac(self, a, b, key):
        prefix = {} if self.accumulator_bits == 24 else None
        try:
            result = checked_matmul(a, b, self.accumulator_bits, label=key, prefix_stats=prefix)
        except OverflowError:
            self.last_overflow_count += 1
            raise
        self.last_mac_required_bits[key] = prefix["required_signed_bits"] if prefix else signed_bits(result)
        if prefix:
            self.last_stats[key + ".prefix"] = prefix
        return result

    def _store(self, key, value, traces, unsigned=False, bits=None):
        bits = bits or self.bits
        a = _integers(value)
        low, high = ((0, (1 << bits) - 1) if unsigned else
                     (-(1 << (bits - 1)), (1 << (bits - 1)) - 1))
        self.last_stats[key] = {"count": int(a.size), "saturated": int(np.count_nonzero((a < low) | (a > high))),
                                "maximum_abs_before_saturation": _maxabs(a)}
        self.last_saturation[key] = {"clipped": self.last_stats[key]["saturated"], "total": int(a.size)}
        maximum = int(np.max(a)) if unsigned and a.size else _maxabs(a)
        self.last_required_bits[key] = (maximum.bit_length() if unsigned else maximum.bit_length() + 1)
        self.last_wide_required_bits[key] = self.last_required_bits[key]
        if key in self._gelu_pending:
            before = self._gelu_pending.pop(key)
            self.last_stats[key]["saturated"] = int(np.count_nonzero((before < low) | (before > high)))
            self.last_stats[key]["maximum_abs_before_saturation"] = _maxabs(before)
            self.last_saturation[key]["clipped"] = self.last_stats[key]["saturated"]
            self.last_required_bits[key] = _maxabs(before).bit_length() + 1
            self.last_wide_required_bits[key] = self.last_required_bits[key]
        a = saturate(a, bits, unsigned)
        if traces is not None:
            traces[key] = a.copy()
        return a

    def _linear(self, x, key, traces):
        spec = self.params["linears"][key]
        acc = self._mac(x, self.arrays[key + ".weight"], key + ".matmul")
        try:
            acc = _checked_add(acc, self.arrays[key + ".bias"], self.accumulator_bits,
                               label=key + ".bias_add")
        except OverflowError:
            self.last_overflow_count += 1
            raise
        shifts = self.exponents[spec["output"]] - self.exponents[spec["input"]] - self.arrays[key + ".weight_exponents"]
        bias = self.arrays[key + ".bias"]
        self.last_wide_required_bits[key + ".bias"] = signed_bits(bias)
        self.last_wide_required_bits[key + ".shift_codes"] = signed_bits(shifts)
        self.last_stats[key + ".bias"] = {
            "minimum": int(np.min(bias)) if bias.size else 0,
            "maximum": int(np.max(bias)) if bias.size else 0,
            "required_signed_bits": signed_bits(bias),
        }
        self.last_stats[key + ".shift_codes"] = {
            "minimum": int(np.min(shifts)) if shifts.size else 0,
            "maximum": int(np.max(shifts)) if shifts.size else 0,
            "required_signed_bits": signed_bits(shifts),
        }
        self.last_stats[key + ".accumulator"] = {"maximum_abs": _maxabs(acc), "required_signed_bits": _maxabs(acc).bit_length() + 1}
        self.last_mac_required_bits[key + ".accumulator"] = signed_bits(acc)
        self.last_required_bits[key] = _maxabs(acc).bit_length() + 1
        return self._store(key, shift_rne(acc, shifts), traces)

    def _residual(self, x, x_key, y, y_key, output_key, traces):
        e = self.exponents[output_key]
        a = shift_rne(x, e - self.exponents[x_key])
        b = shift_rne(y, e - self.exponents[y_key])
        self._wide(output_key + ".aligned_x", a)
        self._wide(output_key + ".aligned_y", b)
        try:
            _checked_add(a, np.int64(0), self.residual_accumulator_bits, label=output_key + ".aligned_x")
            _checked_add(b, np.int64(0), self.residual_accumulator_bits, label=output_key + ".aligned_y")
            total = _checked_add(a, b, self.residual_accumulator_bits, label=output_key + ".residual_add")
        except OverflowError:
            self.last_overflow_count += 1
            raise
        def extrema(value):
            value = np.asarray(value)
            return {"minimum": int(value.min()) if value.size else 0,
                    "maximum": int(value.max()) if value.size else 0,
                    "maximum_abs": _maxabs(value), "required_signed_bits": signed_bits(value)}
        self.last_residual_stats[output_key] = {
            "x": extrema(x), "y": extrema(y), "aligned_x": extrema(a),
            "aligned_y": extrema(b), "sum": extrema(total),
            "x_shift": int(e - self.exponents[x_key]),
            "y_shift": int(e - self.exponents[y_key]),
            "accumulator_bits": self.residual_accumulator_bits,
            "overflow_count": 0}
        return self._store(output_key, total, traces)

    def softmax(self, x, exponent, stats_key=None):
        x = _integers(x)
        delta = x - np.max(x, axis=-1, keepdims=True)
        q8 = shift_rne(delta, -8 - exponent)
        config = self.params.get("softmax_configs", {}).get((stats_key or "").split(".")[0], {})
        prob_frac = int(config.get("prob_frac", 15))
        index = np.clip(-q8, 0, 4096)
        if config.get("table") == "compact":
            if np.any(index % 16):
                raise ValueError("compact Softmax requires score exponent >= -4")
            index = index // 16
        exp = self.arrays[config.get("table_key", "softmax.exp_q24")][index]
        exp = np.where(q8 < -4096, 0, exp)
        if _maxabs(exp) * exp.shape[-1] > I64_MAX:
            raise OverflowError("Softmax exponent sum exceeds int64")
        total = np.sum(exp, axis=-1, keepdims=True, dtype=np.int64)
        numerator = shift_rne(exp, -prob_frac)
        quotient = round_divide(numerator, total)
        # P8 is Q8 in an actual u8 lane: exactly 1.0 rounds to 256,
        # then saturates to 255. P7 retains its native 0..128 endpoint.
        probability = np.minimum(quotient, 255) if prob_frac == 8 else quotient
        if stats_key:
            self.last_wide_required_bits[stats_key + ".total"] = _maxabs(total).bit_length() + 1
            self.last_wide_required_bits[stats_key + ".numerator"] = (_maxabs(exp) << prob_frac).bit_length() + 1
            self.last_stats[stats_key + ".softmax"] = {
                "exp_required_signed_bits": signed_bits(exp),
                "denominator_required_signed_bits": signed_bits(total),
                "numerator_required_signed_bits": (_maxabs(exp) << prob_frac).bit_length() + 1,
                "quotient_required_unsigned_bits": max(1, int(quotient.max()).bit_length()),
                "stored_required_unsigned_bits": max(1, int(probability.max()).bit_length()),
                "exp_required_unsigned_bits": max(1, int(exp.max()).bit_length()),
                "denominator_required_unsigned_bits": max(1, int(total.max()).bit_length()),
                "numerator_required_unsigned_bits": max(1, int(numerator.max()).bit_length()),
                "prob_frac": prob_frac,
            }
            self._wide(stats_key + ".delta", delta)
        return probability

    def gelu(self, x, input_exponent, output_exponent, stats_key=None):
        x = _integers(x)
        config = self.params.get("gelu_configs", {}).get(stats_key, {})
        if config.get("method", "reference") != "reference":
            if np.any(x < -128) or np.any(x > 127):
                raise ValueError("direct GELU input outside A8")
            low, high = config["minimum_input"], config["maximum_input"]
            table = self.arrays[config["table_key"]]
            if table.size:
                middle = table[np.clip(x - low, 0, table.size - 1)]
            else:
                middle = np.zeros_like(x)
            output = np.where(x < low, 0, np.where(x > high,
                saturate(shift_rne(x, output_exponent - input_exponent), 8), middle))
            if stats_key:
                self._gelu_pending[stats_key] = self.arrays[config["presat_key"]][x + 128]
            return output
        q16 = shift_rne(x, -16 - input_exponent)
        bounded = np.clip(q16, -(8 << 16), 8 << 16)
        index = (bounded >> 8) + 2048
        index = np.minimum(index, 4095)
        fraction = bounded - ((index - 2048) << 8)
        table = self.arrays["gelu.y_q20"]
        delta = table[index + 1] - table[index]
        if _maxabs(delta) * _maxabs(fraction) > I64_MAX:
            raise OverflowError("GELU interpolation product exceeds int64")
        product = delta * fraction
        interp = _checked_add(table[index], round_divide(product, np.int64(256)))
        if stats_key:
            self._wide(stats_key + ".q16", q16)
            self._wide(stats_key + ".interpolation_product", product)
            self._wide(stats_key + ".interpolated_q20", interp)
        result = shift_rne(interp, output_exponent + 20)
        positive_tail = shift_rne(x, output_exponent - input_exponent)
        return np.where(q16 <= -(8 << 16), 0, np.where(q16 >= (8 << 16), positive_tail, result))

    def layernorm(self, x, key):
        x = _integers(x)
        spec = self.params["norms"][key]
        n = int(spec["size"])
        if x.shape[-1] != n:
            raise ValueError("LayerNorm last dimension mismatch")
        if _maxabs(x) * n * 2 > I64_MAX:
            raise OverflowError("LayerNorm centered numerator overflow")
        centered = x * n - np.sum(x, axis=-1, keepdims=True, dtype=np.int64)
        maximum = _maxabs(centered)
        if maximum * maximum * n > I64_MAX:
            raise OverflowError("LayerNorm sum of squares overflow")
        # centered=n*(x-mean); population variance is sum(centered^2)/n^3.
        square_sum = np.sum(centered * centered, axis=-1, keepdims=True, dtype=np.int64)
        variance = round_divide(square_sum, np.int64(n * n * n))
        self._wide(key + ".centered", centered)
        self._wide(key + ".square_sum", square_sum)
        input_exp = self.exponents[spec["input"]]
        # x integers represent x_real * 2**input_exp. Convert variance to Q24.
        variance_q24 = _checked_add(
            shift_rne(variance, -(2 * input_exp + 24)),
            np.int64(spec["epsilon_q24"]),
        )
        config = self.params.get("layernorm_configs", {}).get(key, {})
        norm_frac = int(config.get("norm_frac", 20))
        gamma_frac = int(config.get("gamma_frac", 20))
        if config.get("method") == "rsqrt":
            normalized_q20 = self._rsqrt_normalize(centered, variance_q24, input_exp, n, config, key)
        else:
            root_q12 = integer_sqrt(variance_q24)
            # centered/n is (x - mean) in integer units; root is std*2**12.
            numerator = shift_rne(centered, -(input_exp + 12 + norm_frac))
            if _maxabs(root_q12) * n > I64_MAX:
                raise OverflowError("LayerNorm normalization denominator exceeds int64")
            denominator = np.int64(n) * root_q12
            normalized_q20 = round_divide(numerator, denominator)
            self.last_stats[key + ".normalization_quotient"] = {
                "minimum": int(np.min(normalized_q20)) if normalized_q20.size else 0,
                "maximum": int(np.max(normalized_q20)) if normalized_q20.size else 0,
                "required_signed_bits": signed_bits(normalized_q20),
                "norm_frac": norm_frac,
            }
            self._wide(key + ".normalization_numerator", numerator)
            self._wide(key + ".normalization_denominator", denominator)
        self._wide(key + ".variance_q24", variance_q24)
        self._wide(key + ".normalized_q%d" % norm_frac, normalized_q20)
        gamma = self.arrays[key + ".gamma"]
        if _maxabs(normalized_q20) * _maxabs(gamma) > I64_MAX:
            raise OverflowError("LayerNorm affine product overflow")
        # Product is Q40; convert it to the declared output exponent.
        affine_product = normalized_q20 * gamma
        self.last_stats[key + ".affine_product"] = {
            "minimum": int(np.min(affine_product)) if affine_product.size else 0,
            "maximum": int(np.max(affine_product)) if affine_product.size else 0,
            "required_signed_bits": signed_bits(affine_product),
            "fractional_bits": norm_frac + gamma_frac,
        }
        self._wide(key + ".affine_product_q%d" % (norm_frac + gamma_frac), affine_product)
        output = shift_rne(affine_product, self.exponents[spec["output"]] + norm_frac + gamma_frac)
        return _checked_add(output, self.arrays[key + ".beta"])

    def _rsqrt_normalize(self, centered, variance_q24, input_exp, n, config, key):
        if np.any(variance_q24 <= 0):
            raise ValueError("inverse sqrt requires positive variance")
        # Choose variance = mantissa * 2**(2*h), mantissa in [1,4).
        h = np.zeros_like(variance_q24)
        for threshold in range(2, 63, 2):
            h += (variance_q24 >= (1 << threshold)).astype(np.int64)
        mantissa = shift_rne(variance_q24, 2 * h - 30)
        entries, frac = int(config["lut_entries"]), int(config["rsqrt_frac"])
        address = np.clip(((mantissa - (1 << 30)) * entries) // (3 << 30), 0, entries - 1)
        r = self.arrays[config["table_key"]][address]
        self._wide(key + ".rsqrt.mantissa_q30", mantissa)
        if config["iterations"]:
            # y <- y*(3-m*y*y)/2. Round each product before the next one;
            # this keeps Q20 Newton products within checked int64.
            if _maxabs(r) * _maxabs(r) > I64_MAX:
                raise OverflowError("rsqrt square overflow")
            rr = shift_rne(r * r, frac)
            if _maxabs(mantissa) * _maxabs(rr) > I64_MAX:
                raise OverflowError("rsqrt mantissa product overflow")
            mrr = shift_rne(mantissa * rr, 30)
            factor = _checked_add(np.int64(3 << frac), -mrr)
            if _maxabs(r) * _maxabs(factor) > I64_MAX:
                raise OverflowError("rsqrt Newton product overflow")
            correction = r * factor
            self._wide(key + ".rsqrt.square_product", r * r)
            self._wide(key + ".rsqrt.mantissa_product", mantissa * rr)
            self._wide(key + ".rsqrt.correction_factor", factor)
            self._wide(key + ".rsqrt.newton_product", correction)
            r = shift_rne(correction, frac + 1)
        if _maxabs(centered) * _maxabs(r) > I64_MAX:
            raise OverflowError("rsqrt normalization product overflow")
        product = centered * r
        self._wide(key + ".rsqrt.normalization_product", product)
        self._wide(key + ".rsqrt.reciprocal", r)
        scaled = shift_rne(product, frac - input_exp - 12 - int(config["norm_frac"]) + h)
        return round_divide(scaled, np.int64(n))

    def run(self, x_int, trace=False):
        x = _integers(x_int)
        if x.ndim not in (2, 3) or x.shape[-2:] != (99, 64):
            raise ValueError("encoder expects [99,64] or [batch,99,64]")
        self.last_stats = {}
        self.last_saturation = {}
        self.last_required_bits = {}
        self.last_mac_required_bits = {}
        self.last_wide_required_bits = {}
        self.last_overflow_count = 0
        self.last_residual_stats = {}
        self._gelu_pending = {}
        traces = {} if trace else None
        for b in self.params["blocks"]:
            x = self._store(b + ".input", x, traces)
            q = self._linear(x, b + ".q", traces)
            k = self._linear(x, b + ".k", traces)
            v = self._linear(x, b + ".v", traces)
            score = self._mac(q, np.swapaxes(k, -1, -2), b + ".score.matmul")
            source_e = self.exponents[b + ".q"] + self.exponents[b + ".k"] + self.params["attention_scale_exponent"]
            score = self._store(b + ".score", shift_rne(score, self.exponents[b + ".score"] - source_e), traces)
            prob_frac = int(self.params.get("softmax_configs", {}).get(b, {}).get("prob_frac", 15))
            probability = self._store(b + ".softmax", self.softmax(score, self.exponents[b + ".score"], b + ".softmax"), traces, unsigned=True, bits=8 if prob_frac == 8 else prob_frac + 1)
            context = self._mac(probability, v, b + ".context.matmul")
            context = self._store(b + ".context", shift_rne(context, self.exponents[b + ".context"] + prob_frac - self.exponents[b + ".v"]), traces)
            projected = self._linear(context, b + ".proj", traces)
            residual = self._residual(x, b + ".input", projected, b + ".proj", b + ".res1", traces)
            normalized = self._store(b + ".ln1", self.layernorm(residual, b + ".ln1"), traces)
            hidden = self._linear(normalized, b + ".fc1", traces)
            activated = self._store(b + ".gelu", self.gelu(hidden, self.exponents[b + ".fc1"], self.exponents[b + ".gelu"], b + ".gelu"), traces)
            projected = self._linear(activated, b + ".fc2", traces)
            residual = self._residual(normalized, b + ".ln1", projected, b + ".fc2", b + ".res2", traces)
            x = self._store(b + ".output", self.layernorm(residual, b + ".ln2"), traces)
        return x, traces or {}
