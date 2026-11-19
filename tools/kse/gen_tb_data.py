#!/usr/bin/env python3
"""Convert the frozen golden package into text vectors for the KSE VCS testbenches.

Nothing here computes an expected output: every expected value is read from
the frozen golden files (operators/ or sample traces).  Stimulus that is not
stored in the package (MAC accumulators feeding the post-processing lane) is
formed with plain integer matrix products of golden tensors.

  units   -> post.txt softmax.txt ln.txt            (stage 2)
  samples -> sNN_sample_input.hex, sNN_sample_output.hex, sNN_<tensor>.hex (12 layers each)
"""
import argparse
import json
import sys
from pathlib import Path

import numpy as np

sys.path.insert(0, str(Path(__file__).resolve().parent))
import pack_params as pp  # noqa: E402

TENSORS = ("input", "q", "k", "v", "score", "softmax", "context", "proj", "res1",
           "ln1", "fc1", "gelu", "fc2", "res2", "output")
LIN_IN = {"q": "input", "k": "input", "v": "input", "proj": "context", "fc1": "ln1", "fc2": "gelu"}


def h(v, bits):
    return "%0*x" % ((bits + 3) // 4, int(v) & ((1 << bits) - 1))


class Golden:
    def __init__(self, root):
        self.root = Path(root)
        self.pf = pp.Profile(self.root / "profile")
        self.blocks = self.pf.p["blocks"]
        self.ops = json.loads((self.root / "operators" / "operator_manifest.json").read_text())

    def trace(self, s, b, name):
        return np.load(self.root / f"sample_{s:02d}_trace_{b}__{name}.npy").astype(np.int64)

    def op(self, fname):
        return np.load(self.root / "operators" / fname).astype(np.int64)


def gen_units(g, out):
    s = 0
    # ---------------- post-processing lane ----------------
    n_post = 0
    with open(out / "post.txt", "w") as f:
        def emit(acc, bias, sh, gelu, layer, lo, hi, tail, pre, y):
            nonlocal n_post
            f.write(" ".join((h(acc, 24), h(bias, 16), h(sh, 8), h(gelu, 1), h(layer, 4),
                              h(lo, 8), h(hi, 8), h(tail, 8), h(pre, 8), h(y, 8))) + "\n")
            n_post += 1
        for li, b in enumerate(g.blocks):
            _, hf = pp.layer_header(g.pf, b)
            gl = (hf["gelu_lo"], hf["gelu_hi"], hf["gelu_tail"])
            for name in ("q", "k", "v", "proj", "fc1", "fc2"):
                w, bias, shift = pp.linear_fields(g.pf, b, name)
                x = g.trace(s, b, LIN_IN[name])
                acc = x @ w
                assert np.abs(acc + bias).max() < (1 << 23)
                pre = g.trace(s, b, name)
                y = g.trace(s, b, "gelu") if name == "fc1" else pre
                for t in range(acc.shape[0]):
                    for c in range(acc.shape[1]):
                        emit(acc[t, c], bias[c], shift[c], name == "fc1", li, *gl, pre[t, c], y[t, c])
            q, k, v = (g.trace(s, b, n) for n in ("q", "k", "v"))
            acc = q @ k.T
            sc = g.trace(s, b, "score")
            for t in range(99):
                for j in range(99):
                    emit(acc[t, j], 0, hf["score_sh"], 0, li, *gl, sc[t, j], sc[t, j])
            acc = g.trace(s, b, "softmax") @ v
            cx = g.trace(s, b, "context")
            for t in range(99):
                for c in range(64):
                    emit(acc[t, c], 0, hf["ctx_sh"], 0, li, *gl, cx[t, c], cx[t, c])
        # GELU operator vectors: acc = x, bias 0, shift 0 -> pre = x
        for vec in g.ops["vectors"]:
            if vec["operator"] != "gelu":
                continue
            li = g.blocks.index(vec["key"].split(".")[0])
            _, hf = pp.layer_header(g.pf, g.blocks[li])
            xi = g.op(vec["tensors"]["input"]["npy"])
            yo = g.op(vec["tensors"]["output"]["npy"])
            for x, y in zip(xi, yo):
                emit(x, 0, 0, 1, li, hf["gelu_lo"], hf["gelu_hi"], hf["gelu_tail"], x, y)

    # ---------------- softmax ----------------
    # line per row: tag q8_sh then 99 input bytes then 99 expected bytes
    n_sm_rows = 0
    with open(out / "softmax.txt", "w") as f:
        def emit_rows(tag, q8, x, y):
            nonlocal n_sm_rows
            for r in range(x.shape[0]):
                f.write(f"{tag} {h(q8, 8)} " + " ".join(h(v, 8) for v in x[r]) + " "
                        + " ".join(h(v, 8) for v in y[r]) + "\n")
                n_sm_rows += 1
        for vec in g.ops["vectors"]:
            if vec["operator"] != "softmax":
                continue
            li = g.blocks.index(vec["key"].split(".")[0])
            _, hf = pp.layer_header(g.pf, g.blocks[li])
            emit_rows(0, hf["q8_sh"], g.op(vec["tensors"]["input"]["npy"]), g.op(vec["tensors"]["output"]["npy"]))
        for li, b in enumerate(g.blocks):
            _, hf = pp.layer_header(g.pf, b)
            emit_rows(1, hf["q8_sh"], g.trace(s, b, "score"), g.trace(s, b, "softmax"))

    # ---------------- residual + layernorm ----------------
    # line per token: kind ax ay vsh nsh ash eps gamma[64] beta[64] x[64] y[64] exp_res[64] exp_out[64]
    # kind 0 = operator vector (y=0, shifts 0, residual unchecked), 1 = res1/ln1, 2 = res2/ln2
    n_ln = 0
    with open(out / "ln.txt", "w") as f:
        def emit_tok(kind, ax, ay, vsh, nsh, ash, eps, gamma, beta, x, y, r, o):
            nonlocal n_ln
            fields = [str(kind), h(ax, 8), h(ay, 8), h(vsh, 8), h(nsh, 8), h(ash, 8), h(eps, 16)]
            fields += [h(v, 16) for v in gamma] + [h(v, 8) for v in beta]
            fields += [h(v, 8) for v in x] + [h(v, 8) for v in y] + [h(v, 8) for v in r] + [h(v, 8) for v in o]
            f.write(" ".join(fields) + "\n")
            n_ln += 1
        for vec in g.ops["vectors"]:
            if vec["operator"] != "layernorm":
                continue
            b, ln = vec["key"].split(".")
            _, hf = pp.layer_header(g.pf, b)
            gamma = g.pf.arr(f"{b}.{ln}.gamma")
            beta = g.pf.arr(f"{b}.{ln}.beta")
            xi = g.op(vec["tensors"]["input"]["npy"])
            yo = g.op(vec["tensors"]["output"]["npy"])
            for t in range(xi.shape[0]):
                emit_tok(0, 0, 0, hf[ln + "_vsh"], hf[ln + "_nsh"], hf[ln + "_ash"], hf[ln + "_eps"],
                         gamma, beta, xi[t], np.zeros(64, np.int64), xi[t], yo[t])
        for b in g.blocks:
            _, hf = pp.layer_header(g.pf, b)
            for kind, ln, xn, yn, rn, on, axk, ayk in ((1, "ln1", "input", "proj", "res1", "ln1", "res1_ax", "res1_ay"),
                                                       (2, "ln2", "ln1", "fc2", "res2", "output", "res2_ax", "res2_ay")):
                gamma = g.pf.arr(f"{b}.{ln}.gamma")
                beta = g.pf.arr(f"{b}.{ln}.beta")
                X, Y, Rr, O = (g.trace(s, b, n) for n in (xn, yn, rn, on))
                for t in range(99):
                    emit_tok(kind, hf[axk], hf[ayk], hf[ln + "_vsh"], hf[ln + "_nsh"], hf[ln + "_ash"],
                             hf[ln + "_eps"], gamma, beta, X[t], Y[t], Rr[t], O[t])
    print(f"UNIT_VECTORS post={n_post} softmax_rows={n_sm_rows} ln_tokens={n_ln}")


def gen_samples(g, out, samples):
    for s in samples:
        def dump(name, arr):
            a = np.asarray(arr, dtype=np.int64).reshape(-1)
            (out / f"s{s:02d}_{name}.hex").write_text("".join(h(v, 8) + "\n" for v in a))
        dump("sample_input", np.load(g.root / f"sample_{s:02d}_input_int.npy"))
        dump("sample_output", np.load(g.root / f"sample_{s:02d}_output.npy"))
        for name in TENSORS:
            dump(name, np.stack([g.trace(s, b, name) for b in g.blocks]))
    print(f"SAMPLE_VECTORS {len(samples)} samples")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--golden", required=True)
    ap.add_argument("--out", required=True)
    ap.add_argument("what", choices=("units", "samples"))
    ap.add_argument("--samples", default="0")
    ap.add_argument("--unit-limit", type=int, default=1024, help="maximum rows per unit vector file; 0 keeps all")
    a = ap.parse_args()
    g = Golden(a.golden)
    out = Path(a.out)
    out.mkdir(parents=True, exist_ok=True)
    if a.what == "units":
        gen_units(g, out)
        if a.unit_limit:
            for path in out.glob("*.txt"):
                rows = path.read_text().splitlines(True)
                if len(rows) > a.unit_limit:
                    ids = np.linspace(0, len(rows)-1, a.unit_limit, dtype=int)
                    path.write_text("".join(rows[i] for i in ids))
    else:
        sl = list(range(24)) if a.samples == "all" else [int(x) for x in a.samples.split(",")]
        gen_samples(g, out, sl)


if __name__ == "__main__":
    main()
