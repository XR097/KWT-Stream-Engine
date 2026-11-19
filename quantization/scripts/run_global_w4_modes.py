"""Run two global-format full-W4 experiments without changing frozen quantization code."""
import argparse
import copy
import json
import os
import sys
from concurrent.futures import as_completed
from pathlib import Path
from types import SimpleNamespace


def load_full_w4(report_path):
    data = json.loads(Path(report_path).read_text(encoding="utf-8"))
    candidates = []
    for result in data.get("results", []):
        cfg = result.get("config", {})
        bits = cfg.get("weight_bits_by_linear", {})
        if bits and len(bits) == 72 and all(int(v) == 4 for v in bits.values()):
            candidates.append(bits)
    if not candidates:
        raise RuntimeError("acceptance.json does not contain a full-W4 candidate")
    return copy.deepcopy(candidates[0])


def make_config(weight_map, prob_frac, ln_frac):
    return {
        "gelu": "middle",
        "residual_accumulator_bits": 32,
        "weight_bits_by_linear": copy.deepcopy(weight_map),
        "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": prob_frac},
        "layernorm": {"method": "reference", "norm_frac": ln_frac, "gamma_frac": ln_frac},
    }


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    ap.add_argument("--repo-root", default=str(Path(__file__).resolve().parents[2]))
    ap.add_argument("--workers", type=int, default=4)
    args = ap.parse_args()
    root = Path(args.data_root).resolve()
    folder = root / "experiments" / "w4w8_nonlinear_v1"
    acceptance = folder / "reports" / "acceptance.json"
    weight_map = load_full_w4(acceptance)
    configs = [
        ("all_w4_q15_p7_ln12", make_config(weight_map, 7, 12)),
        ("all_w4_q15_p11_ln16", make_config(weight_map, 11, 16)),
    ]

    # Keep BLAS deterministic and avoid accidentally using the GPU.
    os.environ.setdefault("CUDA_VISIBLE_DEVICES", "-1")
    os.environ.setdefault("OMP_NUM_THREADS", "1")
    os.environ.setdefault("OPENBLAS_NUM_THREADS", "1")
    os.environ.setdefault("MKL_NUM_THREADS", "1")
    sys.path.insert(0, str(Path(args.repo_root).resolve()))
    from quantization.experiments import Experiment, _evaluate_job, config_id

    exp = Experiment(SimpleNamespace(data_root=str(root), repo_root=args.repo_root,
                                     workers=args.workers))
    if int(exp.base[0].get("accumulator_bits", 64)) != 32:
        exp.close()
        raise ValueError("the base profile must have int32 MAC accumulators")
    report = {"status": "running", "source_acceptance": str(acceptance),
              "identity": exp.identity,
              "weight_count": len(weight_map), "configs": []}
    try:
        futures = {}
        records = {}
        for name, config in configs:
            records[name] = {"name": name, "config": config, "config_id": config_id(config)}
            for split in ("validation_full", "testing"):
                job = {"config": config, "split": split, "diagnostic": True, "start_block": 0}
                futures[exp.pool.submit(_evaluate_job, job)] = (name, split)
                print("queued", name, split, flush=True)
        for future in as_completed(futures):
            name, split = futures[future]
            result = future.result()
            records[name][split] = result
            test = records[name].get("testing", {})
            records[name]["pass"] = bool(test.get("status") == "complete" and test.get("drop_pp", 999.) <= 2.0)
            report["configs"] = list(records.values())
            out = folder / "reports" / "global_w4_modes.json"
            out.write_text(json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
            print(name, split, result.get("count"), result.get("top1"), result.get("status"), flush=True)
    finally:
        exp.close()
    report["status"] = ("complete" if all(x.get(s, {}).get("status") == "complete"
                                          for x in report["configs"] for s in ("validation_full", "testing")) else "failed")
    (folder / "reports" / "global_w4_modes.json").write_text(
        json.dumps(report, ensure_ascii=False, indent=2), encoding="utf-8")
    print(json.dumps({"status": report["status"],
                      "configs": [{"name": x["name"],
                                   "validation_top1": x["validation_full"].get("top1"),
                                   "testing_top1": x["testing"].get("top1"),
                                   "testing_drop_pp": x["testing"].get("drop_pp"),
                                   "pass": x["pass"]} for x in report["configs"]]},
                     ensure_ascii=False, indent=2))


if __name__ == "__main__":
    main()
