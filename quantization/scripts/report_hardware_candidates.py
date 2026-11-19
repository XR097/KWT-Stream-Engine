"""Audit completed packages and summarize independent hardware requirement axes.

Standard-library only. This script neither imports the numerical encoder nor
estimates cell area. A partial, stale or damaged run cannot produce candidates.
"""
import os
import argparse
from datetime import datetime, timezone
import hashlib
import json
import math
from pathlib import Path


EXPERIMENT = Path("experiments") / "w4w8_nonlinear_v1"
AXES = {
    "incorrect_count": "4890-sample classification errors",
    "weight_binary_bytes": "actual deployed weight bytes",
    "deployment_binary_bytes": "all deployed array bytes, excluding diagnostics",
    "lut_logical_bits": "sum of unique deployed LUT elements times declared bits",
    "lut_binary_bytes": "actual unique deployed LUT bytes",
    "gelu_table_logical_bits": "unique deployed GELU LUT bits",
    "gelu_online_interpolation_multiplications": "dynamic multiplications per task",
    "gelu_tail_comparisons_per_element": "maximum comparisons per GELU element",
    "softmax_numerator_unsigned_bits": "maximum division numerator width",
    "softmax_denominator_unsigned_bits": "maximum denominator width",
    "softmax_probability_bits": "maximum encoded probability width",
    "probability_full_packed_allocated_bytes": "maximum per-block full-matrix capacity example",
    "probability_row_packed_allocated_bytes": "maximum per-block one-row capacity example",
    "layernorm_normalization_fraction_bits": "maximum declared normalization fraction bits",
    "layernorm_gamma_fraction_bits": "maximum declared gamma fraction bits",
    "layernorm_variable_divisions": "dynamic variable-denominator divisions per task",
    "layernorm_square_roots": "dynamic integer square roots per task",
    "layernorm_newton_multiplications": "dynamic Newton multiplications per task",
    "layernorm_rsqrt_multiplications": "dynamic rsqrt normalization multiplications per task",
    "shared_mac_left_bits": "maximum width for one shared MAC operand port",
    "shared_mac_right_bits": "maximum width for the other shared MAC operand port",
    "operand_mode_count": "supported operand modes, not instantiated arithmetic units",
}
LIMITATIONS = [
    "No synthesized area or RTL cycle schedule is available; independent requirements are not an area score.",
    "Dynamic operation counts do not specify instantiated arithmetic units or sharing latency.",
    "SRAM shapes are capacity examples; single/dual ports, banking and official macro area are not selected.",
    "Middle GELU trades smaller tables for comparisons and bypass logic; neither structure is assumed smaller in silicon.",
    "Observed widths cover the evaluated samples only. LayerNorm exact-normalization bounds are not proofs for an approximate rsqrt implementation.",
    "A shared W8 multiplier still supports W8 when some weights use W4; weight-byte reduction does not prove multiplier-area reduction.",
    "Golden verification flags and matching manifests are checked here; no inference or full golden tensor re-audit is performed.",
]


def require(condition, message):
    if not condition:
        raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with Path(path).open("rb") as source:
        for chunk in iter(lambda: source.read(1024 * 1024), b""):
            digest.update(chunk)
    return digest.hexdigest()


def load(path, sources):
    path = Path(path).resolve()
    content = path.read_bytes()
    sources[str(path)] = {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}
    return json.loads(content.decode("utf-8"))


def verify_file(path, expected, sources):
    path = Path(path).resolve()
    require(isinstance(expected, str) and len(expected) == 64, "missing source SHA256: " + str(path))
    digest = sha256(path)
    require(digest == expected, "source SHA256 mismatch: " + str(path))
    sources[str(path)] = {"sha256": digest, "bytes": path.stat().st_size}


def config_id(config):
    text = json.dumps(config, sort_keys=True, separators=(",", ":"))
    return hashlib.sha256(text.encode()).hexdigest()[:20]


def check_identities(value, identity):
    if isinstance(value, dict):
        if "identity" in value:
            require(value["identity"] == identity, "nested identity mismatch")
        for key, child in value.items():
            if key != "identity":
                check_identities(child, identity)
    elif isinstance(value, list):
        for child in value:
            check_identities(child, identity)


