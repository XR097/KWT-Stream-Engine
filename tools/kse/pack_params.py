#!/usr/bin/env python3
"""Pack the frozen KWT-1 all-W4 profile into the KSE parameter stream (v3).

The stream is the exact sequence of 32-bit words that kse_top consumes on its
param port, in consumption order.  Layout (docs/spec/kse_top.md, section 5):

  per layer bNN (every field padded with zero words to a multiple of 4 words,
  i.e. whole 128-bit rows, so the prefetch FIFO can deliver one row per cycle):
    header   8 words  (5 used: precomputed shift constants, GELU window, LN epsilon)
    q,k,v    per column block cb (32 output channels): shift[8] W[2*128]
    proj     per cb: bias[16] shift[8] W[2*128]
    LN1      gamma[32] beta[16]
    fc1      per cb (8 cbs): bias[16] shift[8] W[2*128]
    fc2      per cb (2 cbs): bias[16] shift[8] W[8*128]
    LN2      gamma[32] beta[16]

All exponent arithmetic is done here, once, offline (allowed one-time format
conversion); the RTL only sees final signed shift amounts using the signed shift
convention (positive = round-half-even right shift, negative = left shift).

Every field is range-checked before truncation.  ``--verify`` decodes the
stream back and compares every field with the profile arrays.
"""
from __future__ import annotations

import argparse
import json
import struct
from pathlib import Path

import numpy as np

LINEARS = ("q", "k", "v", "proj", "fc1", "fc2")
HAS_BIAS = {"q": False, "k": False, "v": False, "proj": True, "fc1": True, "fc2": True}
R = 32           # array reduction rows
C = 32           # array columns (output channels per column block)
T = 99
D = 64
HEADER_WORDS = 8   # 5 used + 3 zero pad
SHIFT_WORDS = 8    # 6 used + 2 zero pad
LN_FRAC = 12     # frozen LayerNorm Q12/Q12 configuration
PROB_FRAC = 7    # frozen Softmax P7
SHIFT_BITS = 5   # per-channel linear shift field


def check(value, lo, hi, what):
    value = int(value)
    if value < lo or value > hi:
        raise ValueError(f"{what}={value} outside [{lo},{hi}]")
    return value


def pack_fields(values, width, signed):
    """Pack fields LSB first; a field never straddles a word boundary."""
    out, word, used, mask = [], 0, 0, (1 << width) - 1
    lo, hi = (-(1 << (width - 1)), (1 << (width - 1)) - 1) if signed else (0, mask)
    for v in values:
        v = check(v, lo, hi, f"field{width}")
        if used + width > 32:
            out.append(word)
            word, used = 0, 0
        word |= (v & mask) << used
        used += width
    if used:
        out.append(word)
    return out


def unpack_fields(words, count, width, signed):
    res, wi, bit, mask = [], 0, 0, (1 << width) - 1
    for _ in range(count):
        if bit + width > 32:
            wi, bit = wi + 1, 0
        v = (words[wi] >> bit) & mask
        bit += width
        if signed and v & (1 << (width - 1)):
            v -= 1 << width
        res.append(v)
    return res


class Profile:
    def __init__(self, profile_dir):
        self.dir = Path(profile_dir)
        self.p = json.loads((self.dir / "profile.json").read_text())
        p = self.p
        if p["accumulator_bits"] != 24 or p["residual_accumulator_bits"] != 24:
            raise ValueError("KSE v1 expects the MAC24 profile")
        if p["rounding"] != "nearest_even":
            raise ValueError("unsupported rounding")

    def arr(self, key):
        return np.load(self.dir / self.p["arrays"][key]["file"])

    def e(self, block, name):
        return int(self.p["exponents"][f"{block}.{name}"])


