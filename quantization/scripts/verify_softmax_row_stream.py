"""Compare full attention, row streaming and query tiles with checked int32 partial sums."""
import argparse
import json
import os
import sys
from pathlib import Path

for _key in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_key, "1")
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import numpy as np
from quantization.export import load_profile
from quantization.integer import IntegerEncoder, configure_profile, quantize, saturate, shift_rne
try:
    from .run_global_w4_modes import load_full_w4, make_config
except ImportError:  # direct script execution
    from run_global_w4_modes import load_full_w4, make_config


def partial_mac(a, b, stats, key):
    """Every product/add checked; int64 is only the overflow-check oracle."""
    if a.ndim != 2 or b.ndim != 2 or a.shape[-1] != b.shape[0]:
        raise ValueError("partial_mac expects compatible rank-2 matrices")
    out = np.zeros(a.shape[:-1] + (b.shape[-1],), dtype=np.int32)
    lo, hi = 0, 0
    for k in range(a.shape[-1]):
        prod = a[..., k:k+1].astype(np.int64) * b[..., k:k+1, :].astype(np.int64)
        # Remove the reduction axis introduced in the RHS slice.
        prod = np.squeeze(prod, axis=-2) if prod.ndim > out.ndim else prod
        if int(prod.min()) < -(1 << 31) or int(prod.max()) > (1 << 31)-1:
            raise OverflowError(key + " int32 product overflow")
        total = out.astype(np.int64) + prod
        minimum, maximum = int(total.min()), int(total.max())
        if minimum < -(1 << 31) or maximum > (1 << 31)-1:
            raise OverflowError(key + " int32 partial accumulator overflow")
        lo, hi = min(lo, minimum), max(hi, maximum)
        out = total.astype(np.int32)
    previous = stats.setdefault(key, {"minimum": 0, "maximum": 0, "required_bits": 1})
    previous["minimum"] = min(previous["minimum"], lo)
    previous["maximum"] = max(previous["maximum"], hi)
    previous["required_bits"] = max(previous["maximum"].bit_length()+1,
                                    (~previous["minimum"]).bit_length()+1)
    return out


def verify(root, samples=24):
    folder = root / "experiments" / "w4w8_nonlinear_v1"
    # The legacy mixed-precision acceptance report may be renamed to
    # ``acceptance_stale_*.json`` when the experiment identity changes.  The
    # global W4/A8 rerun itself is the authoritative source for this check;
    # fall back to its two completed configurations when the legacy report is
    # absent.
    acceptance = folder / "reports" / "acceptance.json"
    if acceptance.is_file():
        weights_map = load_full_w4(acceptance)
    else:
        global_report = json.loads((folder / "reports" / "global_w4_modes.json").read_text(encoding="utf-8"))
        maps = [item.get("config", {}).get("weight_bits_by_linear", {})
                for item in global_report.get("configs", [])]
        weights_map = next((value for value in maps
                            if len(value) == 72 and all(int(bits) == 4 for bits in value.values())), None)
        if weights_map is None:
            raise RuntimeError("global W4/A8 report has no complete 72-matrix W4 weight map")
    p0, a0 = load_profile(root / "profiles" / "W8A8_integer")
    with np.load(folder / "cache" / "weights.npz") as src:
        weights = {k: src[k] for k in src.files}
    selection = json.loads((folder / "reports" / "audit_selections.json").read_text())
    if not 1 <= samples <= 24:
        raise ValueError("samples must be between 1 and 24")
    source = selection["selections"]["golden"]
    indices = source["indices"][:samples]
    with np.load(source["source_cache"]) as src:
        boundary = src["boundary"][indices]
        if not np.array_equal(src["labels"][indices], source["labels"][:samples]):
            raise ValueError("golden source labels changed")
    report = {"scope": "fixed validation golden samples; schedule equivalence, not RTL verification",
              "source_cache": source["source_cache"], "identity": selection["identity"],
              "indices": indices, "mac_accumulator_bits": 32, "partial_check": "every reduction step",
              "modes": [], "status": "running"}
    for pf, lf in ((7, 12), (11, 16)):
        p, a = configure_profile(p0, a0, weights, make_config(weights_map, pf, lf))
        assert p["accumulator_bits"] == 32 and p["residual_accumulator_bits"] == 32
        enc = IntegerEncoder(p, a)
        item = {"prob_frac": pf, "ln_frac": lf, "samples": len(indices), "tiles": [], "partial_ranges": {}}
        # One sample at a time bounds memory and avoids retaining a full dataset trace.
        for tile in (1, 8):
            checked = 0
            for x in boundary:
                _, traces = enc.run(quantize(x, p["exponents"]["b00.input"], 8), trace=True)
                for block in p["blocks"]:
                    q, k, v = (traces[block + "." + name] for name in ("q", "k", "v"))
                    for start in range(0, 99, tile):
                        end = min(start+tile, 99)
                        acc = partial_mac(q[start:end], k.T, item["partial_ranges"], block+".qk")
                        se = p["exponents"][block+".q"] + p["exponents"][block+".k"] + p["attention_scale_exponent"]
                        score = saturate(shift_rne(acc, p["exponents"][block+".score"]-se), 8)
                        prob = enc.softmax(score, p["exponents"][block+".score"], block+".softmax")
                        acc = partial_mac(prob, v, item["partial_ranges"], block+".pv")
                        ctx = saturate(shift_rne(acc, p["exponents"][block+".context"]+pf-p["exponents"][block+".v"]), 8)
                        for name, actual in (("score",score),("softmax",prob),("context",ctx)):
                            if not np.array_equal(actual, traces[block+"."+name][start:end]):
                                raise AssertionError("schedule mismatch: " + block + "." + name)
                            checked += actual.size
            item["tiles"].append({"query_rows": tile, "compared_elements": checked, "mismatches": 0, "bit_exact": True})
            print("P%d tile=%d exact; %d compared elements" % (pf, tile, checked), flush=True)
        item["overflow_count"] = 0
        report["modes"].append(item)
        (folder / "reports" / "softmax_row_stream.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    report["status"] = "verified"
    (folder / "reports" / "softmax_row_stream.json").write_text(json.dumps(report, indent=2), encoding="utf-8")
    return report


if __name__ == "__main__":
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    ap.add_argument("--samples", type=int, default=24)
    args = ap.parse_args()
    verify(Path(args.data_root), args.samples)
