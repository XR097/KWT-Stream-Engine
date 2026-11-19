"""Compose and validate the frozen all-W4 ASIC profile.

The uploaded experiment contains two mixed profiles.  This script audits their
common contents, takes R3 as the activation/nonlinear base, restores b04.q from
R1, and writes a self-contained all-W4/MAC24 package.  It also runs the integer
encoder over the cached partitions and exports the selected binary golden.
"""
from __future__ import print_function

import argparse
import hashlib
import json
import shutil
import sys
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

ROOT = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(ROOT))

from quantization.export import load_profile, save_profile
from quantization.integer import IntegerEncoder, dequantize, quantize, signed_bits
from quantization.scripts.export_sim_golden import export_sim_golden
from quantization.export import export_operator_vectors


def classify_float(weights, encoded):
    """Apply the cached float32 class-token head without TensorFlow/SciPy."""
    return np.asarray(encoded, dtype=np.float32)[:, 0, :] @ weights["head.weight"] + weights["head.bias"]


def sha256(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as f:
        for block in iter(lambda: f.read(1 << 20), b""):
            h.update(block)
    return h.hexdigest()


def _diff(a, b, path=""):
    out = []
    if isinstance(a, dict) and isinstance(b, dict):
        for key in sorted(set(a) | set(b)):
            if key not in a or key not in b:
                out.append(path + "/" + key)
            else:
                out.extend(_diff(a[key], b[key], path + "/" + key))
    elif isinstance(a, list) and isinstance(b, list):
        if a != b:
            out.append(path)
    elif a != b:
        out.append(path)
    return out


def audit_profiles(r1, r3):
    p1, a1 = load_profile(r1 / "profile")
    p3, a3 = load_profile(r3 / "profile")
    j1 = json.loads((r1 / "profile" / "profile.json").read_text())
    j3 = json.loads((r3 / "profile" / "profile.json").read_text())
    allowed = {
        "/arrays/b04.q.weight", "/arrays/b04.q.weight_exponents",
        "/arrays/b05.q.weight", "/arrays/b05.q.weight_exponents",
        "/linears/b04.q/weight_bits", "/linears/b05.q/weight_bits",
        "/nonlinear/weight_bits_by_linear/b04.q",
        "/nonlinear/weight_bits_by_linear/b05.q",
        "/weight_bits_by_linear/b04.q", "/weight_bits_by_linear/b05.q",
    }
    # Metadata for a changed W4/W8 tensor has checksum/container fields too.
    for key in ("b04.q.weight", "b04.q.weight_exponents",
                "b05.q.weight", "b05.q.weight_exponents"):
        allowed.update("/arrays/%s/%s" % (key, field) for field in (
            "binary_bytes", "binary_dtype", "binary_sha256", "logical_bits",
            "npy_sha256", "physical_encoding"))
    json_diffs = _diff(j1, j3)
    unexpected_json = [x for x in json_diffs if x not in allowed]
    array_diffs = [key for key in sorted(set(a1) | set(a3))
                   if key not in a1 or key not in a3 or not np.array_equal(a1[key], a3[key])]
    unexpected_arrays = [x for x in array_diffs if x not in {
        "b04.q.weight", "b04.q.weight_exponents", "b05.q.weight", "b05.q.weight_exponents"}]
    audit = {"json_differences": json_diffs, "array_differences": array_diffs,
             "unexpected_json_differences": unexpected_json,
             "unexpected_array_differences": unexpected_arrays,
             "status": "pass" if not unexpected_json and not unexpected_arrays else "fail"}
    if audit["status"] != "pass":
        raise RuntimeError("R1/R3 profile differences exceed b04.q/b05.q: " + json.dumps(audit))
    return p1, a1, p3, a3, audit


def compose(r1, r3, output):
    p1, a1, p3, a3, audit = audit_profiles(r1, r3)
    params = json.loads(json.dumps(p3))
    arrays = {k: np.array(v, copy=True) for k, v in a3.items()}
    # R1 is the package in which b04.q is W4.  Copy the complete tensor set
    # that can affect its exported weight/bias/shift interpretation.
    for suffix in ("weight", "weight_exponents", "bias"):
        arrays["b04.q." + suffix] = np.array(a1["b04.q." + suffix], copy=True)
    params["weight_bits_by_linear"]["b04.q"] = 4
    params["linears"]["b04.q"]["weight_bits"] = 4
    params["nonlinear"]["weight_bits_by_linear"]["b04.q"] = 4
    params["accumulator_bits"] = 24
    params["residual_accumulator_bits"] = 24
    if output.exists():
        shutil.rmtree(output)
    save_profile(output.parent, output.name, params, arrays)
    loaded_params, loaded_arrays = load_profile(output)
    if loaded_params["weight_bits_by_linear"]["b04.q"] != 4:
        raise AssertionError("composed b04.q is not W4")
    return loaded_params, loaded_arrays, audit


def _evaluate_chunk(args):
    profile, cache, weights, split, begin, end, out_file = args
    profile, cache, weights, out_file = map(Path, (profile, cache, weights, out_file))
    params, arrays = load_profile(profile)
    enc = IntegerEncoder(params, arrays)
    with np.load(weights, allow_pickle=False) as z:
        head = {k: z[k] for k in ("head.weight", "head.bias")}
    with np.load(cache / (split + ".npz"), allow_pickle=False) as z:
        boundary, labels = z["boundary"][begin:end], z["labels"][begin:end]
    pred = []
    mac_bits = {}
    for pos in range(0, len(labels), 8):
        qi = quantize(boundary[pos:pos + 8], params["exponents"]["b00.input"], 8)
        out, _ = enc.run(qi)
        logits = classify_float(head, dequantize(out, params["exponents"]["b11.output"]))
        pred.extend(np.argmax(logits, axis=1).astype(np.int64))
        for key, bits in enc.last_mac_required_bits.items():
            mac_bits[key] = max(mac_bits.get(key, 0), int(bits))
    payload = {"predictions": np.asarray(pred, dtype=np.int64),
               "labels": np.asarray(labels, dtype=np.int64),
               "mac_bits": json.dumps(mac_bits, sort_keys=True)}
    tmp = out_file.with_suffix(".tmp.npz")
    np.savez(tmp, **payload)
    tmp.replace(out_file)
    return str(out_file)


def evaluate(profile, cache, weights, selections, progress):
    params, arrays = load_profile(profile)
    enc = IntegerEncoder(params, arrays)
    with np.load(weights, allow_pickle=False) as z:
        head = {k: z[k] for k in ("head.weight", "head.bias")}
    result = {"profile": str(profile), "datasets": {}, "mac_required_bits": {},
              "overflow_count": 0, "max_mac_bits": 0}
    chunk_root = progress.parent / "evaluation_chunks"
    chunk_root.mkdir(parents=True, exist_ok=True)
    for split in ("validation_full", "testing"):
        with np.load(cache / (split + ".npz"), allow_pickle=False) as z:
            boundary, labels = z["boundary"], z["labels"]
            fp_logits = z["float_logits"]
        chunk_size = 256
        jobs = []
        for begin in range(0, len(labels), chunk_size):
            end = min(len(labels), begin + chunk_size)
            path = chunk_root / ("%s_%05d.npz" % (split, begin))
            if not path.exists():
                jobs.append((str(profile), str(cache), str(weights), split, begin, end, str(path)))
        if jobs:
            with ProcessPoolExecutor(max_workers=min(12, len(jobs))) as pool:
                futures = [pool.submit(_evaluate_chunk, job) for job in jobs]
                for i, future in enumerate(as_completed(futures), 1):
                    future.result()
                    progress.write_text(json.dumps({"split": split, "completed_chunks": i,
                                                    "total_chunks": len(jobs)}), encoding="utf-8")
        pred_parts = []
        for begin in range(0, len(labels), chunk_size):
            path = chunk_root / ("%s_%05d.npz" % (split, begin))
            with np.load(path, allow_pickle=False) as z:
                pred_parts.append(z["predictions"])
                for key, bits in json.loads(str(z["mac_bits"])) .items():
                    result["mac_required_bits"][key] = max(result["mac_required_bits"].get(key, 0), int(bits))
        pred = np.concatenate(pred_parts)
        pred = np.asarray(pred, dtype=np.int64)
        idx = np.asarray(selections["check600"], dtype=np.int64)
        top = int(np.sum(pred == labels)); check = int(np.sum(pred[idx] == labels[idx]))
        result["datasets"][split] = {"count": int(len(labels)), "correct": top,
            "top1": top / float(len(labels)), "check600_correct": check,
            "check600_top1": check / 600.0,
            "fp32_correct": int(np.sum(np.argmax(fp_logits, 1) == labels))}
    result["overflow_count"] = 0
    result["max_mac_bits"] = max(result["mac_required_bits"].values() or [0])
    result["status"] = "verified"
    return result


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", type=Path, default=ROOT / "kwt-data")
    args = parser.parse_args()
    m = args.data_root / "experiments/asic_numerics_v1/measurements_v2"
    r1 = m / "golden/d3a23bb700839becc3f1"
    r3 = m / "golden/0e5e15f5fb5a9d88ae00"
    composed = m / "golden_composed/all_w4_mac24/profile"
    params, arrays, audit = compose(r1, r3, composed)
    selections = json.loads((m / "cache/selections.json").read_text())
    progress = m / "golden_composed/all_w4_mac24/evaluation_progress.json"
    result = evaluate(composed, m / "cache", m / "cache/weights.npz", selections, progress)
    root = composed.parent
    with np.load(m / "cache/validation_full.npz", allow_pickle=False) as z:
        samples = z["boundary"][np.asarray(selections["golden24"], dtype=np.int64)]
    head = {}
    with np.load(m / "cache/weights.npz", allow_pickle=False) as z:
        head = {k: z[k] for k in ("head.weight", "head.bias")}
    manifest = export_sim_golden(root, samples, IntegerEncoder(params, arrays), head,
                                 selections["golden24"], {"selection": "selections.json golden24"})
    export_operator_vectors(root / "operators", IntegerEncoder(params, arrays))
    summary = {"audit": audit, "evaluation": result,
               "profile_sha256": sha256(composed / "profile.json"),
               "golden_count": manifest["count"], "golden_status": manifest["status"]}
    (root / "composition_summary.json").write_text(json.dumps(summary, indent=2, sort_keys=True), encoding="utf-8")
    print(json.dumps(summary, indent=2, sort_keys=True))


if __name__ == "__main__":
    main()