def verify_sources(root, data_root, repo_root, identity, sources):
    digest = hashlib.sha256()
    paths = sorted((repo_root / "quantization").glob("*.py"))
    require(bool(paths), "numerical source files are missing")
    for path in paths:
        content = path.read_bytes()
        digest.update(path.name.encode())
        digest.update(content)
        sources[str(path.resolve())] = {"sha256": hashlib.sha256(content).hexdigest(), "bytes": len(content)}
    require(digest.hexdigest() == identity.get("code"), "numerical source fingerprint mismatch")
    for split in ("training", "validation", "testing"):
        verify_file(data_root / "cache" / (split + ".npz"), identity.get("datasets", {}).get(split), sources)
    for key, path in (("weights", root / "cache" / "weights.npz"),
                      ("validation_full", root / "cache" / "validation_full.npz"),
                      ("calibration", data_root / "cache" / "calibration.json")):
        verify_file(path, identity.get(key), sources)
    digest = hashlib.sha256()
    paths = sorted((data_root / "profiles" / "W8A8_integer").iterdir())
    require(bool(paths), "base profile is missing")
    for path in paths:
        if path.is_file():
            value = sha256(path)
            digest.update(path.name.encode())
            digest.update(value.encode())
            sources[str(path.resolve())] = {"sha256": value, "bytes": path.stat().st_size}
    require(digest.hexdigest() == identity.get("base_profile"), "base-profile fingerprint mismatch")


def validate_results(acceptance, identity):
    require(acceptance.get("identity") == identity, "acceptance identity mismatch")
    check_identities(acceptance, identity)
    require(acceptance.get("status") == "complete" and acceptance.get("count_per_candidate") == 4890,
            "formal acceptance must complete all 4890 samples")
    results, passed, baseline_correct = {}, [], None
    for result in acceptance.get("results", []):
        ident = result.get("config_id")
        require(ident == config_id(result["config"]) and ident not in results, "duplicate or invalid configuration hash")
        require(result.get("identity") == identity, "result identity mismatch")
        require(result.get("status") == "complete" and result.get("split") == "testing"
                and result.get("count") == 4890, "result is not a complete 4890-sample test")
        require(result.get("overflow_count") == 0 and result.get("finite_outputs") is True,
                "result failed numeric checks")
        require(result.get("partial_encoder_timing") is False, "partial encoder is not a formal result")
        widths = result.get("mac_required_bits", {})
        require(bool(widths) and all(isinstance(v, int) and 0 < v <= 32 for v in widths.values()),
                "MAC width is missing or exceeds int32")
        correct = result.get("correct")
        require(type(correct) is int and 0 <= correct <= 4890, "invalid correct count")
        top1, float_top1, drop = (float(result[k]) for k in ("top1", "float_top1", "drop_pp"))
        require(all(math.isfinite(v) for v in (top1, float_top1, drop)) and 0 <= float_top1 <= 1,
                "nonfinite or invalid accuracy")
        require(abs(top1 - correct / 4890) < 1e-12, "correct count/top1 mismatch")
        float_correct = round(float_top1 * 4890)
        require(abs(float_top1 - float_correct / 4890) < 1e-12, "FP32 accuracy has no integer correct count")
        require(baseline_correct in (None, float_correct), "FP32 baseline differs between results")
        baseline_correct = float_correct
        require(abs(drop - (float_top1 - top1) * 100) < 1e-10, "saved Top-1 loss mismatch")
        confusion = result.get("confusion_matrix", [])
        require(len(confusion) == 12 and all(len(row) == 12 for row in confusion)
                and all(type(v) is int and v >= 0 for row in confusion for v in row), "invalid confusion matrix")
        require(sum(map(sum, confusion)) == 4890 and sum(confusion[i][i] for i in range(12)) == correct,
                "confusion matrix/count mismatch")
        expected_pass = top1 >= float_top1 - .02
        require(result.get("pass") is expected_pass, "accuracy pass flag is inconsistent")
        if expected_pass:
            passed.append(ident)
        results[ident] = result
    require(bool(results), "formal acceptance has no results")
    require(sorted(acceptance.get("passed", [])) == sorted(passed), "passed list is inconsistent")
    return results, set(passed)


