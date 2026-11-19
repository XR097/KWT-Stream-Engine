"""Resumable CPU experiments; hardware figures are requirements, never area."""
import copy
import hashlib
import json
import math
import os
import shutil
import time
from concurrent.futures import ProcessPoolExecutor, as_completed
from pathlib import Path

import numpy as np

from .export import load_profile, save_profile, export_golden
from .integer import IntegerEncoder, configure_profile, quantize, dequantize
from .pipeline import (_json, _file_hash, _fingerprint, _merge_max,
                       _merge_saturation, _merge_errors, _final_errors)
from .reference import forward_float, classify_float


_WORKER = {}
REFERENCE = {"gelu": "reference", "softmax": {"table": "reference", "exp_frac": 24,
             "prob_frac": 15}, "layernorm": {"method": "reference", "norm_frac": 20,
             "gamma_frac": 20}}


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"))


def config_id(config):
    return hashlib.sha256(canonical(config).encode()).hexdigest()[:20]


def validate_saved_identity(value, identity):
    """Reject stale intermediate reports before they influence selection."""
    seen = 0
    if isinstance(value, dict):
        if "identity" in value:
            if value["identity"] != identity:
                raise ValueError("saved stage identity changed; rerun its prerequisite stage")
            seen += 1
        for key, child in value.items():
            if key != "identity":
                seen += validate_saved_identity(child, identity)
    elif isinstance(value, list):
        for child in value:
            seen += validate_saved_identity(child, identity)
    return seen


def check_space(path):
    if shutil.disk_usage(str(path)).free < 10 * 1024 ** 3:
        raise OSError("Less than 10 GiB free; experiment preserved for resume")


def _merge_ranges(destination, values):
    for key, value in values.items():
        if isinstance(value, dict):
            _merge_ranges(destination.setdefault(key, {}), value)
        elif isinstance(value, (int, float, np.integer, np.floating)):
            if key.endswith("min") or key == "minimum":
                destination[key] = min(destination.get(key, value), value)
            else:
                destination[key] = max(destination.get(key, value), value)
        else:
            destination[key] = value


def _init_worker(root, experiment, identity):
    global _WORKER
    root, experiment = Path(root), Path(experiment)
    p, a = load_profile(root / "profiles" / "W8A8_integer")
    with np.load(experiment / "cache" / "weights.npz") as archive:
        weights = {k: archive[k] for k in archive.files}
    _WORKER = {"root": root, "experiment": experiment, "base": (p, a),
               "weights": weights, "identity": identity, "datasets": {}}


def _dataset(split):
    w = _WORKER
    if split not in w["datasets"]:
        path = (w["experiment"] / "cache" / "validation_full.npz" if split == "validation_full"
                else w["root"] / "cache" / ("validation.npz" if split == "screen" else split + ".npz"))
        with np.load(path) as archive:
            data = {key: archive[key] for key in ("boundary", "labels", "float_logits")}
        if split == "screen":
            idx = np.concatenate([np.flatnonzero(data["labels"] == c)[:10] for c in range(12)])
            if len(idx) != 120:
                raise AssertionError("screen requires ten examples per class")
            data = {key: value[idx] for key, value in data.items()}
        w["datasets"][split] = data
    return w["datasets"][split]


def _evaluate_job(job):
    w = _WORKER
    config, split, diagnostic = job["config"], job["split"], job.get("diagnostic", False)
    key = config_id({"config": config, "split": split, "diagnostic": diagnostic,
                     "identity": w["identity"], "prefix": job.get("start_block", 0)})
    result_path = w["experiment"] / "results" / (key + ".json")
    progress_path = w["experiment"] / "progress" / (key + ".json")
    if result_path.exists():
        return json.loads(result_path.read_text(encoding="utf-8"))
    data = _dataset(split)
    p, a = configure_profile(*w["base"], w["weights"], config)
    encoder = IntegerEncoder(p, a)
    start_block = job.get("start_block", 0)
    prefix = None
    if start_block:
        prefix = np.load(w["experiment"] / "cache" / ("prefix_" + split + ".npz"))
        encoder.params = dict(p, blocks=p["blocks"][start_block:])
    n = len(data["labels"])
    if split == "testing" and n != 4890:
        raise AssertionError("formal testing must contain all 4890 samples")
    state = {"next_index": 0, "predictions": [], "logits": [], "seconds": 0.,
             "saturation": {}, "mac_required_bits": {}, "wide_required_bits": {},
             "residual_ranges": {}, "errors": {}, "sse": 0., "energy": 0.,
             "max_error": 0., "overflow_count": 0, "output_hashes": []}
    if progress_path.exists():
        state = json.loads(progress_path.read_text(encoding="utf-8"))
    try:
        for begin in range(state["next_index"], n, 32):
            end = min(n, begin + 32)
            boundary = data["boundary"][begin:end]
            if start_block:
                q = prefix["b%02d.input" % start_block][begin:end].astype(np.int64)
            else:
                q = quantize(boundary, p["exponents"]["b00.input"], 8)
            tick = time.perf_counter()
            out, traces = encoder.run(q, trace=diagnostic)
            state["seconds"] += time.perf_counter() - tick
            decoded = dequantize(out, p["exponents"]["b11.output"])
            logits = classify_float(w["weights"], decoded)
            if not np.all(np.isfinite(decoded)) or not np.all(np.isfinite(logits)):
                raise ArithmeticError("nonfinite encoder/classifier output")
            float_out, float_traces = (forward_float(w["weights"], boundary, trace=True)
                                       if diagnostic else (forward_float(w["weights"], boundary), {}))
            delta = decoded - float_out
            state["sse"] += float(np.sum(delta * delta))
            state["energy"] += float(np.sum(float_out.astype(np.float64) ** 2))
            state["max_error"] = max(state["max_error"], float(np.max(np.abs(delta))))
            if diagnostic:
                _merge_errors(state["errors"], traces, float_traces, p["exponents"])
            _merge_max(state["mac_required_bits"], encoder.last_mac_required_bits)
            _merge_max(state["wide_required_bits"], encoder.last_wide_required_bits)
            _merge_saturation(state["saturation"], encoder.last_saturation)
            _merge_ranges(state["residual_ranges"], getattr(encoder, "last_residual_stats", {}))
            state["predictions"].extend(np.argmax(logits, axis=1).tolist())
            state["logits"].extend(logits.tolist())
            state["output_hashes"].append(hashlib.sha256(out.astype("<i8").tobytes()).hexdigest())
            state["next_index"] = end
            _json(progress_path, state)
        labels = data["labels"]
        pred = np.asarray(state["predictions"])
        fp_pred = np.argmax(data["float_logits"], axis=1)
        confusion = np.zeros((12, 12), dtype=np.int64)
        np.add.at(confusion, (labels, pred), 1)
        top1, fp_top1 = float(np.mean(pred == labels)), float(np.mean(fp_pred == labels))
        weights_bytes = sum((int(v.size) * p.get("weight_bits_by_linear", {}).get(k[:-7], 8) + 7) // 8
                            for k, v in a.items() if k.endswith(".weight"))
        result = {"id": key, "config_id": config_id(config), "config": config,
                  "split": split, "status": "complete", "count": n,
                  "correct": int(np.sum(pred == labels)), "top1": top1, "float_top1": fp_top1,
                  "drop_pp": (fp_top1 - top1) * 100,
                  "agreement_float": float(np.mean(pred == fp_pred)),
                  "predictions": state["predictions"], "logits": state["logits"],
                  "seconds": state["seconds"], "samples_per_second": n / max(state["seconds"], 1e-12),
                  "nrmse": math.sqrt(state["sse"] / state["energy"]) if state["energy"] else None,
                  "max_error": state["max_error"], "trace_errors": _final_errors(state["errors"]),
                  "mac_required_bits": state["mac_required_bits"],
                  "wide_required_bits": state["wide_required_bits"],
                  "residual_ranges": state["residual_ranges"], "saturation": state["saturation"],
                  "saturation_count": sum(v["clipped"] for v in state["saturation"].values()),
                  "overflow_count": 0, "finite_outputs": True, "weight_bytes": weights_bytes,
                  "confusion_matrix": confusion.tolist(), "output_hashes": state["output_hashes"],
                  "partial_encoder_timing": bool(start_block), "diagnostic": diagnostic,
                  "pass": bool(n == 4890 and split == "testing" and top1 >= fp_top1 - .02),
                  "identity": w["identity"]}
    except (OverflowError, ArithmeticError, ValueError) as error:
        result = {"id": key, "config_id": config_id(config), "config": config, "split": split,
                  "count": state["next_index"], "status": "failed", "pass": False,
                  "error": str(error), "overflow_count": int(isinstance(error, OverflowError)),
                  "identity": w["identity"]}
    finally:
        if prefix is not None:
            prefix.close()
    _json(result_path, result)
    return result


