import hashlib, json, os, platform, time
from pathlib import Path
import numpy as np

from .reference import load_reference, forward_float, classify_float
from .integer import build_profile, IntegerEncoder, quantize, dequantize
from .export import save_profile, load_profile, export_golden
from .data import prepare_dataset

LABELS = ["_silence_", "_unknown_", "yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go"]


def _json(path, value):
    path = Path(path); path.parent.mkdir(parents=True, exist_ok=True)
    tmp = path.with_suffix(path.suffix + ".tmp")
    tmp.write_text(json.dumps(value, indent=2, sort_keys=True, default=str), encoding="utf-8")
    tmp.replace(path)


def _fingerprint(repo):
    h = hashlib.sha256()
    for p in sorted((Path(repo) / "quantization").glob("*.py")):
        h.update(p.name.encode()); h.update(p.read_bytes())
    return h.hexdigest()


def _file_hash(path):
    h = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(8 * 1024 * 1024), b""):
            h.update(chunk)
    return h.hexdigest()


def _merge_max(destination, values):
    for name, value in values.items():
        destination[name] = max(destination.get(name, 0), int(value))


def _merge_saturation(destination, values):
    for name, value in values.items():
        total = destination.setdefault(name, {"clipped": 0, "total": 0})
        total["clipped"] += int(value["clipped"])
        total["total"] += int(value["total"])


def _merge_errors(destination, integer_traces, float_traces, exponents):
    for name, value in integer_traces.items():
        decoded = dequantize(value, exponents[name])
        reference = np.asarray(float_traces[name], dtype=np.float64)
        error = decoded - reference
        if not np.all(np.isfinite(decoded)) or not np.all(np.isfinite(reference)):
            raise ValueError("nonfinite trace: " + name)
        item = destination.setdefault(name, {"count": 0, "squared_error": 0.,
                                            "reference_squared": 0., "max_error": 0.})
        item["count"] += int(error.size)
        item["squared_error"] += float(np.sum(error * error))
        item["reference_squared"] += float(np.sum(reference * reference))
        item["max_error"] = max(item["max_error"], float(np.max(np.abs(error))))


def _final_errors(errors):
    result = {}
    for name, item in errors.items():
        sse, energy, count = item["squared_error"], item["reference_squared"], item["count"]
        result[name] = {"count": count, "rmse": float(np.sqrt(sse / count)),
                        "nrmse": float(np.sqrt(sse / energy)) if energy else (0. if sse == 0 else None),
                        "max_error": item["max_error"]}
    return result


def _batches(ref, processor, mode, count, batch=32):
    out_x, out_y = [], []
    for offset in range(0, count, batch):
        x, y = ref.get_batch(processor, mode, offset, min(batch, count - offset))
        out_x.append(x); out_y.append(y)
    return np.concatenate(out_x), np.concatenate(out_y)


def _stats(traces):
    result = {}
    for key, values in traces.items():
        a = np.abs(np.asarray(values, np.float32)).reshape(-1)
        result[key] = {"max": float(np.max(a)) if a.size else 0.0,
                       "p9999": float(np.percentile(a, 99.99)) if a.size else 0.0,
                       "count": int(a.size)}
    return result


_P9999 = np.true_divide(99.99, 100)  # numpy.percentile's own q / 100