def child_file(folder, name):
    path = (folder / name).resolve()
    require(folder.resolve() in path.parents, "package file escapes its folder: " + str(path))
    return path


def package_summary(package, result, identity, sources):
    folder = Path(package["profile"]).resolve()
    profile = load(folder / "profile.json", sources)
    hw = load(folder / "hardware_requirements.json", sources)
    structure = package["gelu_structure"]
    require(profile.get("nonlinear") == dict(result["config"], gelu=structure), "package configuration mismatch")
    require(hw.get("observed") == result, "hardware report observed result is stale")
    check_identities(hw, identity)
    require(profile.get("activation_bits") == 8 and profile.get("accumulator_bits") == 32
            and profile.get("residual_accumulator_bits") == 32, "profile must use A8 and int32 MAC/residual")
    records = hw["storage"]["arrays"]
    require(set(records) == set(profile["arrays"]), "hardware/profile array sets differ")
    totals = {"deployment_binary_bytes": 0, "weight_binary_bytes": 0, "lut_binary_bytes": 0,
              "lut_logical_bits": 0, "gelu_table_logical_bits": 0, "gelu_table_binary_bytes": 0,
              "w4_binary_bytes": 0, "w8_binary_bytes": 0}
    lut_arrays = {}
    for key, spec in profile["arrays"].items():
        record = records[key]
        path = child_file(folder, spec["binary"])
        verify_file(path, spec.get("binary_sha256"), sources)
        require(path.stat().st_size == spec["binary_bytes"] == record["binary_bytes"], "binary byte count mismatch")
        require(spec.get("byte_order") == "little", "package is not little endian")
        for field in ("logical_bits", "physical_encoding", "shape"):
            require(record[field] == spec[field], "hardware array metadata mismatch: " + key)
        elements = math.prod(spec["shape"])
        require(elements == record["elements"], "array element count mismatch")
        category = ("weights" if key.endswith(".weight") else "bias" if key.endswith(".bias") else
                    "scales" if key.endswith(".weight_exponents") else
                    "normalization" if key.endswith((".gamma", ".beta")) else "lut")
        require(record.get("category") == category, "hardware array category mismatch: " + key)
        deployed = not spec.get("diagnostic", False)
        require(record.get("deployment") is deployed, "diagnostic/deployment mismatch")
        if spec.get("npy_sha256"):
            verify_file(child_file(folder, spec["file"]), spec["npy_sha256"], sources)
        if not deployed:
            continue
        size = spec["binary_bytes"]
        totals["deployment_binary_bytes"] += size
        if key.endswith(".weight"):
            bits = profile.get("weight_bits_by_linear", {}).get(key[:-7], profile.get("weight_bits", 8))
            require(bits in (4, 8) and spec["logical_bits"] == bits, "invalid weight precision")
            expected_bytes = (elements * bits + 7) // 8
            require(size == expected_bytes, "weights are not physically packed at their declared precision")
            require((bits != 4 or spec["physical_encoding"] == "signed_twos_complement_nibbles_low_first"),
                    "W4 package does not declare nibble packing")
            totals["weight_binary_bytes"] += size
            totals["w%d_binary_bytes" % bits] += size
        if record["category"] == "lut":
            bits = elements * spec["logical_bits"]
            totals["lut_binary_bytes"] += size
            totals["lut_logical_bits"] += bits
            lut_arrays[key] = {"entries": elements, "logical_bits_per_entry": spec["logical_bits"],
                               "logical_bits": bits, "binary_bytes": size}
            if key.startswith("gelu."):
                totals["gelu_table_logical_bits"] += bits
                totals["gelu_table_binary_bytes"] += size
    for key in ("deployment_binary_bytes", "weight_binary_bytes", "lut_binary_bytes"):
        require(totals[key] == hw[key], "hardware/file totals mismatch: " + key)
    golden_folder = Path(package["golden"]).resolve()
    golden = load(golden_folder / "golden_manifest.json", sources)
    require(golden == package.get("manifest"), "acceptance embeds a stale golden manifest")
    require(golden.get("status") == "verified" and golden.get("count") == 24
            and golden.get("verified_sample_count") == 24
            and all(golden.get(k) is True for k in ("repeat_bit_exact", "reload_bit_exact", "numpy_binary_bit_exact")),
            "24-sample golden is not verified")
    require(golden.get("nonlinear") == profile["nonlinear"], "golden/profile configuration mismatch")
    copied_profile = load(golden_folder / "profile" / "profile.json", sources)
    require(copied_profile == profile, "golden embeds a different profile")
    vectors = load(golden_folder / "operator_vectors" / "operator_manifest.json", sources)
    require(vectors == package.get("operator_vectors") and vectors.get("status") == "verified",
            "operator-vector manifest mismatch or unverified")
    soft = hw["softmax"]
    norms = hw["layernorm"]
    gelus = hw["gelu"]
    require(bool(soft) and bool(norms) and bool(gelus), "incomplete nonlinear requirements")
    softmax = {"per_block": soft,
               "maximum_numerator_unsigned_bits": max(s["division_numerator_unsigned_bits"] for s in soft.values()),
               "maximum_denominator_unsigned_bits": max(s["denominator_unsigned_bits"] for s in soft.values()),
               "maximum_probability_bits": max(s["probability_bits"] for s in soft.values()),
               "full_matrix_and_one_row_are_alternative_schedules": True}
    norm_summary = {"per_operator": norms,
                    "maximum_normalization_fraction_bits": max(n["normalization_fraction_bits"] for n in norms.values()),
                    "maximum_gamma_fraction_bits": max(n["gamma_fraction_bits"] for n in norms.values()),
                    "maximum_gamma_constant_signed_bits": max(n["gamma_observed_signed_bits"] for n in norms.values()),
                    "maximum_normalized_exact_domain_signed_bits": max(n["normalized_domain_bound_signed_bits"] for n in norms.values()),
                    "maximum_affine_exact_domain_signed_bits": max(n["affine_product_exact_normalization_signed_bits"] for n in norms.values()),
                    "domain_bound_scope": "Exact population normalization only; not a proof for approximate rsqrt or a hardware container declaration."}
    for field in ("variable_denominator_divisions", "integer_square_roots", "newton_multiplications",
                  "rsqrt_normalization_multiplications", "affine_multiplications"):
        norm_summary[field + "_per_task"] = sum(n[field] for n in norms.values())
    gelu_rows = {}
    for key, value in gelus.items():
        cfg = profile["gelu_configs"][key]
        require(value["method"] == cfg["method"] == structure, "GELU structure mismatch")
        gelu_rows[key] = dict(value, table_storage=lut_arrays.get(value["table_key"]),
                              negative_tail_bypass="zero" if structure == "middle" else None,
                              positive_tail_bypass=({"right_shift": cfg["output_exponent"] - cfg["input_exponent"],
                                                     "rounding": "nearest_even", "saturate_to_signed_bits": 8}
                                                    if structure == "middle" else None))
    axes = {"incorrect_count": 4890 - result["correct"],
            **{k: totals[k] for k in ("weight_binary_bytes", "deployment_binary_bytes", "lut_logical_bits", "lut_binary_bytes", "gelu_table_logical_bits")},
            "gelu_online_interpolation_multiplications": sum(g["online_interpolation_multiplications"] for g in gelus.values()),
            "gelu_tail_comparisons_per_element": max(g["tail_comparisons_per_element"] for g in gelus.values()),
            "softmax_numerator_unsigned_bits": softmax["maximum_numerator_unsigned_bits"],
            "softmax_denominator_unsigned_bits": softmax["maximum_denominator_unsigned_bits"],
            "softmax_probability_bits": softmax["maximum_probability_bits"],
            "probability_full_packed_allocated_bytes": max(s["full_matrix"]["packed_macro_example"]["allocated_bytes"] for s in soft.values()),
            "probability_row_packed_allocated_bytes": max(s["one_row"]["packed_macro_example"]["allocated_bytes"] for s in soft.values()),
            "layernorm_normalization_fraction_bits": norm_summary["maximum_normalization_fraction_bits"],
            "layernorm_gamma_fraction_bits": norm_summary["maximum_gamma_fraction_bits"],
            "layernorm_variable_divisions": norm_summary["variable_denominator_divisions_per_task"],
            "layernorm_square_roots": norm_summary["integer_square_roots_per_task"],
            "layernorm_newton_multiplications": norm_summary["newton_multiplications_per_task"],
            "layernorm_rsqrt_multiplications": norm_summary["rsqrt_normalization_multiplications_per_task"],
            "shared_mac_left_bits": hw["resource_sharing"]["one_shared_mac_max_left_bits"],
            "shared_mac_right_bits": hw["resource_sharing"]["one_shared_mac_max_right_bits"],
            "operand_mode_count": hw["resource_sharing"]["operand_mode_count"]}
    require(set(axes) == set(AXES), "requirement axes are incomplete")
    require(all(type(v) is int and v >= 0 for v in axes.values()), "invalid independent requirement axis")
    return {"candidate_id": result["config_id"] + "_" + structure, "config_id": result["config_id"],
            "gelu_structure": structure, "config": profile["nonlinear"], "profile": str(folder),
            "accuracy": {k: result[k] for k in ("correct", "count", "top1", "float_top1", "drop_pp")},
            "checks": {"identity_and_sources_verified": True, "binary_sha256_verified": True,
                       "accuracy_pass": True, "golden_manifests_verified": True},
            "storage": totals, "lut_arrays": lut_arrays, "gelu": gelu_rows,
            "softmax": softmax, "layernorm": norm_summary, "residual": hw["residual"],
            "mac_operators": hw["mac_operators"], "resource_sharing": hw["resource_sharing"],
            "observed_widths": dict(hw["observed_width_summary"],
                                    mac_operators=result.get("mac_required_bits", {}),
                                    residual_ranges=result.get("residual_ranges", {})),
            "requirement_axes": axes, "synthesized_area_mm2": None, "rtl_cycles_per_task": None}