class Experiment:
    def __init__(self, args):
        self.args = args
        self.root = Path(args.data_root).resolve()
        self.repo = Path(args.repo_root).resolve()
        self.folder = self.root / "experiments" / "w4w8_nonlinear_v1"
        for name in ("cache", "results", "progress", "reports", "profiles", "golden"):
            (self.folder / name).mkdir(parents=True, exist_ok=True)
        check_space(self.folder)
        profile_dir = self.root / "profiles" / "W8A8_integer"
        profile_hash = hashlib.sha256()
        for path in sorted(profile_dir.iterdir()):
            if path.is_file():
                profile_hash.update(path.name.encode()); profile_hash.update(_file_hash(path).encode())
        self.identity = {"code": _fingerprint(self.repo), "numpy": np.__version__,
                         "base_profile": profile_hash.hexdigest(),
                         "weights": _file_hash(self.folder / "cache" / "weights.npz"),
                         "calibration": _file_hash(self.root / "cache" / "calibration.json"),
                         "datasets": {s: _file_hash(self.root / "cache" / (s + ".npz"))
                                      for s in ("training", "validation", "testing")},
                         "validation_full": _file_hash(self.folder / "cache" / "validation_full.npz")}
        self.base = load_profile(self.root / "profiles" / "W8A8_integer")
        with np.load(self.folder / "cache" / "weights.npz") as source:
            self.weights = {key: source[key] for key in source.files}
        self.pool = ProcessPoolExecutor(max_workers=args.workers, initializer=_init_worker,
                                        initargs=(str(self.root), str(self.folder), self.identity))
        previous_path = self.folder / "reports" / "run_identity.json"
        previous_identity = json.loads(previous_path.read_text()) if previous_path.exists() else None
        acceptance_path = self.folder / "reports" / "acceptance.json"
        if previous_identity != self.identity and acceptance_path.exists():
            acceptance_path.replace(acceptance_path.with_name("acceptance_stale_%d.json" % time.time_ns()))
        _json(previous_path, self.identity)

    def close(self):
        self.pool.shutdown(wait=True)

    def evaluate(self, configs, split="validation", diagnostic=False, suffix=False):
        unique = {config_id(c): c for c in configs}
        pending = {}
        for key, config in unique.items():
            start = 0
            if suffix and config.get("weight_bits_by_linear"):
                start = min(int(k[1:3]) for k in config["weight_bits_by_linear"])
            job = {"config": config, "split": split, "diagnostic": diagnostic, "start_block": start}
            pending[self.pool.submit(_evaluate_job, job)] = key
        results = {}
        for future in as_completed(pending):
            value = future.result()
            results[pending[future]] = value
            print("%s %s %d top1=%s drop_pp=%s" % (split, value["config_id"], value["count"],
                  value.get("top1", value.get("error")), value.get("drop_pp")), flush=True)
        return [results[config_id(c)] for c in configs]

    def record(self, stage, values):
        _json(self.folder / "reports" / (stage + ".json"), values)


def baseline_config():
    return dict(copy.deepcopy(REFERENCE), residual_accumulator_bits=32)


def _good(result, maximum_drop=2.):
    return result["status"] == "complete" and result["drop_pp"] <= maximum_drop + 1e-10


def _precision_rank(result):
    if result["status"] != "complete":
        return (1, float("inf"), float("inf"), result["config_id"])
    return (0, -result["correct"], result["nrmse"], result["config_id"])


def _weight_rank(result):
    if result["status"] != "complete":
        return (1, float("inf"), float("inf"), float("inf"), float("inf"), result["config_id"])
    return (0, -result["correct"], -result["agreement_float"], result["nrmse"],
            result["weight_bytes"], result["config_id"])


