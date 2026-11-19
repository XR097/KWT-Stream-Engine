"""Numerical hardware requirements, deliberately independent of cell area."""
import math

import numpy as np

from .export import profile_storage_spec


def _ubits(maximum):
    return max(1, int(maximum).bit_length())


def _signed_bits(value):
    value = np.asarray(value)
    low, high = (int(value.min()), int(value.max())) if value.size else (0, 0)
    return max(1, max(high, 0).bit_length() + 1,
               (max(-low, 0) - 1).bit_length() + 1 if low < 0 else 1)


def _macro_words(required_words):
    """Minimum allocated capacity, then minimum count, for 16-bit examples."""
    required_words = int(required_words)
    allocated = ((required_words + 127) // 128) * 128
    remaining = allocated
    counts = {}
    for capacity in (4096, 1024, 128):
        count, remaining = divmod(remaining, capacity)
        if count:
            counts["16x%d" % capacity] = count
    return {"required_words": required_words, "allocated_words": allocated,
            "allocated_bytes": allocated * 2, "unused_words": allocated - required_words,
            "macros": counts, "macro_count": sum(counts.values()),
            "port_configuration": "unspecified; capacity example only"}


def _buffer(count, bits):
    packed_words = (count * bits + 15) // 16
    aligned_words = count * ((bits + 15) // 16)
    return {"elements": count, "logical_bits_per_element": bits,
            "tightly_packed_bytes": (count * bits + 7) // 8,
            "word16_aligned_bytes": aligned_words * 2,
            "packed_macro_example": _macro_words(packed_words),
            "word16_macro_example": _macro_words(aligned_words)}


def describe_profile(params, arrays, observed=None):
    """Return storage, datapath widths and operation counts for batch=1.

    Width/operation lists describe functionality. A count of operations is not
    a count of instantiated arithmetic units. SRAM mappings omit port, timing,
    banking, decoder and technology area, so cannot establish minimum area.
    """
    n, d, blocks = 99, 64, params["blocks"]
    diagnostic = set(params.get("diagnostic_arrays", []))
    records, categories = {}, {}
    for key, value in arrays.items():
        value = np.asarray(value)
        spec = profile_storage_spec(params, key, value)
        category = ("weights" if key.endswith(".weight") else
                    "bias" if key.endswith(".bias") else
                    "scales" if key.endswith(".weight_exponents") else
                    "normalization" if key.endswith((".gamma", ".beta")) else "lut")
        is_diagnostic = key in diagnostic
        records[key] = dict(spec, category=category, elements=int(value.size),
                            shape=list(value.shape), deployment=not is_diagnostic,
                            observed_signed_bits=_signed_bits(value))
        if not is_diagnostic:
            categories[category] = categories.get(category, 0) + int(spec["binary_bytes"])
    deployment_bytes = sum(categories.values())
    weight_bytes = categories.get("weights", 0)
    macs = []
    for key, linear in sorted(params["linears"].items()):
        wb = int(params.get("weight_bits_by_linear", {}).get(key, params.get("weight_bits", 8)))
        k, o = int(linear["in_features"]), int(linear["out_features"])
        macs.append({"operator": key, "kind": "linear", "left_bits": params["activation_bits"],
                     "left_signed": True, "right_bits": wb, "right_signed": True,
                     "accumulator_bits": params.get("accumulator_bits", 64),
                     "reduction_length": k, "output_elements": n * o,
                     "multiply_accumulate_operations": n * k * o,
                     "bias_additions": n * o})
    softmax = {}
    for b in blocks:
        cfg = params.get("softmax_configs", {}).get(b, {})
        eq, pq = int(cfg.get("exp_frac", 24)), int(cfg.get("prob_frac", 15))
        pb = pq + 1
        table_entries = 257 if cfg.get("table", "reference") == "compact" else 4097
        softmax[b] = {"exp_fraction_bits": eq, "probability_fraction_bits": pq,
                      "probability_bits": pb, "exp_unsigned_bits": eq + 1,
                      "denominator_unsigned_bits": _ubits(n * (1 << eq)),
                      "division_numerator_unsigned_bits": eq + pq + 1,
                      "exp_table_entries": table_entries,
                      "exp_table_logical_bytes": (table_entries * (eq + 1) + 7) // 8,
                      "full_matrix": _buffer(n * n, pb), "one_row": _buffer(n, pb),
                      "exp_lookups": n * n, "normalization_divisions": n * n,
                      "sum_additions": n * (n - 1)}
        macs.extend([
            {"operator": b + ".score", "kind": "qk", "left_bits": 8, "left_signed": True,
             "right_bits": 8, "right_signed": True,
             "accumulator_bits": params.get("accumulator_bits", 64),
             "reduction_length": d, "output_elements": n * n,
             "multiply_accumulate_operations": n * n * d, "bias_additions": 0},
            {"operator": b + ".context", "kind": "probability_v", "left_bits": pb, "left_signed": False,
             "right_bits": 8, "right_signed": True,
             "accumulator_bits": params.get("accumulator_bits", 64),
             "reduction_length": n, "output_elements": n * d,
             "multiply_accumulate_operations": n * n * d, "bias_additions": 0},
        ])
    norms = {}
    for key, norm in sorted(params["norms"].items()):
        cfg = params.get("layernorm_configs", {}).get(key, {})
        nf, gf = int(cfg.get("norm_frac", 20)), int(cfg.get("gamma_frac", 20))
        gamma = np.asarray(arrays[key + ".gamma"])
        gb = _signed_bits(gamma)
        rsqrt = cfg.get("method", "reference") == "rsqrt"
        # Population-normalized components are bounded by sqrt(channels-1).
        norm_max = int(math.ceil(math.sqrt(int(norm["size"]) - 1) * (1 << nf)))
        nb = _ubits(norm_max) + 1
        norms[key] = {"method": cfg.get("method", "reference"),
                      "normalization_fraction_bits": nf, "gamma_fraction_bits": gf,
                      "gamma_observed_signed_bits": gb,
                      "normalized_domain_bound_signed_bits": nb,
                      "affine_product_exact_normalization_signed_bits": nb + gb,
                      "affine_product_fraction_bits": nf + gf,
                      "epsilon_q24": int(norm.get("epsilon_q24", 17)),
                      "variance_fraction_bits": 24, "rows_per_task": n,
                      "affine_multiplications": n * int(norm["size"]),
                      "variable_denominator_divisions": 0 if rsqrt else n * int(norm["size"]),
                      "integer_square_roots": 0 if rsqrt else n,
                      "square_sum_multiplications": n * int(norm["size"]),
                      "rsqrt_normalization_multiplications": n * int(norm["size"]) if rsqrt else 0,
                      "newton_multiplications": n * 3 * int(cfg.get("iterations", 0)) if rsqrt else 0,
                      "rsqrt_lut_entries": int(cfg.get("lut_entries", 0)) if rsqrt else 0,
                      "rsqrt_fraction_bits": int(cfg.get("rsqrt_frac", 0)) if rsqrt else 0,
                      "newton_iterations": int(cfg.get("iterations", 0)) if rsqrt else 0,
                      "fixed_divisor_note": "Variance divides by size^3; rsqrt normalization divides by size. For size=64 these are power-of-two round-even shifts."}
        frac = int(cfg.get("rsqrt_frac", 20))
        norms[key]["rsqrt_intermediate_domain_bounds"] = ({
            "mantissa_q30_signed_bits": 33,
            "reciprocal_square_product_signed_bits": 2 * frac + 2,
            "mantissa_times_reciprocal_square_signed_bits": frac + 33,
            "newton_correction_product_signed_bits": 2 * frac + 4,
            "note": "Conservative operand-domain bounds; Newton intermediates do not shrink with norm_frac or gamma_frac. Observed widths are reported separately.",
        } if rsqrt and int(cfg.get("iterations", 0)) else {})
    gelus = {}
    for b in blocks:
        key = b + ".gelu"
        cfg = params.get("gelu_configs", {}).get(key, {})
        method = cfg.get("method", "reference")
        table = arrays.get(cfg.get("table_key", "gelu.y_q20"))
        gelus[key] = {"method": method, "elements_per_task": n * 256,
                      "table_key": cfg.get("table_key", "gelu.y_q20"),
                      "table_entries": int(np.asarray(table).size) if table is not None else None,
                      "online_interpolation_multiplications": n * 256 if method == "reference" else 0,
                      "tail_comparisons_per_element": 2 if method == "middle" else 0,
                      "middle_minimum_input": cfg.get("minimum_input"),
                      "middle_maximum_input": cfg.get("maximum_input")}
    types = sorted(set((m["left_bits"], m["left_signed"], m["right_bits"], m["right_signed"])
                       for m in macs))
    capacities = {str(p): {"full_matrix": _buffer(n * n, p), "one_row": _buffer(n, p)} for p in (16, 12, 8)}
    max_prob = max((v["probability_bits"] for v in softmax.values()), default=16)
    activation_buffers = {
        "embedding": _buffer(n * d, 8), "q_k_v_each": _buffer(n * d, 8),
        "score": _buffer(n * n, 8), "probability": _buffer(n * n, max_prob),
        "ffn_hidden": _buffer(n * 256, 8),
    }
    residuals = {}
    for b in blocks:
        for name, x, y in (("res1", "input", "proj"), ("res2", "ln1", "fc2")):
            out = b + "." + name
            residuals[out] = {
                "adder_bits": params.get("residual_accumulator_bits", 64),
                "additions_per_task": n * d,
                "left_alignment_right_shift": params["exponents"][out] - params["exponents"][b + "." + x],
                "right_alignment_right_shift": params["exponents"][out] - params["exponents"][b + "." + y],
                "output_bits": params["activation_bits"],
                "rounding": "nearest_even", "saturation_after_addition": True,
            }
    observed = observed or {}
    observed_mac = observed.get("mac_required_bits", {})
    observed_wide = observed.get("wide_required_bits", observed.get("wide_temporary_required_bits", {}))
    observed_summary = {
        "maximum_mac_signed_bits": max(observed_mac.values(), default=None),
        "maximum_wide_temporary_signed_bits": max(observed_wide.values(), default=None),
        "wide_operators": dict(sorted(observed_wide.items())),
        "newton_and_rsqrt_operators": {k: v for k, v in observed_wide.items() if ".rsqrt." in k},
        "scope": "Observed values cover the supplied evaluation only; they are not proofs for all legal inputs.",
    }
    return {
        "format_version": 1, "profile_format_version": params.get("format_version", 2),
        "batch_size": 1, "sequence_length": n, "embedding_dimension": d, "blocks": len(blocks),
        "deployment_binary_bytes": deployment_bytes, "weight_binary_bytes": weight_bytes,
        "lut_binary_bytes": categories.get("lut", 0),
        "storage": {"deployment_binary_bytes": deployment_bytes, "bytes_by_category": categories,
                    "archive_array_binary_bytes": sum(v["binary_bytes"] for v in records.values()),
                    "diagnostic_binary_bytes": sum(v["binary_bytes"] for v in records.values() if not v["deployment"]),
                    "logical_weight_bytes": sum((v["elements"] * v["logical_bits"] + 7) // 8
                                                for v in records.values() if v["category"] == "weights"),
                    "arrays": records,
                    "deployment_macro_example": _macro_words((deployment_bytes + 1) // 2)},
        "softmax": softmax, "probability_storage_comparison": capacities,
        "activation_buffers": activation_buffers, "mac_operators": macs,
        "multiply_accumulate_operations_per_task": sum(v["multiply_accumulate_operations"] for v in macs),
        "layernorm": norms, "gelu": gelus, "residual": residuals,
        "resource_sharing": {
            "one_shared_mac_max_left_bits": max(v["left_bits"] for v in macs),
            "one_shared_mac_max_right_bits": max(v["right_bits"] for v in macs),
            "shared_left_supports_signed_and_unsigned": len(set(v["left_signed"] for v in macs)) > 1,
            "operand_mode_count": len(types),
            "dedicated_operand_types": [{"left_bits": a, "left_signed": sa, "right_bits": b, "right_signed": sb}
                                         for a, sa, b, sb in types],
            "arithmetic_instance_count": None, "cycles_per_task": None,
            "note": "Operation counts are dynamic work, not hardware unit counts. Sharing requires a cycle schedule."},
        "observed": observed, "observed_width_summary": observed_summary, "estimated_area": None,
        "limitations": [
            "No RTL synthesis or process library; this report does not rank actual area.",
            "SRAM examples minimize word capacity then macro count; ports, banking and timing remain unspecified.",
            "Physical binary bytes include byte rounding, not gate count or SRAM peripheral area.",
            "LayerNorm domain bounds assume exact population normalization; observed fixed-point widths remain separately recorded.",
            "CPU elapsed time is not converted to RTL clock cycles.",
        ],
    }