def layer_header(pf, b):
    """Return the 5 header words and a dict of the decoded field values."""
    p = pf.p
    e = lambda n: pf.e(b, n)
    sm = p["softmax_configs"][b]
    if sm.get("table") != "compact" or int(sm["prob_frac"]) != PROB_FRAC or int(sm["exp_frac"]) != 15:
        raise ValueError(f"{b}: RTL hardwires compact Q15 exp table and P7")
    for ln in ("ln1", "ln2"):
        cfg = p["layernorm_configs"][f"{b}.{ln}"]
        if cfg["method"] != "reference" or int(cfg["norm_frac"]) != LN_FRAC or int(cfg["gamma_frac"]) != LN_FRAC:
            raise ValueError(f"{b}.{ln}: RTL hardwires reference LN Q12/Q12")
        if int(p["norms"][f"{b}.{ln}"]["size"]) != D:
            raise ValueError("LN size must be 64")
    g = p["gelu_configs"][f"{b}.gelu"]
    if g["method"] != "middle" or int(g["input_exponent"]) != e("fc1") or int(g["output_exponent"]) != e("gelu"):
        raise ValueError(f"{b}: GELU config inconsistent")
    f = {}
    f["score_sh"] = e("score") - (e("q") + e("k") + int(p["attention_scale_exponent"]))
    f["q8_sh"] = -8 - e("score")
    f["ctx_sh"] = e("context") + PROB_FRAC - e("v")
    f["gelu_tail"] = e("gelu") - e("fc1")
    f["res1_ax"] = e("res1") - e("input")
    f["res1_ay"] = e("res1") - e("proj")
    f["res2_ax"] = e("res2") - e("ln1")
    f["res2_ay"] = e("res2") - e("fc2")
    for ln, ein, eout in (("ln1", "res1", "ln1"), ("ln2", "res2", "output")):
        if p["norms"][f"{b}.{ln}"]["input"] != f"{b}.{ein}" or p["norms"][f"{b}.{ln}"]["output"] != f"{b}.{eout}":
            raise ValueError("LN io names")
        f[f"{ln}_vsh"] = -(2 * e(ein) + 24)
        f[f"{ln}_nsh"] = -(e(ein) + 12 + LN_FRAC)
        f[f"{ln}_ash"] = e(eout) + LN_FRAC + LN_FRAC
        f[f"{ln}_eps"] = int(p["norms"][f"{b}.{ln}"]["epsilon_q24"])
    f["gelu_lo"] = int(g["minimum_input"])
    f["gelu_hi"] = int(g["maximum_input"])
    # RTL datapath limits (see docs/spec/kse_top.md section 6)
    check(f["score_sh"], 0, 24, "score_sh"); check(f["ctx_sh"], 0, 24, "ctx_sh")
    check(f["q8_sh"], -15, 0, "q8_sh"); check(f["gelu_tail"], -7, 7, "gelu_tail")
    for k in ("res1_ax", "res1_ay", "res2_ax", "res2_ay"):
        check(f[k], -7, 15, k)
    for ln in ("ln1", "ln2"):
        check(f[f"{ln}_vsh"], -20, 0, "vsh"); check(f[f"{ln}_nsh"], -23, 0, "nsh")
        check(f[f"{ln}_ash"], 0, 20, "ash"); check(f[f"{ln}_eps"], 0, 65535, "eps")
    check(f["gelu_lo"], -128, 127, "gelu_lo"); check(f["gelu_hi"], -128, 127, "gelu_hi")
    tab = np.load(pf.dir / (g["table_key"].replace(".", "__") + ".npy"))
    if f["gelu_hi"] - f["gelu_lo"] + 1 != tab.size:
        raise ValueError("GELU window does not match ROM size")
    b8 = lambda *v: sum((check(x, -128, 127, "hdr") & 0xFF) << (8 * i) for i, x in enumerate(v))
    words = [
        b8(f["score_sh"], f["q8_sh"], f["ctx_sh"], f["gelu_tail"]),
        b8(f["res1_ax"], f["res1_ay"], f["res2_ax"], f["res2_ay"]),
        b8(f["ln1_vsh"], f["ln1_nsh"], f["ln1_ash"], f["gelu_lo"]),
        b8(f["ln2_vsh"], f["ln2_nsh"], f["ln2_ash"], f["gelu_hi"]),
        f["ln1_eps"] | (f["ln2_eps"] << 16),
    ]
    return words, f


def linear_fields(pf, b, name):
    key = f"{b}.{name}"
    spec = pf.p["linears"][key]
    w = pf.arr(key + ".weight").astype(np.int64)
    if spec["weight_bits"] != 4 or w.shape != (spec["in_features"], spec["out_features"]):
        raise ValueError(f"{key}: expected W4 [in,out] weight")
    if w.min() < -8 or w.max() > 7:
        raise ValueError(f"{key}: W4 range")
    bias = pf.arr(key + ".bias").astype(np.int64)
    if not HAS_BIAS[name] and np.any(bias != 0):
        raise ValueError(f"{key}: nonzero bias cannot be dropped")
    we = pf.arr(key + ".weight_exponents").astype(np.int64)
    shift = pf.p["exponents"][spec["output"]] - pf.p["exponents"][spec["input"]] - we
    return w, bias, shift


