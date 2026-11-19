"""Export logical KWT checkpoints and KSE parameter binaries.

This is a binary checkpoint view of export_golden; the profile format is unchanged.
Only NumPy is needed when a profile, head weights and boundary cache exist.
"""
import argparse
import hashlib
import json
import sys
from pathlib import Path

import numpy as np

if __package__ in (None, ""):
    sys.path.insert(0, str(Path(__file__).resolve().parents[2]))

from quantization.export import export_golden, load_profile, pack_int4, unpack_int4
from quantization.integer import IntegerEncoder, checked_matmul, dequantize, saturate, shift_rne

CANDIDATE_ID = "d841686e3017837cd1a2"
CANDIDATE_NAME = CANDIDATE_ID + "_direct"
OPERATORS = "input q k v score softmax context proj res1 ln1 fc1 gelu fc2 res2 ln2".split()
DEFAULT_INDICES = tuple(range(8))


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as stream:
        for chunk in iter(lambda: stream.read(8 * 1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def write_json(path, value):
    path = Path(path)
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True), encoding="utf-8")
    temporary.replace(path)


def frozen_config():
    """Recover the exact canonical configuration without running any search."""
    config = {
        "gelu": "direct", "residual_accumulator_bits": 32,
        "weight_bits_by_linear": {"b%02d.%s" % (i, op): 4 for i in range(12)
                                  for op in ("q", "k", "v", "proj", "fc1", "fc2")},
        "softmax": {"table": "compact", "exp_frac": 15, "prob_frac": 7},
        "layernorm": {"method": "reference", "norm_frac": 12, "gamma_frac": 12},
    }
    actual = hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20]
    if actual != CANDIDATE_ID:
        raise AssertionError("frozen configuration identity changed")
    return config


def profile_identity(params):
    config = params.get("nonlinear", {})
    ident = hashlib.sha256(json.dumps(config, sort_keys=True, separators=(",", ":")).encode()).hexdigest()[:20]
    return ident, ident + "_" + str(config.get("gelu", "reference"))


def validate_frozen_profile(params):
    if len(params["blocks"]) != 12 or len(params["linears"]) != 72:
        raise ValueError("expected the 12-block/72-linear frozen KWT candidate")
    if params.get("nonlinear") != frozen_config():
        raise ValueError("profile does not contain the exact frozen configuration")
    if params["activation_bits"] != 8 or params.get("accumulator_bits") != 32 or params.get("residual_accumulator_bits") != 32:
        raise ValueError("frozen candidate requires A8 and int32 MAC/residual")


def pack_weight_rows(weight):
    """[input,output] -> W^T rows, independent pairs along input."""
    weight = np.asarray(weight)
    if weight.ndim != 2:
        raise ValueError("W4 weight must have shape [input,output]")
    # Pad each row independently: for odd K the next output must not share
    # the final byte's high nibble. Real KWT dimensions are even.
    return np.stack([pack_int4(row) for row in weight.T]).reshape(-1)