def _float_alignment_job(split):
    w = _WORKER
    data = _dataset(split)
    maximum, mismatches = 0., 0
    for start in range(0, len(data["labels"]), 32):
        actual = classify_float(w["weights"], forward_float(w["weights"], data["boundary"][start:start+32]))
        expected = data["float_logits"][start:start+32]
        maximum = max(maximum, float(np.max(np.abs(actual - expected))))
        if not np.allclose(actual, expected, atol=1e-4, rtol=1e-4):
            raise AssertionError("independent FP32 encoder logits differ from official cache: " + split)
        mismatches += int(np.count_nonzero(np.argmax(actual, axis=1) != np.argmax(expected, axis=1)))
    if mismatches:
        raise AssertionError("independent FP32 encoder changed official predictions: " + split)
    return {"split": split, "count": len(data["labels"]), "max_logit_error": maximum,
            "prediction_mismatches": mismatches, "atol": 1e-4, "rtol": 1e-4}


def verify_float_alignment(experiment):
    path = experiment.folder / "reports" / "float_alignment.json"
    if path.exists():
        saved = json.loads(path.read_text())
        if saved.get("identity") == experiment.identity:
            return saved
    futures = [experiment.pool.submit(_float_alignment_job, split)
               for split in ("training", "validation", "validation_full", "testing")]
    results = [future.result() for future in futures]
    report = {"status": "verified", "datasets": results, "identity": experiment.identity}
    experiment.record("float_alignment", report)
    print("Independent FP32 logits/predictions match official caches on all partitions", flush=True)
    return report


def prepare_prefix(experiment):
    p, a = configure_profile(*experiment.base, experiment.weights, baseline_config())
    for split in ("screen", "validation"):
        path = experiment.folder / "cache" / ("prefix_" + split + ".npz")
        identity_path = path.with_suffix(".json")
        if path.exists() and identity_path.exists() and json.loads(identity_path.read_text()) == experiment.identity:
            continue
        with np.load(experiment.root / "cache" / "validation.npz") as source:
            x, y = source["boundary"], source["labels"]
        if split == "screen":
            ix = np.concatenate([np.flatnonzero(y == c)[:10] for c in range(12)])
            x = x[ix]
        gathered = {b + ".input": [] for b in p["blocks"]}
        enc = IntegerEncoder(p, a)
        for start in range(0, len(x), 32):
            _, traces = enc.run(quantize(x[start:start+32], p["exponents"]["b00.input"], 8), trace=True)
            for name in gathered:
                gathered[name].append(traces[name].astype(np.int8))
        np.savez_compressed(path, **{k: np.concatenate(v) for k, v in gathered.items()})
        _json(identity_path, experiment.identity)
        print("Saved exact integer prefix cache", split, flush=True)


def weight_sweep(experiment):
    base = baseline_config()
    linears = sorted(experiment.base[0]["linears"])
    configs = [dict(copy.deepcopy(base), weight_bits_by_linear={name: 4}) for name in linears]
    controls = [dict(copy.deepcopy(base), weight_bits_by_linear={name: 4 for name in linears}),
                dict(copy.deepcopy(base), weight_bits_by_linear={name: 4 for name in linears if ".fc" in name})]
    baseline = experiment.evaluate([base], "validation")[0]
    screened = experiment.evaluate(configs + controls, "screen", suffix=True)
    experiment.record("weight_screen", screened)
    ranked = sorted(screened[:72], key=_weight_rank)
    verified = experiment.evaluate([r["config"] for r in ranked[:24]] + controls, "validation", suffix=True)
    experiment.record("weight_single_validation", verified)
    ordered = sorted(verified[:24], key=_weight_rank) + ranked[24:]
    paths = {"conservative": {"config": base, "best": baseline, "drop": 1.0},
             "compressed": {"config": base, "best": baseline, "drop": 1.5}}
    combinations = []
    for index, item in enumerate(ordered[:32]):
        name = next(iter(item["config"]["weight_bits_by_linear"]))
        trials, owners = [], []
        for owner, state in paths.items():
            c = copy.deepcopy(state["config"])
            c.setdefault("weight_bits_by_linear", {})[name] = 4
            trials.append(c); owners.append(owner)
        results = experiment.evaluate(trials, "validation", suffix=True)
        combinations.extend(results)
        for owner, result in zip(owners, results):
            state = paths[owner]
            if _good(result, state["drop"]):
                state["config"], state["best"] = result["config"], result
        experiment.record("weight_combinations", combinations)
    branches = [{"name": "W8A8", "config": base, "result": baseline}]
    seen = {config_id(base)}
    for owner, state in paths.items():
        possible = [state["best"]] + [r for r in verified[-2:] if _good(r, state["drop"])]
        best = min(possible, key=lambda r: (r["weight_bytes"], -r["correct"], r["config_id"]))
        if config_id(best["config"]) not in seen:
            branches.append({"name": owner, "config": best["config"], "result": best})
            seen.add(config_id(best["config"]))
    experiment.record("weight_branches", branches)
    return branches


def _softmax_configs(base):
    result = []
    for ef in (24, 15):
        for pf in (15, 11, 7):
            c = copy.deepcopy(base)
            c["softmax"] = {"table": "compact", "exp_frac": ef, "prob_frac": pf}
            result.append(c)
    return result