def pareto(candidates):
    """Weakly equal candidates both survive; no weighted scalar is invented."""
    selected = []
    for item in candidates:
        a = item["requirement_axes"]
        dominated = any(all(other["requirement_axes"][k] <= a[k] for k in AXES)
                        and any(other["requirement_axes"][k] < a[k] for k in AXES)
                        for other in candidates if other is not item)
        item["requirement_pareto"] = not dominated
        if not dominated:
            selected.append(item)
    return selected


def representatives(frontier, candidates):
    if not frontier:
        return []
    criteria = [
        ("low_weight_capacity", ("weight_binary_bytes", "deployment_binary_bytes")),
        ("higher_accuracy", ("incorrect_count", "deployment_binary_bytes")),
        ("narrower_declared_datapath", ("softmax_numerator_unsigned_bits", "softmax_denominator_unsigned_bits",
                                       "softmax_probability_bits", "layernorm_normalization_fraction_bits",
                                       "layernorm_gamma_fraction_bits", "deployment_binary_bytes")),
    ]
    output = []
    for name, fields in criteria:
        chosen = min(frontier, key=lambda c: tuple(c["requirement_axes"][k] for k in fields) + (c["candidate_id"],))
        # Both equivalent GELU structures remain a synthesis experiment even
        # when only one is selected by the representative's tie-break rule.
        pair = sorted(c["candidate_id"] for c in candidates if c["config_id"] == chosen["config_id"])
        output.append({"purpose": name, "lexicographic_requirement_order": list(fields),
                       "selected": chosen["candidate_id"], "synthesize_paired_gelu_structures": pair})
    return output