def unpack_weight_rows(data, shape):
    outputs, inputs = map(int, shape)
    data = np.asarray(data, dtype=np.uint8)
    rows = data.reshape(outputs, (inputs + 1) // 2)
    return np.stack([unpack_int4(row, (inputs,)) for row in rows])


def write_binary(root, name, value, dtype, **metadata):
    array = np.asarray(value)
    dtype = np.dtype(dtype).newbyteorder("<")
    if array.dtype.kind in "iu" and array.size and dtype.kind in "iu":
        limits = np.iinfo(dtype)
        if array.min() < limits.min or array.max() > limits.max:
            raise OverflowError("parameter outside declared dtype: " + name)
    array = np.ascontiguousarray(array, dtype=dtype)
    relative = "parameters/" + name.replace(".", "__") + ".bin"
    path = Path(root) / relative
    path.parent.mkdir(parents=True, exist_ok=True)
    array.tofile(path)
    return dict(name=name, dtype=dtype.str, binary_dtype=dtype.str,
                shape=list(array.shape), file=relative, sha256=sha256(path),
                bytes=path.stat().st_size, byte_order="little", layout="row-major",
                **metadata)


def export_parameters(root, params, arrays, head_weights):
    tensors, linears, norms, gelu, softmax = {}, {}, {}, {}, {}
    for key, spec in sorted(params["linears"].items()):
        weight = np.asarray(arrays[key + ".weight"])
        bits = int(spec["weight_bits"])
        if bits == 4:
            packed = pack_weight_rows(weight)
            record = write_binary(root, key + ".weight", packed, "u1",
                                  encoding="signed_twos_complement_nibbles_low_first",
                                  logical_bits=4, exponent_parameter=key + ".weight_exponents")
            record.update(dtype="|i1", shape=list(weight.T.shape), layout="W_transpose_row_major",
                          source_shape=list(weight.shape), axes=["output", "input"],
                          packed_axis=1, row_stride_bytes=(weight.shape[0] + 1) // 2,
                          odd_input_high_nibble=0)
            np.testing.assert_array_equal(unpack_weight_rows(packed, weight.T.shape), weight.T)
        elif bits == 8:
            transposed = np.asarray(weight.T, dtype=np.int8)
            record = write_binary(root, key + ".weight", transposed, "i1",
                                  encoding="signed_int8_row_major", logical_bits=8,
                                  exponent_parameter=key + ".weight_exponents")
            record.update(dtype="|i1", shape=list(transposed.shape), layout="W_transpose_row_major",
                          source_shape=list(weight.shape), axes=["output", "input"])
            np.testing.assert_array_equal(np.fromfile(root / record["file"], dtype="i1").reshape(weight.T.shape), weight.T)
        else:
            raise ValueError("KSE export supports W4/W8 only: " + key)
        tensors[key + ".weight"] = record
        tensors[key + ".bias"] = write_binary(
            root, key + ".bias", arrays[key + ".bias"], "<i4",
            exponent="input_exponent + per_channel_weight_exponent",
            input_exponent=int(params["exponents"][spec["input"]]),
            exponent_parameter=key + ".weight_exponents", bias_before_requantization=True)
        shifts = (params["exponents"][spec["output"]] - params["exponents"][spec["input"]]
                  - np.asarray(arrays[key + ".weight_exponents"]))
        tensors[key + ".shift"] = write_binary(
            root, key + ".shift", shifts, "<i4", units="bits",
            convention="positive=RNE_right_shift; negative=left_shift")
        tensors[key + ".weight_exponents"] = write_binary(
            root, key + ".weight_exponents", arrays[key + ".weight_exponents"], "<i4",
            units="power_of_two_exponent")
        linears[key] = dict(spec, weight=key + ".weight", bias=key + ".bias",
                            shift=key + ".shift", input_exponent=params["exponents"][spec["input"]],
                            output_exponent=params["exponents"][spec["output"]])
    for key, spec in sorted(params["norms"].items()):
        config = params["layernorm_configs"][key]
        tensors[key + ".gamma"] = write_binary(
            root, key + ".gamma", arrays[key + ".gamma"], "<i4",
            exponent=-int(config["gamma_frac"]), q_format="Q%d" % config["gamma_frac"])
        tensors[key + ".beta"] = write_binary(
            root, key + ".beta", arrays[key + ".beta"], "<i4",
            exponent=int(params["exponents"][spec["output"]]))
        norms[key] = dict(spec, **config, gamma=key + ".gamma", beta=key + ".beta")
    for block, config in sorted(params["softmax_configs"].items()):
        key = config["table_key"]
        if key not in tensors:
            tensors[key] = write_binary(root, key, arrays[key], "<i4",
                                       exponent=-int(config["exp_frac"]), q_format="Q15",
                                       index_step_q8=16, table_entries=257)
        softmax[block] = dict(config)
    for key, config in sorted(params["gelu_configs"].items()):
        table = config["table_key"]
        if config["method"] not in ("direct", "middle"):
            raise ValueError("KSE export requires a frozen direct/middle GELU table")
        if table not in tensors:
            tensors[table] = write_binary(root, table, arrays[table], "i1",
                                         exponent=int(config["output_exponent"]),
                                         index="input - minimum_input",
                                         minimum_input=config["minimum_input"], maximum_input=config["maximum_input"])
        gelu[key] = dict(config)
    for key in ("head.weight", "head.bias"):
        tensors[key] = write_binary(root, key, head_weights[key], "<f4",
                                   numeric_format="IEEE754_binary32",
                                   scope="floating_class_token_head")
    return {"tensors": tensors, "linears": linears, "layernorm": norms,
            "gelu": gelu, "softmax": softmax}


def tensor_view(name, spec, exponent=None, **extra):
    result = dict(name=name, dtype=spec["dtype"], binary_dtype=spec["dtype"],
                  shape=spec["shape"], file=spec["binary"], sha256=spec["binary_sha256"],
                  bytes=spec["binary_bytes"], byte_order="little", layout="row-major",
                  exponent=spec.get("exponent") if exponent is None else exponent)
    result.update(extra)
    return result


def export_sim_golden(root, samples, encoder, head_weights, indices, source=None):
    root = Path(root)
    # The floating head is outside integer bit-exact scope. Fix its memory
    # order so a transposed TFLite view and its C-order binary reload use
    # the same float32 BLAS reduction path.
    head_weights = {k: np.ascontiguousarray(v, dtype=np.float32) for k, v in head_weights.items()}
    if len(samples) != len(indices) or len(set(indices)) != len(indices):
        raise ValueError("one unique source index is required per golden sample")
    root.mkdir(parents=True, exist_ok=True)
    path = root / "sim_manifest.json"
    write_json(path, {"status": "verification_pending"})
    golden = export_golden(root, samples, encoder, head_weights,
                           encoder.exponents[encoder.params["blocks"][0] + ".input"],
                           layer_traces=True)
    parameters = export_parameters(root, encoder.params, encoder.arrays, head_weights)
    records = []
    for record, source_index in zip(golden["samples"], indices):
        tensors = {key: tensor_view(key, spec) for key, spec in record["tensors"].items()}
        traces = record["layer_traces"]
        for key, spec in traces.items():
            frac = int(encoder.params.get("softmax_configs", {}).get(key.split(".")[0], {}).get("prob_frac", 15))
            probability_dtype = "|u1" if frac <= 8 else "<u2"
            tensors[key] = tensor_view(key, spec,
                                      q_format="U%d_Q%d" % (8 if frac <= 8 else 16, frac) if key.endswith(".softmax") else "signed_A8")
            # All ordinary outputs are A8 even if this sample's extrema
            # happened to let the general golden writer choose uint8.
            tensors[key]["dtype"] = tensors[key]["binary_dtype"] = probability_dtype if key.endswith(".softmax") else "|i1"
        def read(key):
            spec = tensors[key]
            return np.fromfile(root / spec["file"], dtype=spec["dtype"]).reshape(spec["shape"])
        for block in encoder.params["blocks"]:
            tensors[block + ".ln2"] = dict(tensors[block + ".output"], name=block + ".ln2",
                                              alias_of=block + ".output")
            for suffix, left, right, transpose in (
                    ("score.matmul", "q", "k", True),
                    ("context.matmul", "softmax", "v", False)):
                lhs, rhs = read(block + "." + left), read(block + "." + right)
                if transpose:
                    rhs = rhs.T
                value = checked_matmul(lhs.astype(np.int64), rhs.astype(np.int64),
                                       bits=int(encoder.params.get("accumulator_bits", 64)))
                name = block + "." + suffix
                raw_dtype = "<i4" if int(encoder.params.get("accumulator_bits", 64)) <= 32 else "<i8"
                spec = write_binary(root, "sample_%02d.%s" % (record["index"], name), value, raw_dtype,
                                    exponent=encoder.exponents[block + "." + left] + encoder.exponents[block + "." + right],
                                    stage="raw_int32_matmul_before_requantization")
                spec["name"] = name
                tensors[name] = spec
                if transpose:
                    source_e = spec["exponent"] + encoder.params["attention_scale_exponent"]
                    scaled = saturate(shift_rne(value, encoder.exponents[block + ".score"] - source_e), 8)
                    np.testing.assert_array_equal(scaled, read(block + ".score"))
                else:
                    scaled = saturate(shift_rne(value, encoder.exponents[block + ".context"] - spec["exponent"]), 8)
                    np.testing.assert_array_equal(scaled, read(block + ".context"))
        decoded = dequantize(read("output"), encoder.exponents[encoder.params["blocks"][-1] + ".output"])
        # Match reference.classify_float: explicit float32 class-token head.
        logits = np.asarray(decoded, np.float32)[0] @ head_weights["head.weight"] + head_weights["head.bias"]
        spec = write_binary(root, "sample_%02d.logits" % record["index"], logits, "<f4",
                            numeric_format="IEEE754_binary32", scope="floating_class_token_head")
        spec["name"] = "logits"
        tensors["logits"] = spec
        records.append({"index": record["index"], "source_index": int(source_index),
                        "prediction": int(np.argmax(logits)), "tensors": tensors})
    ident, name = profile_identity(encoder.params)
    manifest = {"format": "kwt-kse-golden-v1", "status": "verification_pending",
                "candidate": name, "config_id": ident,
                "blocks": encoder.params["blocks"], "count": len(records),
                "logical_token_count": 99, "padding": "none", "byte_order": "little",
                "integer_decode": "real = integer * 2**exponent", "rounding": "nearest_even",
                "attention_scale_exponent": encoder.params["attention_scale_exponent"],
                "score_stage": "score.matmul is raw Q*K^T; score includes 1/8 scaling, RNE and A8 saturation",
                "context_stage": "context.matmul is raw P*V; context is requantized A8",
                "profile": "profile/profile.json", "golden_manifest": "golden_manifest.json",
                "source": source or {}, "samples": records, "parameters": parameters}
    verify_manifest(root, manifest)
    manifest["status"] = "verified"
    write_json(path, manifest)
    return manifest


def verify_manifest(root, manifest=None):
    root = Path(root).resolve()
    if manifest is None:
        manifest = json.loads((root / "sim_manifest.json").read_text(encoding="utf-8"))
    records = manifest["samples"]
    if len(records) != manifest["count"] or len({r["source_index"] for r in records}) != len(records):
        raise ValueError("sample count/indices mismatch")
    specs = list(manifest["parameters"]["tensors"].values())
    for record in records:
        required = {block + "." + op for block in manifest["blocks"] for op in OPERATORS}
        if not required.issubset(record["tensors"]) or "logits" not in record["tensors"]:
            raise ValueError("missing operator checkpoints")
        specs.extend(record["tensors"].values())
    for spec in specs:
        path = (root / spec["file"]).resolve()
        if root not in path.parents:
            raise ValueError("manifest path escapes package")
        if sha256(path) != spec["sha256"]:
            raise ValueError("binary SHA256 mismatch: " + spec["name"])
        if spec["byte_order"] != "little":
            raise ValueError("unexpected byte order")
        dtype = np.dtype(spec["binary_dtype"])
        if dtype.itemsize > 1 and dtype.byteorder == ">":
            raise ValueError("big-endian tensor")
        if spec.get("encoding") == "signed_twos_complement_nibbles_low_first":
            expected = spec["shape"][0] * ((spec["shape"][1] + 1) // 2)
            unpack_weight_rows(np.fromfile(path, dtype="u1"), spec["shape"])
        else:
            expected = int(np.prod(spec["shape"])) * dtype.itemsize
        if path.stat().st_size != expected or spec["bytes"] != expected:
            raise ValueError("binary byte count mismatch: " + spec["name"])
    # Compare the packed binary view against the independent standard profile loader.
    params, arrays = load_profile(root / "profile")
    for key, linear in manifest["parameters"]["linears"].items():
        tensors = manifest["parameters"]["tensors"]
        spec = tensors[linear["weight"]]
        if spec.get("encoding") == "signed_twos_complement_nibbles_low_first":
            actual_weight = unpack_weight_rows(np.fromfile(root / spec["file"], dtype="u1"), spec["shape"])
        else:
            actual_weight = np.fromfile(root / spec["file"], dtype="i1").reshape(spec["shape"])
        np.testing.assert_array_equal(actual_weight, arrays[key + ".weight"].T)
        spec = tensors[linear["bias"]]
        np.testing.assert_array_equal(np.fromfile(root / spec["file"], dtype="<i4"), arrays[key + ".bias"])
        spec = tensors[linear["shift"]]
        np.testing.assert_array_equal(np.fromfile(root / spec["file"], dtype="<i4"),
            params["exponents"][linear["output"]] - params["exponents"][linear["input"]] - arrays[key + ".weight_exponents"])
    parameter_tensors = manifest["parameters"]["tensors"]
    def read_parameter(key):
        spec = parameter_tensors[key]
        return np.fromfile(root / spec["file"], dtype=spec["binary_dtype"]).reshape(spec["shape"])
    for record in records:
        def read_sample(key):
            spec = record["tensors"][key]
            return np.fromfile(root / spec["file"], dtype=spec["binary_dtype"]).reshape(spec["shape"])
        decoded = np.asarray(dequantize(read_sample("output"), params["exponents"][params["blocks"][-1] + ".output"]), np.float32)
        expected = decoded[0] @ read_parameter("head.weight") + read_parameter("head.bias")
        # Integer checkpoints and file hashes stay bit exact. The external
        # float32 head can differ by a few ULP across BLAS/CPU architectures.
        np.testing.assert_allclose(expected, read_sample("logits"), atol=1e-6, rtol=1e-6)
        if int(np.argmax(expected)) != record["prediction"]:
            raise ValueError("logit prediction mismatch")
    return {"status": "verified", "samples": len(records), "tensor_records": len(specs),
            "unique_binary_files": len({s["file"] for s in specs})}


def _load_tensor(folder, spec):
    """Load a standard golden tensor, checking size, digest and NumPy mirror."""
    path = folder / spec["binary"]
    expected = int(np.prod(spec["shape"], dtype=np.int64)) * np.dtype(spec["dtype"]).itemsize
    if path.stat().st_size != expected:
        raise ValueError("tensor byte size mismatch: %s" % path)
    if spec.get("binary_sha256") and sha256(path) != spec["binary_sha256"]:
        raise ValueError("tensor checksum mismatch: %s" % path)
    value = np.fromfile(path, dtype=np.dtype(spec["dtype"])).reshape(spec["shape"])
    npy = folder / spec.get("npy", "")
    if npy.is_file() and not np.array_equal(np.load(npy, allow_pickle=False), value):
        raise ValueError("NumPy/binary mismatch: %s" % path)
    return value


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    repo = Path(__file__).resolve().parents[2]
    parser.add_argument("--data-root", type=Path, default=repo / "kwt-data")
    parser.add_argument("--profile", type=Path)
    parser.add_argument("--package", type=Path, help="re-export every sample of an existing read-only golden package")
    parser.add_argument("--source-report", type=Path)
    parser.add_argument("--weights", type=Path)
    parser.add_argument("--cache", type=Path)
    parser.add_argument("--indices", default=",".join(map(str, DEFAULT_INDICES)))
    parser.add_argument("--output", type=Path)
    parser.add_argument("--verify-only", action="store_true")
    parser.add_argument("--asic", action="store_true", help="export a generic v3 A8/24-bit ASIC profile")
    args = parser.parse_args()
    output = args.output or args.data_root / "golden" / CANDIDATE_NAME
    if args.verify_only:
        print(json.dumps(verify_manifest(output), indent=2))
        return
    profile = args.package / "profile" if args.package else (args.profile or args.data_root / "profiles" / CANDIDATE_NAME)
    params, arrays = load_profile(profile)
    if args.asic:
        if params.get("format_version") != 3 or params.get("accumulator_bits") != 24 or params.get("activation_bits") != 8:
            raise ValueError("--asic requires v3 A8 / 24-bit MAC")
    elif not args.package:
        validate_frozen_profile(params)
    elif not args.output:
        output = args.data_root / "golden" / profile_identity(params)[1]
    if args.package:
        source_root, output_root = args.package.resolve(), output.resolve()
        if output_root == source_root or source_root in output_root.parents:
            raise ValueError("source golden package is read-only; choose a separate output")
    with np.load(args.weights or args.data_root / "cache" / "weights.npz", allow_pickle=False) as data:
        weights = {k: data[k] for k in ("head.weight", "head.bias")}
    if args.package:
        # Read standard golden tensors locally; no execution backend is needed.
        original = json.loads((args.package / "golden_manifest.json").read_text())
        samples = np.stack([_load_tensor(args.package, r["tensors"]["input"]) for r in original["samples"]])
        indices = [r["index"] for r in original["samples"]]
        source = {"package": str(args.package.resolve()),
                  "golden_manifest_sha256": sha256(args.package / "golden_manifest.json"),
                  "indices": indices, "selection": "all supplied golden records in manifest order"}
        if args.source_report:
            source["identification"] = json.loads(args.source_report.read_text())
        manifest = export_sim_golden(output, samples, IntegerEncoder(params, arrays), weights, indices, source)
        for old, new in zip(original["samples"], manifest["samples"]):
            for name, spec in old["layer_traces"].items():
                if (args.package / spec["binary"]).read_bytes() != (output / new["tensors"][name]["file"]).read_bytes():
                    manifest["status"] = "failed_source_trace_comparison"
                    write_json(output / "sim_manifest.json", manifest)
                    raise AssertionError("source/re-export trace byte mismatch: " + name)
        print(json.dumps(dict(output=str(output), **verify_manifest(output, manifest)), indent=2))
        return
    cache = args.cache or args.data_root / "cache" / "validation.npz"
    indices = [int(i) for i in args.indices.split(",")]
    with np.load(cache, allow_pickle=False) as data:
        if not indices or min(indices) < 0 or max(indices) >= len(data["boundary"]):
            raise ValueError("sample indices outside source cache")
        samples = data["boundary"][indices]
        labels = data["labels"][indices].tolist()
    source = {"cache": str(cache.resolve()), "cache_sha256": sha256(cache),
              "indices": indices, "labels": labels, "selection": "fixed indices; no accuracy filtering"}
    source_manifest = cache.with_name(cache.stem + "_sources.json")
    if source_manifest.exists():
        sources = json.loads(source_manifest.read_text())["records"]
        source["records"] = [sources[i] for i in indices]
    manifest = export_sim_golden(output, samples, IntegerEncoder(params, arrays), weights, indices, source)
    print(json.dumps(dict(output=str(output), **verify_manifest(output, manifest)), indent=2))


if __name__ == "__main__":
    main()