def pack(profile_dir, output_dir, array_r=R, array_c=C):
    pf = Profile(profile_dir)
    stream, layers = [], []

    def add(tag, words, layer):
        layer["fields"].append({"name": tag, "offset": len(stream), "words": len(words)})
        stream.extend(int(x) & 0xFFFFFFFF for x in words)

    for li, b in enumerate(pf.p["blocks"]):
        layer = {"block": b, "start": len(stream), "fields": []}
        hw, hf = layer_header(pf, b)
        layer["header"] = hf
        add("header", hw + [0] * (HEADER_WORDS - len(hw)), layer)

        def emit_linear(name):
            w, bias, shift = linear_fields(pf, b, name)
            K, N = w.shape
            for cb in range(N // array_c):
                ch = slice(cb * array_c, (cb + 1) * array_c)
                if HAS_BIAS[name]:
                    add(f"{name}.cb{cb}.bias", pack_fields(bias[ch], 16, True), layer)
                sw = pack_fields(shift[ch], SHIFT_BITS, True)
                add(f"{name}.cb{cb}.shift", sw + [0] * (SHIFT_WORDS - len(sw)), layer)
                wwords = []
                for kb in range(K // array_r):
                    for r in range(array_r):
                        row = w[kb * array_r + r, ch]
                        for q in range(array_c // 8):
                            x = 0
                            for j in range(8):
                                x |= (int(row[8 * q + j]) & 15) << (4 * j)
                            wwords.append(x)
                add(f"{name}.cb{cb}.weight", wwords, layer)

        def emit_ln(ln):
            gamma = pf.arr(f"{b}.{ln}.gamma").astype(np.int64)
            beta = pf.arr(f"{b}.{ln}.beta").astype(np.int64)
            add(f"{ln}.gamma", pack_fields(gamma, 16, False), layer)
            add(f"{ln}.beta", pack_fields(beta, 8, True), layer)

        for name in ("q", "k", "v", "proj"):
            emit_linear(name)
        emit_ln("ln1")
        emit_linear("fc1")
        emit_linear("fc2")
        emit_ln("ln2")
        layer["words"] = len(stream) - layer["start"]
        layers.append(layer)

    out = Path(output_dir)
    out.mkdir(parents=True, exist_ok=True)
    (out / "params.bin").write_bytes(struct.pack("<%dI" % len(stream), *stream))
    (out / "params.hex").write_text("".join("%08x\n" % x for x in stream))
    manifest = {"format": "kse-param-stream-v3", "word_bytes": 4, "R": array_r, "C": array_c,
                "word_count": len(stream), "layer_words": [l["words"] for l in layers],
                "profile": "profile/profile.json", "blocks": layers}
    (out / "params.json").write_text(json.dumps(manifest, indent=1) + "\n")
    return manifest


def verify(profile_dir, output_dir, array_r=R, array_c=C):
    """Decode params.bin field by field and compare with the profile arrays."""
    pf = Profile(profile_dir)
    d = json.loads((Path(output_dir) / "params.json").read_text())
    raw = (Path(output_dir) / "params.bin").read_bytes()
    words = struct.unpack("<%dI" % (len(raw) // 4), raw)
    if len(words) != d["word_count"]:
        raise ValueError("size mismatch")
    pos = 0
    checked = 0

    def take(n):
        nonlocal pos
        seg = words[pos:pos + n]
        pos += n
        return seg

    for b in pf.p["blocks"]:
        hw, hf = layer_header(pf, b)
        if list(take(HEADER_WORDS)) != hw + [0] * (HEADER_WORDS - len(hw)):
            raise ValueError(f"{b}: header mismatch")
        checked += HEADER_WORDS

        def check_linear(name):
            nonlocal checked
            w, bias, shift = linear_fields(pf, b, name)
            K, N = w.shape
            for cb in range(N // array_c):
                ch = slice(cb * array_c, (cb + 1) * array_c)
                if HAS_BIAS[name]:
                    got = unpack_fields(take(array_c // 2), array_c, 16, True)
                    if got != list(bias[ch]):
                        raise ValueError(f"{b}.{name} bias cb{cb}")
                seg = take(SHIFT_WORDS)
                if any(seg[6:]):
                    raise ValueError("shift pad")
                got = unpack_fields(seg, array_c, SHIFT_BITS, True)
                if got != list(shift[ch]):
                    raise ValueError(f"{b}.{name} shift cb{cb}")
                for kb in range(K // array_r):
                    for r in range(array_r):
                        nib = unpack_fields(take(array_c // 8), array_c, 4, True)
                        if nib != list(w[kb * array_r + r, ch]):
                            raise ValueError(f"{b}.{name} weight cb{cb} kb{kb} r{r}")
            checked += w.size + N + (N if HAS_BIAS[name] else 0)

        def check_ln(ln):
            nonlocal checked
            if unpack_fields(take(32), D, 16, False) != list(pf.arr(f"{b}.{ln}.gamma")):
                raise ValueError(f"{b}.{ln} gamma")
            if unpack_fields(take(16), D, 8, True) != list(pf.arr(f"{b}.{ln}.beta")):
                raise ValueError(f"{b}.{ln} beta")
            checked += 2 * D

        for name in ("q", "k", "v", "proj"):
            check_linear(name)
        check_ln("ln1")
        check_linear("fc1")
        check_linear("fc2")
        check_ln("ln2")
    if pos != len(words) or len(words) % 4:
        raise ValueError("trailing words")
    return len(words), checked


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--profile", required=True, help="golden profile/ directory")
    ap.add_argument("--output-dir", required=True)
    ap.add_argument("--verify", action="store_true", help="only verify an existing stream")
    ap.add_argument("--array-r", type=int, choices=(16, 32), default=R)
    ap.add_argument("--array-c", type=int, choices=(32,), default=C)
    a = ap.parse_args()
    if not a.verify:
        m = pack(a.profile, a.output_dir, a.array_r, a.array_c)
        print(f"PARAM_PACKED {m['word_count']} words, per layer {m['layer_words']}")
    n, c = verify(a.profile, a.output_dir, a.array_r, a.array_c)
    print(f"PARAM_VERIFY_OK {n} words, {c} profile values round-tripped")


if __name__ == "__main__":
    main()
