"""Reconstruct auditable experiment data without changing legacy caches.

Upstream ``gfile.Glob`` order is not stable on Windows.  Legacy sample provenance
is therefore recovered from exact padded PCM content, never inferred from a newly
constructed processor's order.  Its public data API then verifies that recovery.
"""

import hashlib
import io
import json
from pathlib import Path
import shutil
import wave

import numpy as np

from .data import prepare_dataset


LABELS = ["_silence_", "_unknown_", "yes", "no", "up", "down", "left", "right", "on", "off", "stop", "go"]
LEGACY_COUNTS = {"training": 1200, "validation": 500, "testing": 4890}
BATCH_SIZE = 32


def _hash(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as handle:
        for chunk in iter(lambda: handle.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def _json(path, value):
    path = Path(path)
    path.parent.mkdir(parents=True, exist_ok=True)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def _npz(path, **arrays):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    with temporary.open("wb") as handle:
        np.savez_compressed(handle, **arrays)
    temporary.replace(path)


def _space(root):
    if shutil.disk_usage(str(root)).free < 10 * 1024 ** 3:
        raise RuntimeError("Experiment data preparation requires at least 10 GiB free; progress was retained")


def _ensure_legacy_cache(ref, processor, cache_root):
    """Create the small legacy NPZ caches when a checkout has only raw WAVs."""
    cache_root.mkdir(parents=True, exist_ok=True)
    for mode, count in LEGACY_COUNTS.items():
        destination = cache_root / (mode + ".npz")
        if destination.exists():
            continue
        waves, labels, boundaries, logits = [], [], [], []
        for start in range(0, count, BATCH_SIZE):
            stop = min(count, start + BATCH_SIZE)
            batch_waves, batch_labels = ref.get_batch(processor, mode, start, stop - start)
            batch_boundary, batch_logits = ref.boundary_and_logits(batch_waves)
            waves.append(batch_waves); labels.append(batch_labels)
            boundaries.append(batch_boundary); logits.append(batch_logits)
        _npz(destination, waveforms=np.concatenate(waves), labels=np.concatenate(labels),
             boundary=np.concatenate(boundaries), float_logits=np.concatenate(logits))
        print("legacy cache created: " + str(destination), flush=True)


def _pcm_fingerprint(waveform):
    sample = np.asarray(waveform, dtype=np.float32).reshape(-1)
    if sample.shape != (16000,) or not np.all(np.isfinite(sample)):
        raise ValueError("Expected a finite 16000-sample waveform")
    scaled = sample.astype(np.float64) * 32768
    if np.any(scaled < -32768) or np.any(scaled > 32767) or not np.array_equal(scaled, np.rint(scaled)):
        raise ValueError("Cached waveform is not exact signed PCM16 / 32768")
    return hashlib.sha256(scaled.astype("<i2").tobytes()).hexdigest()


def _decode_pcm(contents):
    with wave.open(io.BytesIO(contents), "rb") as handle:
        if (handle.getnchannels(), handle.getsampwidth(), handle.getframerate()) != (1, 2, 16000):
            raise ValueError("Expected mono PCM16 at 16000 Hz")
        raw = np.frombuffer(handle.readframes(handle.getnframes()), dtype="<i2")
    padded = np.zeros(16000, dtype="<i2")
    padded[:min(len(raw), 16000)] = raw[:16000]
    return hashlib.sha256(padded.tobytes()).hexdigest()


def _speaker(relative_path):
    return Path(relative_path).name.split("_nohash_", 1)[0]


def _select_per_class(labels, count):
    selected = []
    labels = np.asarray(labels)
    for label in range(12):
        indices = np.flatnonzero(labels == label)[:count]
        if len(indices) != count:
            raise ValueError("Not enough validation samples for class %d" % label)
        selected.extend(indices.tolist())
    return selected


def _check_leakage(split_records):
    result = {"status": "passed", "silence_policy": "synthetic zero waveform; excluded from speech identity comparisons", "pairs": {}}
    names = sorted(split_records)
    keys = ("relative_path", "sha256", "speaker")
    for i, first in enumerate(names):
        for second in names[i + 1:]:
            pair = {}
            for key in keys:
                first_set = set()
                second_set = set()
                for records, destination in ((split_records[first], first_set), (split_records[second], second_set)):
                    for record in records:
                        if record["silence"]:
                            continue
                        for source in record["source_candidates"]:
                            destination.add(source[key])
                overlap = sorted(first_set & second_set)
                pair[key] = {"overlap_count": len(overlap), "examples": overlap[:20]}
                if overlap:
                    result["status"] = "failed"
            result["pairs"][first + "__" + second] = pair
    return result


def _source_for_file(path, data_dir, label, which_set, validation_percentage, testing_percentage):
    contents = path.read_bytes()
    relative = path.relative_to(data_dir).as_posix()
    return _decode_pcm(contents), {
        "relative_path": relative,
        "sha256": hashlib.sha256(contents).hexdigest(),
        "speaker": _speaker(relative),
        "source_label": path.parent.name,
        "label": int(label),
        "partition": which_set(str(path), validation_percentage, testing_percentage),
    }


def _record(index, label, candidates):
    silence = int(label) == 0
    return {"index": int(index), "label": int(label), "silence": silence,
            "source_candidates": [] if silence else candidates,
            "source_unique": not silence and len(candidates) == 1,
            "silence_generation": "official zero waveform without background" if silence else None}


def _restore_sources(ref, processor, data_dir, cache_root, manifest_path, identity, resume):
    if resume and manifest_path.exists():
        saved = json.loads(manifest_path.read_text(encoding="utf-8"))
        if saved.get("identity") == identity:
            for records in saved["splits"].values():
                for record in records:
                    for source in record["source_candidates"]:
                        if _hash(data_dir / source["relative_path"]) != source["sha256"]:
                            raise ValueError("Source file content changed: " + source["relative_path"])
            return saved["splits"], saved["recovery"]
    requests = {}
    labels_by_mode = {}
    fingerprints = {}
    for mode, count in LEGACY_COUNTS.items():
        with np.load(cache_root / (mode + ".npz"), allow_pickle=False) as data:
            labels, waves = data["labels"], data["waveforms"]
        if labels.shape != (count,) or waves.shape != (count, 16000):
            raise ValueError("Unexpected legacy cache shape: " + mode)
        labels_by_mode[mode] = labels
        fingerprints[mode] = []
        for index, (label, waveform) in enumerate(zip(labels, waves)):
            if label == 0:
                if np.any(waveform != 0):
                    raise ValueError("Cached silence contains nonzero audio")
                fingerprints[mode].append(None)
                continue
            fingerprint = _pcm_fingerprint(waveform)
            key = (mode, int(label), fingerprint)
            requests.setdefault(key, [])
            fingerprints[mode].append(key)
        del waves
    all_files = sorted(p for p in data_dir.glob("*/*.wav") if p.parent.name != "_background_noise_")
    wanted = {value[2] for value in requests}
    matched_files = 0
    for index, path in enumerate(all_files):
        label = processor.word_to_index[path.parent.name]
        contents = path.read_bytes()
        fingerprint = _decode_pcm(contents)
        if fingerprint in wanted:
            partition = ref.input_data.which_set(str(path), processor.quant_flags.validation_percentage,
                                                processor.quant_flags.testing_percentage)
            key = (partition, int(label), fingerprint)
            if key in requests:
                relative = path.relative_to(data_dir).as_posix()
                requests[key].append({"relative_path": relative, "sha256": hashlib.sha256(contents).hexdigest(),
                                      "speaker": _speaker(relative), "source_label": path.parent.name,
                                      "label": int(label), "partition": partition})
                matched_files += 1
        if index == 0 or (index + 1) % 10000 == 0 or index + 1 == len(all_files):
            print("source PCM recovery: %d / %d WAV files, %d matches" % (index + 1, len(all_files), matched_files), flush=True)
    missing = [key for key, sources in requests.items() if not sources]
    if missing:
        raise ValueError("Cannot recover %d cached waveform sources; first: %r" % (len(missing), missing[:5]))
    splits = {}
    for mode, labels in labels_by_mode.items():
        splits[mode] = [_record(i, label, [] if key is None else requests[key])
                        for i, (label, key) in enumerate(zip(labels, fingerprints[mode]))]
    recovery = {"method": "exact padded PCM16 identity, label and upstream hash partition",
                "upstream_order_reused": False, "reason": "Windows gfile.Glob enumeration varies between constructions",
                "ambiguous_audio_count": sum(not r["silence"] and not r["source_unique"] for records in splits.values() for r in records),
                "scanned_wav_count": len(all_files)}
    _json(manifest_path, {"identity": identity, "splits": splits, "recovery": recovery})
    return splits, recovery


def _freeze_validation_sources(ref, processor, data_dir, manifest_path, identity, resume):
    if resume and manifest_path.exists():
        saved = json.loads(manifest_path.read_text(encoding="utf-8"))
        if saved.get("identity") == identity:
            records = saved["records"]
            for record in records:
                for source in record["source_candidates"]:
                    if _hash(data_dir / source["relative_path"]) != source["sha256"]:
                        raise ValueError("Validation source file changed")
            return records
    records = []
    for index, sample in enumerate(processor.data_index["validation"]):
        label = processor.word_to_index[sample["label"]]
        sources = []
        if label != 0:
            path = Path(sample["file"])
            _, source = _source_for_file(path, data_dir, label, ref.input_data.which_set,
                                         processor.quant_flags.validation_percentage,
                                         processor.quant_flags.testing_percentage)
            sources.append(source)
        records.append(_record(index, label, sources))
    _json(manifest_path, {"identity": identity, "order_policy": "first current official processor index, frozen explicitly", "records": records})
    return records


def _processor_records(records, data_dir, silence_source):
    result = []
    for record in records:
        if record["silence"]:
            result.append({"label": "_silence_", "file": str(silence_source)})
        else:
            source = record["source_candidates"][0]
            result.append({"label": source["source_label"], "file": str(data_dir / source["relative_path"])})
    return result


def _verify_legacy(ref, processor, data_dir, cache_root, records, experiment_cache, identity, resume):
    marker = experiment_cache / "legacy_verification.json"
    progress = {"identity": identity, "splits": {}}
    if resume and marker.exists():
        saved = json.loads(marker.read_text(encoding="utf-8"))
        if saved.get("identity") == identity:
            progress = saved
    silence_source = next(data_dir.glob("yes/*.wav"))
    for mode in LEGACY_COUNTS:
        state = progress["splits"].setdefault(mode, {"next_index": 0, "boundary_max_absolute_error": 0.,
                                                    "logits_max_absolute_error": 0., "waveforms_bit_exact": True})
        processor.data_index[mode] = _processor_records(records[mode], data_dir, silence_source)
        with np.load(cache_root / (mode + ".npz"), allow_pickle=False) as data:
            labels, waveforms, boundary, logits = [data[name] for name in ("labels", "waveforms", "boundary", "float_logits")]
        for start in range(state["next_index"], len(labels), BATCH_SIZE):
            _space(experiment_cache)
            stop = min(start + BATCH_SIZE, len(labels))
            x, y = ref.get_batch(processor, mode, start, stop - start)
            if not np.array_equal(y, labels[start:stop]) or not np.array_equal(x, waveforms[start:stop]):
                raise AssertionError("Recovered official audio/label mismatch: %s [%d:%d]" % (mode, start, stop))
            actual_boundary, actual_logits = ref.boundary_and_logits(x)
            boundary_error = float(np.max(np.abs(actual_boundary - boundary[start:stop])))
            logit_error = float(np.max(np.abs(actual_logits - logits[start:stop])))
            if not np.allclose(actual_boundary, boundary[start:stop], atol=1e-6, rtol=1e-6):
                raise AssertionError("Recovered boundary mismatch: %s [%d:%d], max %g" % (mode, start, stop, boundary_error))
            if not np.allclose(actual_logits, logits[start:stop], atol=1e-4, rtol=1e-4):
                raise AssertionError("Recovered official logits mismatch: %s [%d:%d], max %g" % (mode, start, stop, logit_error))
            if not np.array_equal(np.argmax(actual_logits, 1), np.argmax(logits[start:stop], 1)):
                raise AssertionError("Recovered official prediction mismatch")
            state["boundary_max_absolute_error"] = max(state["boundary_max_absolute_error"], boundary_error)
            state["logits_max_absolute_error"] = max(state["logits_max_absolute_error"], logit_error)
            state["next_index"] = stop
            _json(marker, progress)
            if start == 0 or stop % 512 == 0 or stop == len(labels):
                print("legacy official regeneration: %s %d / %d" % (mode, stop, len(labels)), flush=True)
        state["count"] = len(labels)
        state["status"] = "verified"
        del labels, waveforms, boundary, logits
    _json(marker, progress)
    return progress["splits"]


def _build_full_validation(ref, processor, data_dir, records, cache, identity, resume):
    destination = cache / "validation_full.npz"
    marker = cache / "validation_full_progress.json"
    state = {"identity": identity, "batches": {}}
    if resume and marker.exists():
        saved = json.loads(marker.read_text(encoding="utf-8"))
        if saved.get("identity") == identity:
            state = saved
    if state.get("status") == "complete" and destination.exists() and _hash(destination) == state.get("sha256"):
        return state
    batches = cache / "validation_batches"
    batches.mkdir(exist_ok=True)
    processor.data_index["validation"] = _processor_records(records, data_dir, next(data_dir.glob("yes/*.wav")))
    for start in range(0, len(records), BATCH_SIZE):
        stop = min(start + BATCH_SIZE, len(records))
        filename = "%06d.npz" % start
        path = batches / filename
        prior = state["batches"].get(filename)
        if resume and prior and path.exists() and _hash(path) == prior["sha256"]:
            continue
        _space(cache)
        waveforms, labels = ref.get_batch(processor, "validation", start, stop - start)
        expected_labels = np.asarray([r["label"] for r in records[start:stop]])
        if not np.array_equal(labels, expected_labels):
            raise AssertionError("Frozen full validation labels disagree with official processor")
        boundary, logits = ref.boundary_and_logits(waveforms)
        if not np.all(np.isfinite(boundary)) or not np.all(np.isfinite(logits)):
            raise ValueError("Nonfinite full validation reference")
        _npz(path, boundary=boundary, labels=labels, float_logits=logits)
        state["batches"][filename] = {"start": start, "stop": stop, "sha256": _hash(path)}
        state["next_index"] = stop
        _json(marker, state)
        if start == 0 or stop % 512 == 0 or stop == len(records):
            print("full official validation: %d / %d" % (stop, len(records)), flush=True)
    collected = {"boundary": [], "labels": [], "float_logits": []}
    for start in range(0, len(records), BATCH_SIZE):
        with np.load(batches / ("%06d.npz" % start), allow_pickle=False) as data:
            for name in collected:
                collected[name].append(data[name])
    _space(cache)
    _npz(destination, **{name: np.concatenate(values) for name, values in collected.items()})
    state.update(status="complete", count=len(records), path=str(destination), sha256=_hash(destination))
    _json(marker, state)
    return state


def prepare_experiment_data(data_root, repo_root, experiment_root, ref=None, resume=True):
    """Prepare verified legacy lineage, frozen full validation and FP32 weights.

    Legacy NPZs are read in place.  Every artifact produced by this function is
    contained in ``experiment_root``.  A supplied Reference remains open.
    """
    data_root, repo_root, experiment_root = (Path(p).resolve() for p in (data_root, repo_root, experiment_root))
    # Keep dataset acquisition outside TensorFlow so a new checkout can resume
    # the experiment without any machine-specific drive letter or manual copy.
    prepare_dataset(data_root)
    data_dir, legacy = data_root / "data2", data_root / "cache"
    experiment_cache = experiment_root / "cache"
    experiment_cache.mkdir(parents=True, exist_ok=True)
    _space(experiment_root)
    upstream = repo_root / "third-party" / "kwt"
    files = [repo_root / "quantization" / "reference.py", Path(__file__),
             upstream / "kws_streaming" / "data" / "input_data.py"]
    files += sorted((upstream / "models_data_v2_12_labels" / "kwt1").glob("best_weights.*"))
    files += [upstream / "models_data_v2_12_labels" / "kwt1" / "flags.txt"]
    files += [legacy / (mode + ".npz") for mode in LEGACY_COUNTS]
    identity = {"files": {str(path): _hash(path) for path in files}, "batch_size": BATCH_SIZE,
                "numpy_version": np.__version__, "schema_version": 1}
    owned = ref is None
    if owned:
        from .reference import load_reference
        ref = load_reference(repo_root)
    try:
        weights_path = experiment_cache / "weights.npz"
        weights_meta = experiment_cache / "weights.json"
        weights_identity = {key: value for key, value in identity["files"].items() if "best_weights." in key or key.endswith("reference.py")}
        previous = json.loads(weights_meta.read_text(encoding="utf-8")) if weights_meta.exists() else {}
        if not (resume and weights_path.exists() and previous.get("identity") == weights_identity and previous.get("sha256") == _hash(weights_path)):
            _npz(weights_path, **ref.weights())
            _json(weights_meta, {"identity": weights_identity, "sha256": _hash(weights_path)})
        print("FP32 weight cache ready: " + str(weights_path), flush=True)
        processor = ref.build_processor(data_dir)
        _ensure_legacy_cache(ref, processor, legacy)
        original_counts = {mode: len(records) for mode, records in processor.data_index.items()}
        original_validation = list(processor.data_index["validation"])
        sources, recovery = _restore_sources(ref, processor, data_dir, legacy,
                                              experiment_cache / "legacy_sources.json", identity, resume)
        processor.data_index["validation"] = original_validation
        full_sources = _freeze_validation_sources(ref, processor, data_dir,
                                                   experiment_cache / "validation_full_sources.json", identity, resume)
        audit = _check_leakage({"calibration_training": sources["training"], "validation_subset": sources["validation"],
                                "testing": sources["testing"]})
        full_audit = _check_leakage({"calibration_training": sources["training"], "validation_full": full_sources,
                                     "testing": sources["testing"]})
        _json(experiment_cache / "leakage_audit.json", {"legacy": audit, "full_validation": full_audit})
        if audit["status"] != "passed" or full_audit["status"] != "passed":
            raise AssertionError("Real speech path/content/speaker leakage; inspect leakage_audit.json")
        verification = _verify_legacy(ref, processor, data_dir, legacy, sources, experiment_cache, identity, resume)
        full_state = _build_full_validation(ref, processor, data_dir, full_sources, experiment_cache, identity, resume)
        with np.load(legacy / "validation.npz", allow_pickle=False) as data:
            labels = data["labels"]
        with np.load(legacy / "training.npz", allow_pickle=False) as data:
            training_labels = data["labels"]
        metadata = {"status": "complete", "identity": identity, "labels": LABELS,
                    "cache_paths": {**{mode: str(legacy / (mode + ".npz")) for mode in LEGACY_COUNTS},
                                    "validation_full": full_state["path"], "weights": str(weights_path)},
                    "weights_path": str(weights_path), "validation_full_path": full_state["path"],
                    "counts": {**LEGACY_COUNTS, "validation_full": full_state["count"]},
                    "official_processor_counts": original_counts, "legacy_verification": verification,
                    "prescreen_indices": _select_per_class(labels, 10), "golden_indices": _select_per_class(labels, 2),
                    "training_class_counts": np.bincount(training_labels, minlength=12).tolist(),
                    "lineage_recovery": recovery, "leakage_audit_status": "passed",
                    "validation_full_sha256": full_state["sha256"], "weights_sha256": _hash(weights_path),
                    "lineage_manifests": {"legacy": str(experiment_cache / "legacy_sources.json"),
                                          "validation_full": str(experiment_cache / "validation_full_sources.json")},
                    "cache_order_policy": "legacy exact retained; full validation official index frozen in source manifest"}
        _json(experiment_root / "metadata.json", metadata)
        print("Experiment data ready: full validation %d, test %d, lineage verified" %
              (full_state["count"], LEGACY_COUNTS["testing"]), flush=True)
        return metadata
    finally:
        if owned:
            ref.close()


if __name__ == "__main__":
    import argparse
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", required=True)
    parser.add_argument("--repo-root", default=".")
    parser.add_argument("--experiment-root", required=True)
    parser.add_argument("--no-resume", action="store_true")
    options = parser.parse_args()
    prepare_experiment_data(options.data_root, options.repo_root, options.experiment_root,
                            resume=not options.no_resume)