def markdown(report):
    lines = ["# 面积导向候选与综合优先级", "", "状态：**%s**。" % report["status"], "",
             "仅比较独立硬件需求轴，不构造面积分数；候选不是实际面积排名。", ""]
    if report.get("errors"):
        lines += ["校验失败，未发布候选：", ""] + ["- " + e for e in report["errors"]] + [""]
    if report["status"] == "pending":
        lines += ["正式完整测试及导出尚未完成，候选为空。", ""]
    rows = report["candidates"]
    if rows:
        lines += ["| 配置/GELU | 正确数/4890 | Top-1 % | 损失 pp | 权重/部署 B | LUT 逻辑 bit/实际 B | GELU 表 bit/比较数 | Pareto |",
                  "|---|---:|---:|---:|---:|---:|---:|---|"]
        for c in rows:
            a, s, v = c["accuracy"], c["storage"], c["requirement_axes"]
            lines.append("| %s | %s | %.6f | %.6f | %s/%s | %s/%s | %s/%s | %s |" %
                         (c["candidate_id"], a["correct"], 100 * a["top1"], a["drop_pp"], s["weight_binary_bytes"],
                          s["deployment_binary_bytes"], s["lut_logical_bits"], s["lut_binary_bytes"],
                          s["gelu_table_logical_bits"], v["gelu_tail_comparisons_per_element"], c["requirement_pareto"]))
        lines += ["", "## 优先综合代表", ""]
        for r in report["representatives"]:
            lines.append("- %s：`%s`；同时综合其等价 GELU 对照：%s。按 %s 依次择优，未使用加权面积分数。" %
                         (r["purpose"], r["selected"], ", ".join("`" + v + "`" for v in r["synthesize_paired_gelu_structures"]),
                          ", ".join(r["lexicographic_requirement_order"])))
        for c in rows:
            s, n, v = c["softmax"], c["layernorm"], c["observed_widths"]
            lines += ["", "## " + c["candidate_id"], "",
                      "Softmax 最大分子/分母/概率位宽：%s/%s/%s；各块整矩阵与逐行容量、16 位对齐和单/双端口未定的 SRAM 形状完整记录于 JSON。两种缓冲是不同调度备选，不能相加冒充工作存储。" %
                      (s["maximum_numerator_unsigned_bits"], s["maximum_denominator_unsigned_bits"], s["maximum_probability_bits"]), "",
                      "LayerNorm 最大归一化 Q/gamma Q：%s/%s；gamma 常量位宽 %s，精确归一化域/仿射域界 %s/%s 位。域界不证明近似 rsqrt 实现无溢出。每任务变量除法/平方根/Newton 乘法/rsqrt 归一化乘法：%s/%s/%s/%s。" %
                      (n["maximum_normalization_fraction_bits"], n["maximum_gamma_fraction_bits"], n["maximum_gamma_constant_signed_bits"],
                       n["maximum_normalized_exact_domain_signed_bits"], n["maximum_affine_exact_domain_signed_bits"],
                       n["variable_denominator_divisions_per_task"], n["integer_square_roots_per_task"],
                       n["newton_multiplications_per_task"], n["rsqrt_normalization_multiplications_per_task"]), "",
                      "MAC/宽临时量最大**实测**位宽：%s/%s，仅覆盖本次测试。共享和专用操作数模式：`%s`；实例数和任务周期尚未确定。" %
                      (v.get("maximum_mac_signed_bits"), v.get("maximum_wide_temporary_signed_bits"),
                       json.dumps(c["resource_sharing"]["dedicated_operand_types"], ensure_ascii=False)), "",
                      "GELU %s：唯一表共 %s 字节；每元素尾部比较最多 %s 次。中段表还需负尾输出零、正尾尺度转换/舍入/饱和旁路；全表与中段表必须同约束实测综合净面积。" %
                      (c["gelu_structure"], c["storage"]["gelu_table_binary_bytes"], c["requirement_axes"]["gelu_tail_comparisons_per_element"])]
            lines += ["", "| 概率缓冲形状（按块） | 概率 bit | 逻辑紧密 B | 16位字对齐 B | 紧密容量/宏形状示例 | 字对齐容量/宏形状示例 |",
                      "|---|---:|---:|---:|---|---|"]
            for block, soft in sorted(s["per_block"].items()):
                for schedule in ("full_matrix", "one_row"):
                    buffer = soft[schedule]
                    packed, aligned = buffer["packed_macro_example"], buffer["word16_macro_example"]
                    lines.append("| %s/%s | %s | %s | %s | %s B / `%s` | %s B / `%s` |" %
                                 (block, schedule, buffer["logical_bits_per_element"], buffer["tightly_packed_bytes"],
                                  buffer.get("word16_aligned_bytes", buffer["elements"] * 2), packed["allocated_bytes"],
                                  json.dumps(packed["macros"], sort_keys=True), aligned["allocated_bytes"],
                                  json.dumps(aligned["macros"], sort_keys=True)))
            lines += ["", "所有宏形状均为容量取整示例，尚未决定端口、banking和官方宏面积。", ""]
    lines += ["", "## 边界与最终选择", "",
              "最终真实排序：先满足同一浮点基线 Top-1 下降不超过 2 个百分点、RTL 对照、150 MHz 及 2.25 mm²，再取面积最低；面积相同时取任务周期最低。没有综合数据时不选出实际面积最小方案。", "",
              "面积计入新增加速器、接口逻辑、内部 SRAM；排除复用 E203、512 KB 共享 SRAM、固定总线和外设。SRAM 使用指定 16×128/1024/4096 单/双端口宏，需官方宏面积与工艺库。吞吐、功耗和面积来自同一冻结配置。", "",
              "Pareto 轴均按更小需求择优；其中调用次数及模式数是调度需求，不能解释为硬件实例数。gamma/归一化域界和样本实测位宽单列，未将样本最大值当作全输入域证明。", ""]
    lines += ["- " + note for note in report["limitations"]] + [""]
    return "\n".join(lines)