def nonlinear_sweep(experiment, branches):
    output = []
    for branch in branches:
        base = copy.deepcopy(branch["config"])
        gelus = [dict(copy.deepcopy(base), gelu=mode) for mode in ("direct", "middle")]
        gelu_results = experiment.evaluate(gelus, "validation")
        for result in gelu_results:
            if result["status"] != "complete" or result["output_hashes"] != branch["result"]["output_hashes"]:
                raise AssertionError("lossless GELU changed full validation outputs")
        base["gelu"] = "direct"
        soft = experiment.evaluate(_softmax_configs(base), "validation")
        precisions = []
        for nf in (20, 16, 12):
            for gf in (20, 16, 12):
                c = copy.deepcopy(base)
                c["layernorm"] = {"method": "reference", "norm_frac": nf, "gamma_frac": gf}
                precisions.append(c)
        ln_precision = experiment.evaluate(precisions, "validation")
        non_reference = [r for r in ln_precision if r["status"] == "complete" and
                         (r["config"]["layernorm"]["norm_frac"], r["config"]["layernorm"]["gamma_frac"]) != (20, 20)]
        leaders = sorted(non_reference, key=_precision_rank)[:2]
        alternatives = []
        for leader in leaders:
            for entries in (64, 256):
                for frac in (16, 20):
                    for iterations in (0, 1):
                        c = copy.deepcopy(leader["config"])
                        c["layernorm"].update(method="rsqrt", lut_entries=entries,
                             rsqrt_frac=frac, iterations=iterations)
                        alternatives.append(c)
        ln_approx = experiment.evaluate(alternatives, "validation")
        all_ln = [r for r in ln_precision + ln_approx if r["status"] == "complete"]
        accurate = min(all_ln, key=_precision_rank)
        cheapest = min(all_ln, key=lambda r: (r["config"]["layernorm"]["norm_frac"] +
                       r["config"]["layernorm"]["gamma_frac"],
                       r["config"]["layernorm"].get("lut_entries", 0), -r["correct"]))
        useful = [r for r in ln_approx if _good(r, 1.75)]
        tradeoff = min(useful or [r for r in ln_approx if r["status"] == "complete"] or all_ln,
                       key=lambda r: (r["config"]["layernorm"].get("lut_entries", 0),
                       r["config"]["layernorm"].get("iterations", 0), -r["correct"]))
        ln_choices = {canonical(r["config"]["layernorm"]): r["config"]["layernorm"]
                      for r in (accurate, cheapest, tradeoff)}
        for result in sorted(all_ln, key=_precision_rank):
            if len(ln_choices) >= 3:
                break
            spec = result["config"]["layernorm"]
            ln_choices.setdefault(canonical(spec), spec)
        global_configs = []
        for sm in _softmax_configs(base):
            for ln in ln_choices.values():
                c = copy.deepcopy(sm); c["layernorm"] = ln
                global_configs.append(c)
        global_results = experiment.evaluate(global_configs, "validation")
        record = {"branch": branch["name"], "base": branch, "gelu": gelu_results,
                  "softmax": soft, "layernorm_precision": ln_precision,
                  "layernorm_rsqrt": ln_approx, "global": global_results}
        experiment.record("nonlinear_" + branch["name"], record)
        output.append(record)
    return output


def _residual_batch(begin):
    w = _WORKER
    path = w["experiment"] / "progress" / ("residual_%04d_%s.json" % (begin, config_id(w["identity"])))
    if path.exists():
        return json.loads(path.read_text())
    data = _dataset("testing")
    end = min(begin + 32, len(data["labels"]))
    p, a = w["base"]
    old = IntegerEncoder(p, a)
    new = IntegerEncoder(*configure_profile(p, a, w["weights"], baseline_config()))
    q = quantize(data["boundary"][begin:end], p["exponents"]["b00.input"], 8)
    before, before_trace = old.run(q, trace=True)
    after, after_trace = new.run(q, trace=True)
    if before_trace.keys() != after_trace.keys():
        raise AssertionError("residual regression changed trace structure")
    for name in before_trace:
        if not np.array_equal(before_trace[name], after_trace[name]):
            raise AssertionError("residual int32 mismatch: %s sample batch %d" % (name, begin))
    if not np.array_equal(before, after) or old.last_saturation != new.last_saturation:
        raise AssertionError("residual int32 output/saturation mismatch")
    result = {"begin": begin, "end": end, "count": end - begin, "bit_exact": True,
              "overflow_count": 0, "ranges": new.last_residual_stats,
              "output_sha256": hashlib.sha256(after.astype("<i8").tobytes()).hexdigest()}
    _json(path, result)
    return result


def residual_audit(experiment):
    pending = [experiment.pool.submit(_residual_batch, start) for start in range(0, 4890, 32)]
    batches, ranges = [], {}
    for future in as_completed(pending):
        result = future.result(); batches.append(result)
        _merge_ranges(ranges, result["ranges"])
        if len(batches) % 16 == 0:
            print("Residual int32 bit-exact %d / 4890" % sum(x["count"] for x in batches), flush=True)
    if sum(x["count"] for x in batches) != 4890:
        raise AssertionError("incomplete residual regression")
    with (experiment.root / "cache" / "w8a8_int32_evaluate_progress.json").open() as source:
        historical = json.load(source)
    hashes = [x["output_sha256"] for x in sorted(batches, key=lambda x: x["begin"])]
    if hashes != historical["output_sha256"]:
        raise AssertionError("reference outputs differ from historical complete W8A8 evaluation")
    proofs = {}
    for key, r in ranges.items():
        xshift, yshift = int(r["x_shift"]), int(r["y_shift"])
        def endpoints(shift):
            from .integer import shift_rne
            return shift_rne(np.array([-128, 127], np.int64), shift).tolist()
        xb, yb = endpoints(xshift), endpoints(yshift)
        low, high = xb[0] + yb[0], xb[1] + yb[1]
        proofs[key] = {"aligned_x_domain": xb, "aligned_y_domain": yb,
                       "sum_domain": [low, high], "int32_domain_safe": -(1 << 31) <= low <= high < (1 << 31)}
    report = {"status": "complete", "count": 4890, "bit_exact": True,
              "historical_output_hashes_match": True, "overflow_count": 0,
              "ranges": ranges, "domain_proofs": proofs, "identity": experiment.identity}
    experiment.record("residual_int32", report)
    return report