class _TraceStats:
    """Streaming equivalent of ``_stats`` over batches of ``total`` samples.

    Keeping every trace of the 4890-sample test set needs more than 33 GB.
    The linear-interpolated 99.99th percentile only depends on the largest
    ``N - floor(0.9999 * (N - 1))`` values, so only that tail is retained.
    """

    def __init__(self, total):
        self.total = int(total); self.seen = 0; self.items = {}

    def add(self, traces, batch):
        batch = int(batch)
        for key, values in traces.items():
            a = np.abs(np.asarray(values, np.float32)).reshape(-1)
            if a.size % batch:
                raise ValueError("trace size is not divisible by batch: " + key)
            item = self.items.setdefault(key, {"count": 0, "max": 0.0, "tail": np.empty(0, np.float32),
                                                "expected": a.size // batch * self.total})
            n = item["expected"]
            keep = n - int(np.floor(_P9999 * (n - 1))) if n else 0
            tail = np.concatenate([item["tail"], a])
            if tail.size > keep:
                tail = np.partition(tail, tail.size - keep)[tail.size - keep:]
            item["tail"] = tail; item["count"] += int(a.size)
            if a.size:
                item["max"] = max(item["max"], float(np.max(a)))
        self.seen += batch

    def result(self):
        if self.seen != self.total:
            raise ValueError("trace statistics saw %d of %d samples" % (self.seen, self.total))
        result = {}
        for key, item in self.items.items():
            n = item["count"]
            if n != item["expected"]:
                raise ValueError("trace size changed between batches: " + key)
            p9999 = 0.0
            if n:
                # Same index/weight arithmetic as numpy 1.19's linear percentile.
                position = _P9999 * (n - 1)
                below = int(np.floor(position)); above = min(below + 1, n - 1)
                weight = position - below
                tail = np.sort(item["tail"])
                start = n - tail.size
                p9999 = float(tail[below - start] * (1 - weight) + tail[above - start] * weight)
            result[key] = {"max": item["max"], "p9999": p9999, "count": n}
        return result


def _encode_with_stats(ref, boundary, batch=32):
    """Encode in batches; return encoded output and streamed trace statistics."""
    stats = _TraceStats(len(boundary)); encoded = []
    for offset in range(0, len(boundary), batch):
        part = boundary[offset:offset + batch]
        out, traces = ref.encode(part, trace=True)
        encoded.append(out); stats.add(traces, len(part))
    return np.concatenate(encoded), stats.result()


def prepare(args, state):
    root = Path(args.data_root); root.mkdir(parents=True, exist_ok=True)
    # A fresh checkout has no local dataset.  This validates an existing
    # archive/cache or downloads and extracts Speech Commands automatically.
    prepare_dataset(root)
    ref = load_reference(args.repo_root)
    proc = ref.build_processor(root / "data2")
    (root / "cache").mkdir(parents=True, exist_ok=True)
    # The upstream split has a deterministic order. Persist the actual order and samples.
    splits = {}
    for mode, count in (("training", 1200), ("validation", 500), ("testing", 4890)):
        x, y = _batches(ref, proc, mode, count)
        b, logits = ref.boundary_and_logits(x)
        np.savez_compressed(root / "cache" / (mode + ".npz"), waveforms=x, labels=y, boundary=b, float_logits=logits)
        splits[mode] = {"count": int(len(y)), "labels": y.tolist(), "indices": list(range(len(y)))}
    _json(root / "cache" / "manifest.json", {"labels": LABELS, "splits": splits,
                                                "checkpoint": str(ref.checkpoint), "fingerprint": _fingerprint(args.repo_root)})
    ref.close(); state["prepared"] = True


def baseline(args, state):
    root = Path(args.data_root); ref = load_reference(args.repo_root)
    data = np.load(root / "cache" / "testing.npz")
    boundary = data["boundary"]
    encoded, trace_stats = _encode_with_stats(ref, boundary)
    logits = ref.classify(encoded)
    labels = data["labels"]
    pred = np.argmax(logits, axis=1)
    val = {"top1": float(np.mean(pred == labels)), "count": int(len(labels)),
           "first4800": float(np.mean(pred[:4800] == labels[:4800])),
           "parameter_count": 607308, "trace_stats": trace_stats}
    np.savez_compressed(root / "cache" / "baseline.npz", encoded=encoded, logits=logits, labels=labels)
    _json(root / "reports" / "baseline.json", val); state["baseline"] = val; ref.close()


def calibrate(args, state):
    root = Path(args.data_root); ref = load_reference(args.repo_root)
    data = np.load(root / "cache" / "training.npz")
    _, stats = _encode_with_stats(ref, data["boundary"])
    # Weight calibration is exact and activation ranges come from the fixed training subset.
    _json(root / "cache" / "calibration.json", stats); state["calibrated"] = True; ref.close()


def _profile_name(w, a, mode):
    return "W%dA%d_%s" % (w, a, mode)


def sweep(args, state):
    root = Path(args.data_root); ref = load_reference(args.repo_root)
    weights = ref.weights(); stats = json.loads((root / "cache" / "calibration.json").read_text(encoding="utf-8"))
    val = np.load(root / "cache" / "validation.npz"); boundary = val["boundary"]; labels = val["labels"]
    results = []
    configs = [(8, 8, "integer")]
    for wb, ab, kind in configs:
        name = "FP32" if kind == "float" else _profile_name(wb, ab, kind)
        if kind == "float":
            logits = ref.classify(ref.encode(boundary)); pred = np.argmax(logits, 1)
            results.append({"name": name, "top1": float(np.mean(pred == labels)), "kind": kind}); continue
        params, arrays = build_profile(weights, stats, wb, ab, "max")
        folder = save_profile(root / "profiles", name, params, arrays)
        enc = IntegerEncoder(params, arrays)
        inp_exp = params["exponents"]["b00.input"]
        qi = quantize(boundary, inp_exp, ab)
        out, traces = enc.run(qi, trace=True)
        deq = dequantize(out, params["exponents"]["b11.output"])
        logits = classify_float(weights, deq)
        pred = np.argmax(logits, 1)
        _, float_traces = ref.encode(boundary, trace=True)
        errors = {}
        _merge_errors(errors, traces, float_traces, params["exponents"])
        errors = _final_errors(errors)
        nrmse = errors["b11.output"]["nrmse"]
        results.append({"name": name, "top1": float(np.mean(pred == labels)), "kind": kind,
                        "count": int(len(labels)), "mac_accumulator_bits": params["accumulator_bits"],
                        "input_exponent": inp_exp, "output_exponent": params["exponents"]["b11.output"],
                        "nrmse": nrmse, "rmse": errors["b11.output"]["rmse"],
                        "trace_errors": errors, "storage_bytes": int(sum(v.nbytes for v in arrays.values()))})
    _json(root / "reports" / "validation_profiles.json", results); state["profiles"] = results; ref.close()


def evaluate(args, state):
    root = Path(args.data_root)
    folder = root / "profiles" / "W8A8_integer"
    params, arrays = load_profile(folder)
    if (params["weight_bits"], params["activation_bits"], params.get("accumulator_bits")) != (8, 8, 32):
        raise ValueError("evaluation requires a frozen W8A8 / int32 MAC profile")
    data_path = root / "cache" / "testing.npz"
    baseline_path = root / "cache" / "baseline.npz"
    with np.load(data_path) as test:
        boundary, labels, official_logits = test["boundary"], test["labels"], test["float_logits"]
    with np.load(baseline_path) as baseline_data:
        if not np.array_equal(labels, baseline_data["labels"]):
            raise AssertionError("float baseline labels/order differ from the test split")
        float_logits = baseline_data["logits"]
    if len(labels) != 4890 or boundary.shape != (4890, 99, 64) or labels.ndim != 1:
        raise AssertionError("expected complete 4890-sample test split at [99,64]")
    if not np.all(np.isfinite(boundary)) or not np.all(np.isfinite(float_logits)):
        raise ValueError("nonfinite cached baseline/input")
    float_pred = np.argmax(float_logits, axis=1)
    if not np.array_equal(float_pred, np.argmax(official_logits, axis=1)):
        raise AssertionError("cached encoder baseline predictions disagree with official model")
    base = float(np.mean(float_pred == labels))
    profile_hash = hashlib.sha256()
    for path in sorted(folder.glob("*.npy")) + [folder / "profile.json"]:
        profile_hash.update(path.name.encode()); profile_hash.update(_file_hash(path).encode())
    identity = {"code": _fingerprint(args.repo_root), "profile": profile_hash.hexdigest(),
                "testing": _file_hash(data_path), "baseline": _file_hash(baseline_path),
                "checkpoint": {p.name: _file_hash(p) for p in sorted(
                    (Path(args.repo_root) / "third-party" / "kwt" / "models_data_v2_12_labels" / "kwt1").glob("best_weights.*"))},
                "numpy_version": np.__version__,
                "batch_size": 32, "count": 4890}
    checkpoint = root / "cache" / "w8a8_int32_evaluate_progress.json"
    progress = {"identity": identity, "next_index": 0, "predictions": [], "saturation": {},
                "mac_required_bits": {}, "wide_temporary_required_bits": {}, "required_bits": {},
                "trace_errors": {}, "encoder_seconds": 0., "total_seconds": 0.,
                "finite_outputs": True, "overflow_count": 0, "output_sha256": []}
    if args.resume and checkpoint.exists():
        saved = json.loads(checkpoint.read_text(encoding="utf-8"))
        if saved["identity"] == identity:
            progress = saved
            print("Resuming W8A8 int32 at %d / 4890" % progress["next_index"], flush=True)
        else:
            print("Fingerprint changed; starting a fresh complete evaluation.", flush=True)
    acceptance_path = root / "reports" / "acceptance.json"
    _json(acceptance_path, {"status": "running", "pass": None, "count": progress["next_index"],
                            "float_top1": base, "identity": identity})
    ref = load_reference(args.repo_root)
    enc = IntegerEncoder(params, arrays)
    weights = ref.weights()
    try:
        for start in range(progress["next_index"], len(labels), identity["batch_size"]):
            tick = time.perf_counter()
            stop = min(start + identity["batch_size"], len(labels))
            q = quantize(boundary[start:stop], params["exponents"]["b00.input"], 8)
            try:
                encoder_tick = time.perf_counter()
                out, traces = enc.run(q, trace=True)
                encoder_seconds = time.perf_counter() - encoder_tick
            except OverflowError as error:
                progress["overflow_count"] += 1
                progress["failure"] = {"start": start, "stop": stop, "message": str(error)}
                _json(checkpoint, progress)
                _json(acceptance_path, {"status": "failed", "pass": False,
                     "count": start, "overflow_count": progress["overflow_count"], "failure": progress["failure"]})
                raise
            decoded = dequantize(out, params["exponents"]["b11.output"])
            logits = classify_float(weights, decoded)
            if not np.all(np.isfinite(logits)) or not np.all(np.isfinite(decoded)):
                raise ValueError("nonfinite decoded output/logits at %d" % start)
            _, float_traces = ref.encode(boundary[start:stop], trace=True)
            _merge_errors(progress["trace_errors"], traces, float_traces, params["exponents"])
            _merge_saturation(progress["saturation"], enc.last_saturation)
            _merge_max(progress["mac_required_bits"], enc.last_mac_required_bits)
            _merge_max(progress["wide_temporary_required_bits"], enc.last_wide_required_bits)
            _merge_max(progress["required_bits"], enc.last_required_bits)
            progress["predictions"].extend(np.argmax(logits, axis=1).tolist())
            progress["output_sha256"].append(hashlib.sha256(out.astype("<i8").tobytes()).hexdigest())
            progress["encoder_seconds"] += encoder_seconds
            progress["total_seconds"] += time.perf_counter() - tick
            progress["next_index"] = stop
            _json(checkpoint, progress)
            if start == 0 or stop % 256 == 0 or stop == len(labels):
                print("W8A8 int32: %d / 4890; encoder %.1fs; MAC max %d bits" %
                      (stop, progress["encoder_seconds"], max(progress["mac_required_bits"].values())), flush=True)
            del traces, float_traces, out
    except Exception as error:
        _json(acceptance_path, {"status": "failed", "pass": False,
             "count": progress["next_index"], "error": str(error), "identity": identity,
             "overflow_count": progress["overflow_count"]})
        raise
    finally:
        ref.close()
    pred = np.asarray(progress["predictions"], dtype=np.int64)
    if pred.shape != labels.shape or progress["next_index"] != 4890:
        raise AssertionError("incomplete evaluation cannot produce acceptance")
    confusion = np.zeros((12, 12), dtype=np.int64)
    np.add.at(confusion, (labels, pred), 1)
    saturation = progress["saturation"]
    for item in saturation.values():
        item["rate"] = item["clipped"] / item["total"]
    top1 = float(np.mean(pred == labels))
    result = {"name": folder.name, "status": "complete", "count": 4890,
              "correct": int(np.sum(pred == labels)), "top1": top1, "float_top1": base,
              "drop_percentage_points": (base - top1) * 100,
              "first4800": float(np.mean(pred[:4800] == labels[:4800])),
              "prediction_agreement_float": float(np.mean(pred == float_pred)),
              "seconds": progress["encoder_seconds"], "total_diagnostic_seconds": progress["total_seconds"],
              "samples_per_second": 4890 / progress["encoder_seconds"],
              "timing_scope": "CPU batch32 integer encoder with traces and overflow checks; not E203 timing",
              "saturation": saturation, "saturation_count": sum(x["clipped"] for x in saturation.values()),
              "mac_required_bits": progress["mac_required_bits"],
              "wide_temporary_required_bits": progress["wide_temporary_required_bits"],
              "required_bits": progress["required_bits"], "overflow_count": progress["overflow_count"],
              "finite_outputs": progress["finite_outputs"], "confusion_matrix": confusion.tolist(),
              "confusion_labels": LABELS, "trace_errors": _final_errors(progress["trace_errors"]),
              "weight_bits": 8, "activation_bits": 8, "mac_accumulator_bits": 32,
              "softmax_bits": params["softmax_bits"], "wide_temporary_bits": 64,
              "storage_bytes": sum(p.stat().st_size for p in folder.iterdir() if p.is_file()),
              "identity": identity}
    _json(root / "reports" / "test_profiles.json", [result])
    np.save(root / "reports" / "W8A8_int32_test_predictions.npy", pred)
    passed = top1 >= base - .02 and progress["overflow_count"] == 0
    _json(acceptance_path, {"status": "complete", "float_top1": base, "chosen": result,
             "pass": passed, "criterion": "complete 4890-sample test top1 >= float top1 - 0.02 and no MAC overflow",
             "test_scope": "complete 4890-sample cached test split; official 600 list unavailable"})
    state["evaluated"] = True


def export(args, state):
    root = Path(args.data_root); ref = load_reference(args.repo_root)
    val = np.load(root / "cache" / "validation.npz"); selected = np.concatenate([np.where(val["labels"] == c)[0][:2] for c in range(12)])
    boundary = val["boundary"][selected]
    # Select smallest passing profile from the frozen acceptance record, with deterministic fallback.
    acceptance = json.loads((root / "reports" / "acceptance.json").read_text(encoding="utf-8"))
    name = (acceptance.get("chosen") or {}).get("name")
    if not name: name = "W8A8_integer"
    params, arrays = load_profile(root / "profiles" / name); enc = IntegerEncoder(params, arrays)
    golden_dir = root / "golden" / name
    export_golden(golden_dir, boundary, enc, ref.weights(), params["exponents"]["b00.input"])
    reloaded = IntegerEncoder(*load_profile(root / "profiles" / name))
    for i, sample in enumerate(boundary):
        qi = quantize(sample, params["exponents"]["b00.input"], params["activation_bits"])
        expected = np.load(golden_dir / ("sample_%02d_output.npy" % i), allow_pickle=False)
        actual, _ = reloaded.run(qi)
        if not np.array_equal(actual, expected):
            raise AssertionError("golden reload mismatch at sample %d" % i)
    _json(root / "reports" / "provenance.json", {"python": platform.python_version(), "platform": platform.platform(),
             "cpu": platform.processor(), "fingerprint": _fingerprint(args.repo_root), "profile": name})
    ref.close(); state["exported"] = True


def run(args):
    root = Path(args.data_root); state_path = root / "cache" / "state.json"
    state = json.loads(state_path.read_text(encoding="utf-8")) if args.resume and state_path.exists() else {}
    for name, fn in (("prepare", prepare), ("baseline", baseline), ("calibrate", calibrate), ("sweep", sweep), ("evaluate", evaluate), ("export", export)):
        if args.resume and state.get(name == "prepare" and "prepared" or name): continue
        fn(args, state); _json(state_path, state)
    _json(root / "reports" / "report.json", state)