def generate_report(data_root, experiment_root=None, repo_root=None):
    data_root = Path(data_root).resolve()
    root = Path(experiment_root).resolve() if experiment_root else data_root / EXPERIMENT
    repo_root = Path(repo_root).resolve() if repo_root else Path(__file__).resolve().parents[2]
    reports = root / "reports"
    reports.mkdir(parents=True, exist_ok=True)
    output = {"schema_version": 1, "generated_utc": datetime.now(timezone.utc).isoformat(timespec="seconds"),
              "status": "pending", "identity": None, "candidates": [], "pareto_candidate_ids": [],
              "representatives": [], "axes": {k: {"direction": "minimize", "meaning": v} for k, v in AXES.items()},
              "source_files": {}, "errors": [], "limitations": LIMITATIONS,
              "real_synthesis_selection": {"max_top1_drop_percentage_points": 2,
                                           "required_rtl_match": True, "clock_mhz": 150,
                                           "maximum_area_mm2": 2.25, "primary": "minimum synthesized area",
                                           "tie_break": "minimum measured RTL cycles per task"}}
    sources = output["source_files"]
    try:
        path = reports / "acceptance.json"
        if path.exists():
            acceptance = load(path, sources)
            if acceptance.get("status") == "complete":
                identity = load(reports / "run_identity.json", sources)
                output["identity"] = identity
                results, passed = validate_results(acceptance, identity)
                verify_sources(root, data_root, repo_root, identity, sources)
                packages = acceptance.get("packages", [])
                expected = {(ident, structure) for ident in passed for structure in ("direct", "middle")}
                actual = [(p.get("config_id"), p.get("gelu_structure")) for p in packages]
                require(len(actual) == len(expected) and set(actual) == expected,
                        "package count/set mismatch: require direct and middle for every passing configuration")
                candidates = [package_summary(p, results[p["config_id"]], identity, sources) for p in packages]
                frontier = pareto(candidates)
                output.update(status="verified" if candidates else "complete_no_qualified_candidates",
                              candidates=candidates, pareto_candidate_ids=sorted(c["candidate_id"] for c in frontier),
                              representatives=representatives(frontier, candidates))
            elif acceptance.get("status") not in ("running", "pending"):
                raise ValueError("formal acceptance failed or has an unknown state")
    except (OSError, ValueError, KeyError, TypeError, OverflowError) as error:
        output.update(status="rejected", candidates=[], pareto_candidate_ids=[], representatives=[], errors=[str(error)])
    for name, content in (("hardware_candidates.json", json.dumps(output, indent=2, sort_keys=True, ensure_ascii=False, allow_nan=False)),
                          ("hardware_candidates.md", markdown(output))):
        path = reports / name
        temporary = path.with_suffix(path.suffix + ".tmp")
        temporary.write_text(content, encoding="utf-8")
        temporary.replace(path)
    return output


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    parser.add_argument("--experiment-root")
    parser.add_argument("--repo-root")
    args = parser.parse_args()
    report = generate_report(args.data_root, args.experiment_root, args.repo_root)
    print(json.dumps({"status": report["status"], "candidates": len(report["candidates"]),
                      "representatives": report["representatives"], "errors": report["errors"]}, indent=2))
    return 2 if report["status"] == "rejected" else 0


if __name__ == "__main__":
    raise SystemExit(main())