def _resource_vector(experiment, config):
    p, a = configure_profile(*experiment.base, experiment.weights, config)
    diagnostic = set(p.get("diagnostic_arrays", []))
    weight_bits = p.get("weight_bits_by_linear", {})
    weight_bytes = sum((v.size * weight_bits.get(k[:-7], 8) + 7) // 8
                       for k, v in a.items() if k.endswith(".weight"))
    lut_bits = sum(v.size * max(1, int(max(abs(int(v.min())), abs(int(v.max())))).bit_length() +
                    int(v.min() < 0)) for k, v in a.items()
                   if (k.startswith("gelu.") or k.startswith("softmax.") or k.startswith("layernorm.rsqrt"))
                   and k not in diagnostic)
    soft = p.get("softmax_configs", {})
    prob_widths = [s["prob_frac"] + 1 for s in soft.values()]
    ln = p.get("layernorm_configs", {})
    affine_widths = [s["norm_frac"] + s["gamma_frac"] for s in ln.values()]
    # These are independent requirement axes, not a fabricated area formula.
    reference_norms = sum(s["method"] == "reference" for s in ln.values())
    inverse_configs = [s for s in ln.values() if s["method"] == "rsqrt"]
    inverse_product_width = max((s["rsqrt_frac"] + (33 if s["iterations"] else 16)
                                 for s in inverse_configs), default=0)
    newton_steps = sum(s["iterations"] for s in inverse_configs) * 99
    return (int(weight_bytes), int(lut_bits), max(prob_widths or [16]),
            sum(prob_widths), max(affine_widths or [40]), sum(affine_widths),
            reference_norms * 99 * 64, reference_norms * 99,
            inverse_product_width, newton_steps)


def pareto_results(experiment, results):
    complete = {r["config_id"]: r for r in results if r["status"] == "complete"}
    keyed = [(r, _resource_vector(experiment, r["config"])) for r in complete.values()]
    front = []
    for r, resource in keyed:
        dominated = any(other["correct"] >= r["correct"] and all(a <= b for a, b in zip(cost, resource))
                        and (other["correct"] > r["correct"] or cost != resource)
                        for other, cost in keyed if other["config_id"] != r["config_id"])
        if not dominated:
            front.append(r)
    return sorted(front, key=lambda r: (_resource_vector(experiment, r["config"]), -r["correct"], r["config_id"]))


def joint_search(experiment, nonlinear_records):
    combined = []
    for record in nonlinear_records:
        results = [r for r in record["global"] if r["status"] == "complete"]
        if not results:
            raise RuntimeError("no numerically valid global nonlinear configuration")
        front = pareto_results(experiment, results)
        beam = (front[:2] + sorted(results, key=_precision_rank)[:2])
        seen = {r["config_id"] for r in results}
        tried = []
        for turn in range(4):
            proposals = []
            for parent in beam[:4]:
                c = parent["config"]
                parent_proposals = 0
                for offset in range(12):
                    block = "b%02d" % ((turn * 3 + offset) % 12)
                    for kind in ("softmax", "ln1", "ln2"):
                        trial = copy.deepcopy(c)
                        if kind == "softmax":
                            global_sm = c.get("softmax", {})
                            current = c.get("softmax_by_block", {}).get(block, global_sm)
                            value = dict(global_sm, **current)
                            fraction = value.get("prob_frac", 15)
                            value["prob_frac"] = {7: 11, 11: 15, 15: 7}[fraction]
                            trial.setdefault("softmax_by_block", {})[block] = value
                        else:
                            op = block + "." + kind
                            current = c.get("layernorm_by_op", {}).get(op, c.get("layernorm", {}))
                            value = dict(current)
                            # Change one LayerNorm operator per proposal.
                            value.update(method="reference", norm_frac=20, gamma_frac=20)
                            if current.get("method") == "reference" and current.get("norm_frac", 20) == 20 and current.get("gamma_frac", 20) == 20:
                                value.update(norm_frac=12, gamma_frac=12)
                            trial.setdefault("layernorm_by_op", {})[op] = value
                        ident = config_id(trial)
                        if ident not in seen:
                            proposals.append(trial); seen.add(ident)
                            parent_proposals += 1
                        if parent_proposals >= 4 or len(proposals) >= 16:
                            break
                    if parent_proposals >= 4 or len(proposals) >= 16:
                        break
                if len(proposals) >= 16:
                    break
            if not proposals:
                break
            trial_results = experiment.evaluate(proposals, "validation")
            tried.extend(trial_results)
            valid = [r for r in results + tried if _good(r, 2.)]
            population = valid or [r for r in results + tried if r["status"] == "complete"]
            front = pareto_results(experiment, population)
            beam = front[:2] + sorted(population, key=_precision_rank)[:2]
            beam = list({r["config_id"]: r for r in beam}.values())[:4]
            experiment.record("joint_" + record["branch"], tried)
        combined.extend(results + tried + [record["base"]["result"]])
    good = [r for r in combined if _good(r, 2.)]
    front = pareto_results(experiment, good)
    nominated = []
    # Cover both the original weights and every selected mixed-weight branch.
    for record in nonlinear_records:
        wb = record["base"]["config"].get("weight_bits_by_linear", {})
        group = [r for r in good if r["config"].get("weight_bits_by_linear", {}) == wb]
        if group:
            nominated.append(min(group, key=_precision_rank))
            nominated.append(min(group, key=lambda r: (_resource_vector(experiment, r["config"]), -r["correct"])))
    nominated += front[:6] + sorted(good, key=_precision_rank)[:3]
    nominated = list({r["config_id"]: r for r in nominated}.values())[:12]
    if not nominated:
        raise RuntimeError("no candidate passes the validation-subset accuracy gate")
    full = experiment.evaluate([r["config"] for r in nominated], "validation_full")
    full_good = [r for r in full if _good(r, 2.)]
    if not full_good:
        raise RuntimeError("no candidate passes complete validation; no formal test acceptance is possible")
    finalists = []
    for branch in nonlinear_records:
        wb = branch["base"]["config"].get("weight_bits_by_linear", {})
        group = [r for r in full_good if r["config"].get("weight_bits_by_linear", {}) == wb]
        if group:
            finalists.append(min(group, key=lambda r: (_resource_vector(experiment, r["config"]), -r["correct"])))
    finalists += pareto_results(experiment, full_good)[:3] + sorted(full_good, key=_precision_rank)[:1]
    finalists = list({r["config_id"]: r for r in finalists}.values())[:6]
    frozen = {"status": "frozen_before_test", "selection_split": "validation_full",
              "full_validation": full, "finalists": finalists, "identity": experiment.identity,
              "equivalent_gelu_structures": ["direct", "middle"],
              "scope": "software Pareto requirements; not synthesized area"}
    experiment.record("frozen_candidates", frozen)
    return frozen


