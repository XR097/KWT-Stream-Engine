"""Portable, checked NumPy and little-endian deployment packages."""
import hashlib
import json
from pathlib import Path

import numpy as np

from .integer import IntegerEncoder, quantize, saturate


def pack_int4(value):
    """Pack row-major signed nibbles, low nibble first, zero odd tail."""
    value = np.asarray(value)
    if value.dtype.kind not in "iu" or (value.size and (int(value.min()) < -8 or int(value.max()) > 7)):
        raise ValueError("W4 values must be integers in [-8,7]")
    flat = value.astype(np.int8, copy=False).reshape(-1)
    nibbles = flat.astype(np.uint8) & 15
    result = np.zeros((flat.size + 1) // 2, dtype=np.uint8)
    result[:] = nibbles[::2]
    result[:flat.size // 2] |= nibbles[1::2] << 4
    return result


def unpack_int4(data, shape):
    data = np.asarray(data, dtype=np.uint8).reshape(-1)
    count = int(np.prod(shape, dtype=np.int64))
    if data.size != (count + 1) // 2:
        raise ValueError("packed W4 size does not match shape")
    if count % 2 and data.size and int(data[-1]) >> 4:
        raise ValueError("packed W4 odd tail must have zero high nibble")
    nibbles = np.empty(data.size * 2, dtype=np.uint8)
    nibbles[::2] = data & 15
    nibbles[1::2] = data >> 4
    signed = nibbles[:count].astype(np.int8)
    signed = np.where(signed >= 8, signed - 16, signed).astype(np.int8)
    return signed.reshape(shape)


def _smallest_dtype(value):
    value = np.asarray(value)
    if value.dtype.kind not in "iu":
        raise TypeError("profile arrays must contain integers")
    low, high = (int(value.min()), int(value.max())) if value.size else (0, 0)
    for code in (("u1", "<u2", "<u4", "<u8") if low >= 0 else ("i1", "<i2", "<i4", "<i8")):
        bounds = np.iinfo(code)
        if low >= int(bounds.min) and high <= int(bounds.max):
            return np.dtype(code)
    raise OverflowError("profile value cannot be represented by 64-bit integer")


def _bits(value, unsigned=False):
    value = np.asarray(value)
    low, high = (int(value.min()), int(value.max())) if value.size else (0, 0)
    if unsigned:
        return max(1, high.bit_length())
    return max(1, max(high, 0).bit_length() + 1,
               (max(-low, 0) - 1).bit_length() + 1 if low < 0 else 1)


def profile_storage_spec(params, key, value):
    """Return actual physical encoding; shared by export and hardware reports."""
    value = np.asarray(value)
    version = int(params.get("format_version", 2))
    encoding = "plain"
    logical_bits = _bits(value, value.dtype.kind == "u")
    if version < 3:
        dtype = value.dtype.newbyteorder("<")
    elif key.endswith(".weight"):
        logical_bits = int(params.get("weight_bits_by_linear", {}).get(key[:-7], params.get("weight_bits", 8)))
        if logical_bits not in (4, 8):
            raise ValueError("v3 deployment weights require W4 or W8")
        low, high = -(1 << (logical_bits - 1)), (1 << (logical_bits - 1)) - 1
        if value.size and (int(value.min()) < low or int(value.max()) > high):
            raise OverflowError("weight outside declared encoding: " + key)
        dtype = np.dtype("i1")
        encoding = "signed_twos_complement_nibbles_low_first" if logical_bits == 4 else "plain"
    elif key.endswith(".bias"):
        if value.size and (int(value.min()) < -(1 << 31) or int(value.max()) > (1 << 31) - 1):
            raise OverflowError("bias outside int32: " + key)
        dtype = np.dtype("<i4")
        logical_bits = 32
    else:
        dtype = _smallest_dtype(value)
        logical_bits = _bits(value, dtype.kind == "u")
    return {"dtype": str(dtype), "binary_dtype": "|u1" if encoding != "plain" else dtype.str,
            "logical_bits": logical_bits, "physical_encoding": encoding,
            "physical_container_bits": dtype.itemsize * 8,
            "binary_bytes": (value.size + 1) // 2 if encoding != "plain" else value.size * dtype.itemsize}


def _sha256(path):
    return hashlib.sha256(Path(path).read_bytes()).hexdigest()


def save_profile(root, name, params, arrays):
    root = Path(root); root.mkdir(parents=True, exist_ok=True)
    folder = root / name; folder.mkdir(exist_ok=True)
    meta = dict(params); meta["arrays"] = {}
    for key, value in arrays.items():
        value = np.asarray(value)
        storage = profile_storage_spec(params, key, value)
        value = np.ascontiguousarray(value, dtype=storage["dtype"])
        filename = key.replace("/", "_").replace(".", "__") + ".npy"
        binary = filename[:-4] + ".bin"
        np.save(folder / filename, value, allow_pickle=False)
        if storage["physical_encoding"] != "plain":
            pack_int4(value).tofile(folder / binary)
        else:
            value.tofile(folder / binary)
        spec = dict(storage, file=filename, binary=binary, shape=list(value.shape),
                    byte_order="little", layout="row-major-little-endian",
                    diagnostic=key in params.get("diagnostic_arrays", []),
                    binary_sha256=_sha256(folder / binary), npy_sha256=_sha256(folder / filename))
        if not np.array_equal(_read_binary(folder, spec), value):
            raise AssertionError("profile binary mismatch: " + key)
        meta["arrays"][key] = spec
    (folder / "profile.json").write_text(json.dumps(meta, indent=2, sort_keys=True), encoding="utf-8")
    return folder


def _read_binary(folder, spec):
    path = Path(folder) / spec["binary"]
    count = int(np.prod(spec["shape"], dtype=np.int64))
    packed = spec.get("physical_encoding", "plain") == "signed_twos_complement_nibbles_low_first"
    dtype = np.dtype(spec.get("binary_dtype", spec["dtype"]))
    expected = (count + 1) // 2 if packed else count * dtype.itemsize
    if path.stat().st_size != expected:
        raise ValueError("profile binary size mismatch: " + str(path))
    if spec.get("binary_sha256") and _sha256(path) != spec["binary_sha256"]:
        raise ValueError("profile binary checksum mismatch: " + str(path))
    data = np.fromfile(path, dtype=dtype)
    return unpack_int4(data, spec["shape"]) if packed else data.reshape(spec["shape"])


def load_profile(folder):
    """Prefer binary arrays, verifying optional NumPy mirrors when present."""
    folder = Path(folder)
    meta = json.loads((folder / "profile.json").read_text(encoding="utf-8"))
    arrays = {}
    for key, spec in meta.pop("arrays").items():
        npy = folder / spec["file"]
        if spec.get("binary") and (folder / spec["binary"]).is_file():
            value = _read_binary(folder, spec)
            if npy.is_file():
                if spec.get("npy_sha256") and _sha256(npy) != spec["npy_sha256"]:
                    raise ValueError("profile NumPy checksum mismatch: " + key)
                mirrored = np.load(npy, allow_pickle=False)
                if mirrored.shape != value.shape or not np.array_equal(mirrored, value):
                    raise ValueError("profile NumPy/binary mismatch: " + key)
        elif int(meta.get("format_version", 2)) < 3:
            value = np.load(npy, allow_pickle=False)
        else:
            raise FileNotFoundError("v3 deployment binary missing: " + key)
        if list(value.shape) != spec["shape"]:
            raise ValueError("profile shape mismatch: " + key)
        arrays[key] = value
    return meta, arrays


def _write_tensor(folder, prefix, value, dtype=None, exponent=None, logical_bits=None):
    value = np.asarray(value)
    dtype = np.dtype(dtype) if dtype else _smallest_dtype(value)
    if value.size and value.dtype.kind in "iu":
        bounds = np.iinfo(dtype)
        if int(value.min()) < int(bounds.min) or int(value.max()) > int(bounds.max):
            raise OverflowError("tensor outside export dtype: " + prefix)
    value = np.ascontiguousarray(value, dtype=dtype.newbyteorder("<"))
    if logical_bits is None:
        logical_bits = _bits(value, dtype.kind == "u") if dtype.kind in "iu" else dtype.itemsize * 8
    np.save(folder / (prefix + ".npy"), value, allow_pickle=False)
    value.tofile(folder / (prefix + ".bin"))
    restored = np.fromfile(folder / (prefix + ".bin"), dtype=value.dtype).reshape(value.shape)
    if not np.array_equal(restored, value) or not np.array_equal(np.load(folder / (prefix + ".npy")), value):
        raise AssertionError("NumPy/binary mismatch: " + prefix)
    return {"npy": prefix + ".npy", "binary": prefix + ".bin", "shape": list(value.shape),
            "dtype": value.dtype.str, "layout": "row-major", "byte_order": "little",
            "physical_encoding": "plain", "logical_bits": logical_bits,
            "exponent": exponent, "binary_bytes": value.nbytes,
            "binary_sha256": _sha256(folder / (prefix + ".bin"))}


def export_golden(folder, samples, encoder, head_weights, input_exponent, layer_traces=False):
    """Export a self-contained package and verify repeat and binary reload."""
    folder = Path(folder); folder.mkdir(parents=True, exist_ok=True)
    samples = np.asarray(samples)
    if samples.ndim != 3 or samples.shape[1:] != (99, 64) or not len(samples):
        raise ValueError("golden samples must have shape [count,99,64] and be nonempty")
    expected_exponent = encoder.exponents[encoder.params["blocks"][0] + ".input"]
    if input_exponent != expected_exponent:
        raise ValueError("golden input exponent does not match encoder profile")
    manifest_path = folder / "golden_manifest.json"
    manifest_path.write_text(json.dumps({"count": len(samples), "reload_bit_exact": False,
                                         "status": "verification_pending"}), encoding="utf-8")
    profile_folder = save_profile(folder, "profile", encoder.params, encoder.arrays)
    reloaded = IntegerEncoder(*load_profile(profile_folder))
    compact = int(encoder.params.get("format_version", 2)) >= 3
    boundary_dtype = "i1" if compact else "<i8"
    records = []
    for i, sample in enumerate(samples):
        qi = quantize(sample, input_exponent, encoder.params["activation_bits"])
        out, traces = encoder.run(qi, trace=layer_traces)
        repeated, _ = encoder.run(qi)
        if not np.array_equal(out, repeated):
            raise AssertionError("golden repeat mismatch at sample %d" % i)
        record = {"index": i, "tensors": {}}
        for name, value, dtype, exponent in (
                ("input", sample, "<f4", None),
                ("input_int", qi, boundary_dtype, input_exponent),
                ("output", out, boundary_dtype, encoder.exponents[encoder.params["blocks"][-1] + ".output"])):
            prefix = "sample_%02d_%s" % (i, name)
            record["tensors"][name] = _write_tensor(folder, prefix, value, dtype, exponent,
                                                   None if name == "input" else encoder.bits)
        if layer_traces:
            record["layer_traces"] = {}
            for key, value in traces.items():
                prefix = "sample_%02d_trace_%s" % (i, key.replace(".", "__"))
                dtype = None
                if compact:
                    frac = int(encoder.params.get("softmax_configs", {}).get(key.split(".")[0], {}).get("prob_frac", 15))
                    dtype = ("u1" if frac <= 8 else "<u2") if key.endswith(".softmax") else "i1"
                record["layer_traces"][key] = _write_tensor(folder, prefix, value,
                                                            dtype=dtype, exponent=encoder.exponents.get(key))
        saved_input = np.fromfile(folder / record["tensors"]["input_int"]["binary"], dtype=boundary_dtype).reshape(qi.shape)
        actual, reloaded_traces = reloaded.run(saved_input, trace=layer_traces)
        saved_output = np.fromfile(folder / record["tensors"]["output"]["binary"], dtype=boundary_dtype).reshape(out.shape)
        if not np.array_equal(actual, saved_output):
            raise AssertionError("golden package reload mismatch at sample %d" % i)
        if layer_traces:
            for key, value in traces.items():
                spec = record["layer_traces"][key]
                binary_value = np.fromfile(folder / spec["binary"], dtype=spec["dtype"]).reshape(spec["shape"])
                if not np.array_equal(reloaded_traces[key], value) or not np.array_equal(binary_value, value):
                    raise AssertionError("golden layer reload mismatch: " + key)
        records.append(record)
    manifest = {"count": len(samples), "input_shape": [99, 64], "output_shape": [99, 64],
                "input_exponent": input_exponent, "output_exponent": encoder.exponents[encoder.params["blocks"][-1] + ".output"],
                "dtype": "int8" if compact else "int64", "byte_order": "little", "rounding": "nearest_even",
                "weight_bits": encoder.params["weight_bits"],
                "weight_bits_by_linear": encoder.params.get("weight_bits_by_linear", {}),
                "nonlinear": encoder.params.get("nonlinear", {}),
                "softmax_configs": encoder.params.get("softmax_configs", {}),
                "gelu_configs": encoder.params.get("gelu_configs", {}),
                "layernorm_configs": encoder.params.get("layernorm_configs", {}),
                "activation_bits": encoder.params["activation_bits"],
                "mac_accumulator_bits": encoder.params.get("accumulator_bits", 64),
                "residual_accumulator_bits": encoder.params.get("residual_accumulator_bits", 64),
                "wide_temporary_bits": encoder.params.get("wide_temporary_bits", 64),
                "saturation": encoder.params["saturation"], "layer_traces": bool(layer_traces),
                "profile": "profile/profile.json", "samples": records,
                "numpy_binary_bit_exact": True, "repeat_bit_exact": True,
                "verified_sample_count": len(records), "reload_bit_exact": True, "status": "verified"}
    temporary = manifest_path.with_suffix(".json.tmp")
    temporary.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    temporary.replace(manifest_path)
    return manifest


def export_operator_vectors(folder, encoder):
    """Write boundary vectors and compare operator results after package reload."""
    folder = Path(folder); folder.mkdir(parents=True, exist_ok=True)
    path = folder / "operator_manifest.json"
    path.write_text(json.dumps({"status": "verification_pending"}), encoding="utf-8")
    restored = IntegerEncoder(*load_profile(save_profile(folder, "profile", encoder.params, encoder.arrays)))
    records = []
    for b in encoder.params["blocks"]:
        vectors = [
            ("gelu_all_int8", np.arange(-128, 128, dtype=np.int64), "gelu", b + ".gelu"),
            ("softmax_uniform", np.zeros((99, 99), dtype=np.int64), "softmax", b + ".softmax"),
            ("softmax_extreme", np.tile(np.r_[127, np.full(98, -128)], (99, 1)), "softmax", b + ".softmax"),
        ]
        for norm in ("ln1", "ln2"):
            for name, value in (("zero", np.zeros((1, 64), dtype=np.int64)),
                                ("constant", np.full((1, 64), 127, dtype=np.int64)),
                                ("pattern", np.tile(np.array([-128, 127], dtype=np.int64), (1, 32)))):
                vectors.append((norm + "_" + name, value, "layernorm", b + "." + norm))
        for name, value, operator, key in vectors:
            def apply(target, argument):
                if operator == "gelu":
                    raw = target.gelu(argument, target.exponents[b + ".fc1"], target.exponents[b + ".gelu"], key)
                    config = target.params.get("gelu_configs", {}).get(key, {})
                    if config.get("presat_key"):
                        raw = target.arrays[config["presat_key"]][argument.astype(np.int64) + 128]
                    return raw, saturate(raw, target.bits)
                if operator == "softmax":
                    raw = target.softmax(argument, target.exponents[b + ".score"], key)
                    return raw, raw
                raw = target.layernorm(argument, key)
                return raw, saturate(raw, target.bits)
            raw, output = apply(encoder, value)
            prefix = b + "_" + name
            tensors = {"input": _write_tensor(folder, prefix + "_input", value, "i1"),
                       "pre_saturation": _write_tensor(folder, prefix + "_presat", raw),
                       "output": _write_tensor(folder, prefix + "_output", output)}
            inp = tensors["input"]
            saved = np.fromfile(folder / inp["binary"], dtype=inp["dtype"]).reshape(inp["shape"])
            repeated_raw, repeated = apply(restored, saved)
            if not np.array_equal(raw, repeated_raw) or not np.array_equal(output, repeated):
                raise AssertionError("operator package reload mismatch: " + prefix)
            records.append({"operator": operator, "key": key, "case": name, "tensors": tensors})
    manifest = {"status": "verified", "count": len(records), "vectors": records,
                "numpy_binary_bit_exact": True, "reload_bit_exact": True,
                "profile": "profile/profile.json", "byte_order": "little", "rounding": "nearest_even"}
    path.write_text(json.dumps(manifest, indent=2), encoding="utf-8")
    return manifest