def final_tests(experiment, frozen):
    from .hardware import describe_profile
    from .export import export_operator_vectors
    if frozen.get("identity") != experiment.identity or frozen.get("selection_split") != "validation_full":
        raise ValueError("final tests require configurations frozen on matching complete validation")
    if not frozen.get("finalists"):
        raise ValueError("no frozen finalists; cannot generate formal acceptance")
    experiment.record("acceptance", {"status": "running", "identity": experiment.identity,
                                     "results": [], "passed": [], "packages": []})
    results = experiment.evaluate([r["config"] for r in frozen["finalists"]], "testing", diagnostic=True)
    with np.load(experiment.root / "cache" / "validation.npz") as val:
        indices = np.concatenate([np.flatnonzero(val["labels"] == c)[:2] for c in range(12)])
        golden = val["boundary"][indices]
    packages = []
    for result in results:
        structures = ("direct", "middle") if result.get("pass") else (result["config"].get("gelu", "reference"),)
        for structure in structures:
            config = dict(copy.deepcopy(result["config"]), gelu=structure)
            p, a = configure_profile(*experiment.base, experiment.weights, config)
            hardware = describe_profile(p, a, observed=result)
            name = "candidate_" + result["config_id"] + "_" + structure
            folder = save_profile(experiment.folder / "profiles", name, p, a)
            _json(folder / "hardware_requirements.json", hardware)
            if not result.get("pass"):
                continue
            check_space(experiment.folder)
            enc = IntegerEncoder(p, a)
            gd = experiment.folder / "golden" / name
            manifest = export_golden(gd, golden, enc, experiment.weights,
                                     p["exponents"]["b00.input"], layer_traces=True)
            vectors = export_operator_vectors(gd / "operator_vectors", enc)
            packages.append({"config_id": result["config_id"], "profile": str(folder),
                             "gelu_structure": structure,
                             "equivalence": "256-code exhaustive GELU proof; full test numerical mapping is identical",
                             "golden": str(gd), "manifest": manifest, "operator_vectors": vectors})
    completed = all(r.get("status") == "complete" and r.get("split") == "testing"
                    and r.get("count") == 4890 and r.get("overflow_count") == 0 for r in results)
    report = {"status": "complete" if completed else "failed", "count_per_candidate": 4890, "results": results,
              "passed": [r["config_id"] for r in results if r.get("pass")],
              "packages": packages, "identity": experiment.identity,
              "synthesized_area_available": False,
              "conclusion": "Accuracy-qualified software candidates only; real RTL area awaits synthesis."}
    experiment.record("acceptance", report)
    return report


def verify_lossless_maps(experiment):
    from .integer import saturate, shift_rne
    p, a = experiment.base
    reference = IntegerEncoder(p, a)
    x = np.arange(-128, 128, dtype=np.int64)
    report = {"gelu": {}, "softmax": {}, "status": "verified"}
    for mode in ("direct", "middle"):
        cp, ca = configure_profile(p, a, experiment.weights, dict(baseline_config(), gelu=mode))
        candidate = IntegerEncoder(cp, ca)
        for b in p["blocks"]:
            ei, eo = p["exponents"][b + ".fc1"], p["exponents"][b + ".gelu"]
            old = saturate(reference.gelu(x, ei, eo), 8)
            new = candidate.gelu(x, ei, eo, b + ".gelu")
            if not np.array_equal(old, new):
                raise AssertionError("GELU finite-domain map changed")
            spec = cp["gelu_configs"][b + ".gelu"]
            report["gelu"]["%s_e%d_e%d" % (mode, ei, eo)] = {
                "entries": int(ca[spec["table_key"]].size), "input_codes_tested": 256,
                "minimum_input": spec["minimum_input"], "maximum_input": spec["maximum_input"],
                "bit_exact": True}
    cp, ca = configure_profile(p, a, experiment.weights, dict(baseline_config(),
                              softmax={"table": "compact", "exp_frac": 24, "prob_frac": 15}))
    candidate = IntegerEncoder(cp, ca)
    scores = np.stack((np.full(256, 127, np.int64), 127 - np.arange(256, dtype=np.int64)), axis=-1)
    for b in p["blocks"]:
        exponent = p["exponents"][b + ".score"]
        old = reference.softmax(scores, exponent, b + ".softmax")
        new = candidate.softmax(scores, exponent, b + ".softmax")
        if not np.array_equal(old, new):
            raise AssertionError("compact Softmax map changed")
        report["softmax"][str(exponent)] = {"score_differences_tested": 256, "bit_exact": True,
                                          "reference_entries": 4097, "compact_entries": 257}
    experiment.record("lossless_maps", report)
    return report


def _accumulate_probability_error(item, actual, ideal):
    error = actual - ideal
    item["elements"] = item.get("elements", 0) + int(actual.size)
    item["absolute_error_sum"] = item.get("absolute_error_sum", 0.) + float(np.abs(error).sum())
    item["max_error"] = max(item.get("max_error", 0.), float(np.max(np.abs(error))))
    item["zero_count"] = item.get("zero_count", 0) + int(np.count_nonzero(actual == 0))
    item["row_count"] = item.get("row_count", 0) + int(actual.size // actual.shape[-1])
    sums = actual.sum(axis=-1)
    item["row_sum_error_abs"] = item.get("row_sum_error_abs", 0.) + float(np.abs(sums - 1.).sum())
    item["max_row_sum_error"] = max(item.get("max_row_sum_error", 0.), float(np.max(np.abs(sums - 1.))))


def _softmax_replay_job(branch):
    w = _WORKER
    path = w["experiment"] / "reports" / ("softmax_replay_" + branch["name"] + ".json")
    if path.exists():
        saved = json.loads(path.read_text())
        if saved.get("identity") == w["identity"]:
            return saved
    data = _dataset("validation")
    p, a = configure_profile(*w["base"], w["weights"], branch["config"])
    baseline = IntegerEncoder(p, a)
    variants = []
    for config in _softmax_configs(dict(copy.deepcopy(branch["config"]), gelu="direct")):
        pp, aa = configure_profile(*w["base"], w["weights"], config)
        variants.append((config, IntegerEncoder(pp, aa)))
    stages, per_layer = {}, {}
    for begin in range(0, len(data["labels"]), 32):
        _, trace = baseline.run(quantize(data["boundary"][begin:begin+32], p["exponents"]["b00.input"], 8), trace=True)
        for block in p["blocks"]:
            score = trace[block + ".score"]
            real_delta = (score.astype(np.float64) - score.max(axis=-1, keepdims=True)) * np.exp2(p["exponents"][block + ".score"])
            exp = np.exp(real_delta)
            ideal = exp / exp.sum(axis=-1, keepdims=True)
            clipped = np.where(real_delta < -16., 0., exp)
            cut_prob = clipped / clipped.sum(axis=-1, keepdims=True)
            layer = per_layer.setdefault(block, {})
            _accumulate_probability_error(layer.setdefault("cutoff_only", {}), cut_prob, ideal)
            q8 = np.rint(real_delta * 256).astype(np.int64)
            indices = np.clip(-q8, 0, 4096)
            encoded = np.where(q8 < -4096, 0, w["base"][1]["softmax.exp_q24"][indices])
            denominator = encoded.sum(axis=-1, keepdims=True, dtype=np.int64)
            fraction = encoded / denominator.astype(np.float64)
            _accumulate_probability_error(layer.setdefault("q24_exponent_before_probability_rounding", {}), fraction, ideal)
            _accumulate_probability_error(layer.setdefault("q24_exponent_error_relative_cutoff", {}), fraction, cut_prob)
            encoded15 = np.rint(np.exp(-np.arange(4097, dtype=np.float64) / 256.) * (1 << 15)).astype(np.int64)[indices]
            encoded15 = np.where(q8 < -4096, 0, encoded15)
            fraction15 = encoded15 / encoded15.sum(axis=-1, keepdims=True, dtype=np.int64).astype(np.float64)
            _accumulate_probability_error(layer.setdefault("q15_exponent_before_probability_rounding", {}), fraction15, ideal)
            _accumulate_probability_error(layer.setdefault("q15_exponent_error_relative_cutoff", {}), fraction15, cut_prob)
            layer["integer_denominator_matches_encoded_sum"] = True
            value = dequantize(trace[block + ".v"], p["exponents"][block + ".v"])
            context_ideal = np.matmul(ideal, value)
            for config, encoder in variants:
                sm = config["softmax"]
                name = "E%d_P%d" % (sm["exp_frac"], sm["prob_frac"])
                prob_int = encoder.softmax(score, p["exponents"][block + ".score"], block + ".softmax")
                probability = prob_int * np.exp2(-sm["prob_frac"])
                item = layer.setdefault(name, {})
                _accumulate_probability_error(item, probability, ideal)
                _accumulate_probability_error(layer.setdefault(name + "_rounding_only", {}), probability,
                                              fraction if sm["exp_frac"] == 24 else fraction15)
                context = np.matmul(probability, value)
                ce = context - context_ideal
                item["context_squared_error"] = item.get("context_squared_error", 0.) + float(np.sum(ce * ce))
                item["context_reference_energy"] = item.get("context_reference_energy", 0.) + float(np.sum(context_ideal * context_ideal))
                item["context_max_error"] = max(item.get("context_max_error", 0.), float(np.max(np.abs(ce))))
                from .integer import shift_rne, saturate
                acc = np.matmul(prob_int, trace[block + ".v"])
                context_int = saturate(shift_rne(acc, p["exponents"][block + ".context"] +
                                      sm["prob_frac"] - p["exponents"][block + ".v"]), 8)
                post = dequantize(context_int, p["exponents"][block + ".context"]) - context_ideal
                item["context_after_a8_squared_error"] = item.get("context_after_a8_squared_error", 0.) + float(np.sum(post * post))
                item["context_after_a8_max_error"] = max(item.get("context_after_a8_max_error", 0.), float(np.max(np.abs(post))))
                if sm["exp_frac"] == 24 and sm["prob_frac"] == 15:
                    if not np.array_equal(prob_int, trace[block + ".softmax"]):
                        raise AssertionError("lossless compact table changed probabilities during replay")
    for layer in per_layer.values():
        for item in layer.values():
            if isinstance(item, dict) and item.get("elements"):
                item["mean_absolute_error"] = item["absolute_error_sum"] / item["elements"]
                item["zero_fraction"] = item["zero_count"] / item["elements"]
                item["mean_absolute_row_sum_error"] = item["row_sum_error_abs"] / item["row_count"]
                if item.get("context_reference_energy"):
                    item["context_nrmse"] = math.sqrt(item["context_squared_error"] / item["context_reference_energy"])
    result = {"status": "complete", "count": len(data["labels"]), "branch": branch["name"],
              "identity": w["identity"], "layers": per_layer,
              "notes": ["Same baseline score and V are replayed for all local error measurements.",
                        "Integer exponent sum is exact; cutoff, exponent encoding and output rounding can lose precision.",
                        "End-to-end Top-1 ablations are reported separately and are not additive."]}
    _json(path, result)
    return result


def softmax_attribution(experiment, records):
    futures = [experiment.pool.submit(_softmax_replay_job, r["base"]) for r in records]
    replay = [f.result() for f in futures]
    summaries = []
    for record in records:
        baseline = record["base"]["result"]
        table = {(r["config"]["softmax"]["exp_frac"], r["config"]["softmax"]["prob_frac"]): r
                 for r in record["softmax"] if r["status"] == "complete"}
        chain = [("reference", baseline), ("compact_exact", table[(24, 15)]),
                 ("exponent_q15", table[(15, 15)]), ("probability_q11", table[(15, 11)]),
                 ("probability_q7", table[(15, 7)])]
        steps, previous = [], baseline
        for name, result in chain:
            steps.append({"step": name, "top1": result["top1"],
                          "loss_previous_pp": (previous["top1"] - result["top1"]) * 100,
                          "loss_weight_branch_pp": (baseline["top1"] - result["top1"]) * 100,
                          "loss_fp32_pp": result["drop_pp"],
                          "prediction_flips_previous": sum(a != b for a, b in zip(previous["predictions"], result["predictions"]))})
            previous = result
        single = []
        for key, name in (((24, 15), "table_only"), ((15, 15), "exponent_only"),
                          ((24, 11), "probability_q11_only"), ((24, 7), "probability_q7_only")):
            result = table[key]
            single.append({"step": name, "top1": result["top1"], "loss_branch_pp":
                          (baseline["top1"] - result["top1"]) * 100, "loss_fp32_pp": result["drop_pp"]})
        summaries.append({"branch": record["branch"], "cumulative": steps, "single_factor": single})
    experiment.record("softmax_attribution", {"end_to_end": summaries, "replay": replay})
    return summaries


def write_report(experiment):
    report_dir = experiment.folder / "reports"
    acceptance_path = report_dir / "acceptance.json"
    acceptance = json.loads(acceptance_path.read_text()) if acceptance_path.exists() else None
    if acceptance and acceptance.get("identity") != experiment.identity:
        acceptance = None
    lines = ["# W4/W8 integer nonlinear experiments", "",
             "Software experiments only. No RTL or synthesized area is claimed.", "",
             "Activation A8; checked int32 MAC and residual addition; no training or A16.", ""]
    residual_path = report_dir / "residual_int32.json"
    if residual_path.exists():
        r = json.loads(residual_path.read_text())
        if r.get("identity") == experiment.identity:
            maximum = max(v["sum"]["required_signed_bits"] for v in r["ranges"].values())
            lines += ["## Residual regression", "", "%d samples: bit-exact=%s, overflow=%d, observed sum width=%d bits." %
                      (r["count"], r["bit_exact"], r["overflow_count"], maximum), ""]
    attr_path = report_dir / "softmax_attribution.json"
    if attr_path.exists():
        attrs = json.loads(attr_path.read_text())
        lines += ["## Softmax cumulative ablation", "",
                  "| Branch | Step | Top-1 (%) | Loss previous (pp) | Loss branch (pp) | Loss FP32 (pp) |",
                  "|---|---|---:|---:|---:|---:|"]
        for b in attrs["end_to_end"]:
            for row in b["cumulative"]:
                lines.append("| %s | %s | %.6f | %.6f | %.6f | %.6f |" %
                             (b["branch"], row["step"], row["top1"] * 100, row["loss_previous_pp"],
                              row["loss_weight_branch_pp"], row["loss_fp32_pp"]))
        lines += ["", "Single-factor ablations and fixed-score replay diagnostics: softmax_attribution.json.", ""]
    if acceptance and acceptance.get("status") == "complete":
        lines += ["## Complete test results", "",
                  "| Configuration | Count | Top-1 (%) | Loss FP32 (pp) | W4 matrices | Weight KiB | CPU seconds | Pass |",
                  "|---|---:|---:|---:|---:|---:|---:|---|"]
        for r in acceptance["results"]:
            if r["status"] == "complete":
                wc = sum(v == 4 for v in r["config"].get("weight_bits_by_linear", {}).values())
                lines.append("| %s | %d | %.6f | %.6f | %d | %.2f | %.2f | %s |" %
                             (r["config_id"], r["count"], r["top1"] * 100, r["drop_pp"], wc,
                              r["weight_bytes"] / 1024, r["seconds"], r["pass"]))
            else:
                lines.append("| %s | %d | failed | - | - | - | - | False |" % (r["config_id"], r["count"]))
        lines += ["", "All final configurations were frozen using the complete validation partition before testing.",
                  "Golden and operator-vector manifests are recorded in acceptance.json.",
                  "Hardware requirements list widths, tables, packed/16-bit-aligned buffers and SRAM-capacity examples.",
                  "They do not establish an RTL area ranking or an E203 cycle count.", ""]
    else:
        lines += ["## Status", "", "Experiment is incomplete; formal acceptance has not been generated.", ""]
    lines += ["## Reproduction", "", "```powershell",
              "./quantization/scripts/run_mixed_nonlinear.ps1 -Resume", "```", "",
              "Every configuration/split uses a code/data/profile identity and checkpoints every 32 samples.",
              "Old W8A8 profiles, reports, testing order and golden remain separate.", ""]
    (report_dir / "experiment_report.md").write_text("\n".join(lines), encoding="utf-8")
    return report_dir / "experiment_report.md"


def run_experiments(args):
    from .experiment_data import prepare_experiment_data
    from .pipeline import prepare as prepare_legacy, baseline as baseline_legacy, calibrate as calibrate_legacy, sweep as sweep_legacy
    root = Path(args.data_root).resolve()
    folder = root / "experiments" / "w4w8_nonlinear_v1"
    # A fresh checkout has the checkpoint and source code but no legacy caches
    # or base profile. Build those deterministic prerequisites automatically.
    if not (root / "profiles" / "W8A8_integer" / "profile.json").is_file():
        state = {}
        prepare_legacy(args, state)
        baseline_legacy(args, state)
        calibrate_legacy(args, state)
        sweep_legacy(args, state)
    prepare_experiment_data(root, Path(args.repo_root).resolve(), folder, resume=args.resume)
    if args.stage == "prepare":
        return
    experiment = Experiment(args)
    try:
        verify_float_alignment(experiment)
        verify_lossless_maps(experiment)
        if args.stage == "report":
            return
        if args.stage in ("all", "residual"):
            residual_audit(experiment)
        if args.stage == "residual":
            return
        if args.stage in ("all", "weights"):
            prepare_prefix(experiment)
            branches = weight_sweep(experiment)
        else:
            branches = json.loads((folder / "reports" / "weight_branches.json").read_text())
            if not validate_saved_identity(branches, experiment.identity):
                raise ValueError("weight branches have no identity")
        if args.stage == "weights":
            return
        if args.stage in ("all", "nonlinear"):
            records = nonlinear_sweep(experiment, branches)
            softmax_attribution(experiment, records)
        else:
            records = [json.loads((folder / "reports" / ("nonlinear_" + b["name"] + ".json")).read_text()) for b in branches]
            if not validate_saved_identity(records, experiment.identity):
                raise ValueError("nonlinear reports have no identity")
        if args.stage == "nonlinear":
            return
        if args.stage in ("all", "joint"):
            frozen = joint_search(experiment, records)
        else:
            frozen = json.loads((folder / "reports" / "frozen_candidates.json").read_text())
            if frozen["identity"] != experiment.identity:
                raise ValueError("frozen configuration identity changed; rerun joint validation")
        if args.stage in ("all", "final"):
            final_tests(experiment, frozen)
    finally:
        write_report(experiment)
        experiment.close()
