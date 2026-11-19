import os
"""Summarize matching experiment artifacts without importing the model runtime."""
import argparse
import csv
from datetime import datetime, timezone
import hashlib
import io
import json
from pathlib import Path


RESULT_FIELDS = (
    "id", "config_id", "config", "split", "status", "count", "correct",
    "top1", "float_top1", "drop_pp", "agreement_float", "seconds",
    "samples_per_second", "nrmse", "max_error", "saturation_count",
    "overflow_count", "weight_bytes", "pass", "error", "diagnostic",
    "partial_encoder_timing",
)
CSV_FIELDS = (
    "result_id", "config_id", "stages", "split", "status", "count", "correct",
    "top1_percent", "float_top1_percent", "drop_percentage_points",
    "agreement_float_percent", "w4_matrix_count", "w4_matrices",
    "logical_weight_bytes", "actual_w4_binary_bytes", "actual_w8_binary_bytes",
    "actual_weight_binary_bytes", "deployment_bytes_by_gelu",
    "gelu", "softmax_json", "softmax_by_block_json", "layernorm_json",
    "layernorm_by_op_json", "mac_max_signed_bits", "wide_max_signed_bits",
    "residual_sum_max_signed_bits", "saturation_count", "overflow_count",
    "encoder_seconds", "samples_per_second", "partial_encoder_timing",
    "diagnostic", "nrmse", "max_error", "pass", "error", "config_json",
    "source_files",
)


def canonical(value):
    return json.dumps(value, sort_keys=True, separators=(",", ":"), ensure_ascii=False)


def load_json(path):
    return json.loads(Path(path).read_text(encoding="utf-8"))


def identity_state(value, identity):
    """Require at least one identity and reject any nested stale identity."""
    found = []

    def visit(node):
        if isinstance(node, dict):
            if "identity" in node:
                found.append(node["identity"] == identity)
            for key, child in node.items():
                if key != "identity":
                    visit(child)
        elif isinstance(node, list):
            for child in node:
                visit(child)

    visit(value)
    if not found:
        return "unverified: missing identity"
    return "matching" if all(found) else "stale: identity mismatch"


def results_in(value):
    if isinstance(value, dict):
        if all(key in value for key in ("config_id", "config", "split", "status")):
            yield value
        else:
            for key, child in value.items():
                if key != "identity":
                    yield from results_in(child)
    elif isinstance(value, list):
        for child in value:
            yield from results_in(child)


def slim_result(result):
    output = {key: result[key] for key in RESULT_FIELDS if key in result}
    output["mac_max_bits"] = max(result.get("mac_required_bits", {}).values(), default=None)
    output["wide_max_bits"] = max(result.get("wide_required_bits", result.get("wide_temporary_required_bits", {})).values(), default=None)
    output["residual_max_bits"] = max((item.get("sum", {}).get("required_signed_bits", 0)
                                       for item in result.get("residual_ranges", {}).values()), default=None)
    return output


def w4_names(config):
    return sorted(key for key, value in config.get("weight_bits_by_linear", {}).items() if value == 4)


def percent(value):
    return "" if value is None else float(value) * 100


def number(value, places=6):
    if value is None:
        return "-"
    if isinstance(value, bool):
        return str(value)
    if isinstance(value, int):
        return str(value)
    return ("%%.%df" % places) % value


def signed_interval_bits(low, high):
    return max(1, max(int(high), 0).bit_length() + 1,
               (max(-int(low), 0) - 1).bit_length() + 1 if low < 0 else 1)


def safe(value):
    return str(value).replace("|", "\\|").replace("\n", " ")


def table(lines, headings, rows):
    lines.extend(["| " + " | ".join(headings) + " |", "|" + "---|" * len(headings)])
    lines.extend("| " + " | ".join(safe(cell) for cell in row) + " |" for row in rows)
    lines.append("")


def atomic_text(path, content, encoding="utf-8"):
    temporary = path.with_suffix(path.suffix + ".tmp")
    temporary.write_text(content, encoding=encoding)
    temporary.replace(path)


def read_artifacts(root, identity):
    reports, rejected, all_results = {}, {}, {}

    def record_results(value, source):
        for result in results_in(value):
            if result.get("status") not in ("complete", "failed") or result.get("identity") != identity:
                continue
            key = result.get("id") or canonical([result["config_id"], result["split"], result.get("diagnostic"), result.get("partial_encoder_timing")])
            if key not in all_results:
                all_results[key] = {"result": slim_result(result), "sources": set()}
            all_results[key]["sources"].add(source)

    for path in sorted((root / "reports").glob("*.json")):
        if path.name == "run_identity.json" or path.name.startswith("acceptance_stale_"):
            continue
        try:
            value = load_json(path)
            state = identity_state(value, identity)
        except (ValueError, OSError) as error:
            rejected[path.stem] = "pending: unreadable JSON (%s)" % error
            continue
        if state != "matching":
            rejected[path.stem] = state
            continue
        reports[path.stem] = value
        record_results(value, "reports/" + path.name)
    for path in sorted((root / "results").glob("*.json")):
        try:
            result = load_json(path)
        except (ValueError, OSError):
            continue
        if result.get("identity") == identity:
            record_results(result, "results/" + path.name)
    return reports, rejected, all_results


def binary_package(package, result):
    """Measure the actual deployment files, not NumPy container sizes."""
    folder = Path(package["profile"])
    profile = load_json(folder / "profile.json")
    hardware = load_json(folder / "hardware_requirements.json")
    expected = dict(result["config"], gelu=package.get("gelu_structure", result["config"].get("gelu", "reference")))
    if profile.get("nonlinear") != expected:
        raise ValueError("profile configuration differs from its acceptance package")
    measured = {"actual_w4_binary_bytes": 0, "actual_w8_binary_bytes": 0,
                "actual_weight_binary_bytes": 0, "actual_deployment_bytes": 0,
                "w4_arrays": 0, "profile": str(folder), "gelu": package.get("gelu_structure", "reference")}
    weight_map = profile.get("weight_bits_by_linear", {})
    for key, spec in profile["arrays"].items():
        path = folder / spec["binary"]
        contents = path.read_bytes()
        if len(contents) != spec["binary_bytes"]:
            raise ValueError("binary size mismatch: " + str(path))
        if spec.get("binary_sha256") and hashlib.sha256(contents).hexdigest() != spec["binary_sha256"]:
            raise ValueError("binary checksum mismatch: " + str(path))
        if not spec.get("diagnostic", False):
            measured["actual_deployment_bytes"] += len(contents)
        if key.endswith(".weight"):
            bits = int(weight_map.get(key[:-7], profile.get("weight_bits", 8)))
            if bits not in (4, 8):
                raise ValueError("unexpected deployment weight precision")
            if bits == 4:
                if spec.get("physical_encoding") != "signed_twos_complement_nibbles_low_first":
                    raise ValueError("W4 binary does not declare nibble packing")
                measured["w4_arrays"] += 1
            measured["actual_w%d_binary_bytes" % bits] += len(contents)
            measured["actual_weight_binary_bytes"] += len(contents)
    if measured["actual_weight_binary_bytes"] != hardware["weight_binary_bytes"]:
        raise ValueError("hardware report weight bytes differ from deployment files")
    if measured["actual_deployment_bytes"] != hardware["deployment_binary_bytes"]:
        raise ValueError("hardware report deployment bytes differ from files")
    golden = load_json(Path(package["golden"]) / "golden_manifest.json")
    measured["golden_verified"] = (golden.get("status") == "verified" and golden.get("verified_sample_count") == 24
                                     and all(golden.get(key) for key in ("reload_bit_exact", "repeat_bit_exact", "numpy_binary_bit_exact")))
    measured["hardware"] = hardware
    return measured


def report_result_rows(results):
    rows = []
    for result in results:
        cfg = result["config"]
        rows.append([result["config_id"], result["status"], result.get("count", "-"),
                     number(percent(result.get("top1"))), number(result.get("drop_pp")),
                     len(w4_names(cfg)), result.get("weight_bytes", "-"),
                     number(result.get("nrmse")), ", ".join(w4_names(cfg)) or "W8"])
    return rows


def generate_summary(root):
    root = Path(root).resolve()
    output = root / "reports"
    output.mkdir(parents=True, exist_ok=True)
    identity_path = output / "run_identity.json"
    identity = load_json(identity_path) if identity_path.exists() else None
    if identity is None:
        reports, rejected, evaluations = {}, {}, {}
    else:
        reports, rejected, evaluations = read_artifacts(root, identity)
    now = datetime.now(timezone.utc).isoformat(timespec="seconds")
    lines = ["# W4/W8 联合优化实验分析摘要", "", "生成时间：%s。" % now, "",
             "只汇总与当前 run_identity.json 匹配的已落盘结果。未完成阶段显示 pending；准确率下降单位为百分点。",
             "普通激活固定 A8；硬件报告是数值与存储需求，没有实际 RTL 综合面积，不能按单一面积分数排名。", ""]
    if identity is None:
        lines.extend(["当前状态：pending，尚无 run_identity.json。", ""])
    else:
        lines.extend(["当前源码指纹：`%s`。" % identity.get("code", "unknown"), ""])
    stage_names = (("残差全量回归", "residual_int32"), ("权重预筛", "weight_screen"),
                   ("W4 单项验证", "weight_single_validation"), ("W4 组合", "weight_combinations"),
                   ("权重分支冻结", "weight_branches"), ("Softmax 误差归因", "softmax_attribution"),
                   ("完整验证冻结", "frozen_candidates"), ("完整测试及导出", "acceptance"))
    stage_rows = []
    for label, key in stage_names:
        value = reports.get(key)
        state = "pending" if value is None else (value.get("status", "available") if isinstance(value, dict) else "available")
        stage_rows.append([label, state, rejected.get(key, "reports/" + key + ".json" if value is not None else "尚未完成或尚未落盘")])
    lines.extend(["## 阶段状态", ""])
    table(lines, ["阶段", "状态", "来源/说明"], stage_rows)
    complete = sum(item["result"]["status"] == "complete" for item in evaluations.values())
    failed = len(evaluations) - complete
    lines.extend(["当前身份已完成的唯一评估记录：%d；失败记录：%d。全部记录见 all_accuracy_results.csv。" % (complete, failed), ""])
    residual = reports.get("residual_int32")
    if residual:
        width = max((item.get("sum", {}).get("required_signed_bits", 0) for item in residual.get("ranges", {}).values()), default=None)
        observed_low = min((item.get("sum", {}).get("minimum", 0) for item in residual.get("ranges", {}).values()), default=None)
        observed_high = max((item.get("sum", {}).get("maximum", 0) for item in residual.get("ranges", {}).values()), default=None)
        lines.extend(["残差回归：%s 条，逐位一致=%s，历史输出哈希一致=%s，溢出=%s，饱和前和实测最大位宽=%s。" %
                      (residual.get("count"), residual.get("bit_exact"), residual.get("historical_output_hashes_match"),
                       residual.get("overflow_count"), width), ""])
        proofs = residual.get("domain_proofs", {})
        domain_bits = max((signed_interval_bits(*proof["sum_domain"]) for proof in proofs.values()), default=None)
        proven = bool(proofs) and all(proof.get("int32_domain_safe") for proof in proofs.values())
        lines.extend(["实测饱和前和范围为 [%s, %s]；当前 A8 编码及固定移位的合法输入域证明最多需要 %s 位，int32 域安全=%s。正式残差运算仍为受检查的 int32；实测 %s 位不能视为任意输入安全界。" %
                      (observed_low, observed_high, domain_bits, proven, width), ""])
    lines.extend(["## W4 权重扫描与分支", ""])
    branch_values = reports.get("weight_branches", [])
    if branch_values:
        table(lines, ["分支", "配置", "验证 Top-1 (%)", "损失 (pp)", "W4 矩阵数", "逻辑权重字节", "W4 矩阵"],
              [[b["name"], b["result"]["config_id"], number(percent(b["result"].get("top1"))), number(b["result"].get("drop_pp")),
                len(w4_names(b["config"])), b["result"].get("weight_bytes", "-"), ", ".join(w4_names(b["config"])) or "W8"] for b in branch_values])
    else:
        lines.extend(["分支选择 pending；现有配置评估不等于已经冻结分支。", ""])
    for key, title in (("weight_screen", "120 条预筛"), ("weight_single_validation", "500 条单项复核"), ("weight_combinations", "500 条组合复核")):
        lines.extend(["### " + title, ""])
        values = reports.get(key)
        if values is None:
            lines.extend(["pending。已完成的配置仍可在 CSV 中查看。", ""])
        else:
            table(lines, ["配置", "状态", "条数", "Top-1 (%)", "损失 (pp)", "W4 数", "逻辑权重字节", "NRMSE", "W4 矩阵"], report_result_rows(values))
    nonlinear = [(key, value) for key, value in sorted(reports.items()) if key.startswith("nonlinear_")]
    lines.extend(["## GELU、Softmax 与 LayerNorm", ""])
    if not nonlinear:
        lines.extend(["pending：分支非线性阶段尚未完成。", ""])
    for _, record in nonlinear:
        name = record.get("branch", "unknown")
        lines.extend(["### 分支 " + name, ""])
        table(lines, ["GELU", "状态", "Top-1 (%)", "损失 (pp)"],
              [[r["config"].get("gelu"), r["status"], number(percent(r.get("top1"))), number(r.get("drop_pp"))] for r in record.get("gelu", [])])
        table(lines, ["指数 Q", "概率 Q", "状态", "Top-1 (%)", "损失 (pp)", "NRMSE"],
              [[r["config"].get("softmax", {}).get("exp_frac"), r["config"].get("softmax", {}).get("prob_frac"), r["status"],
                number(percent(r.get("top1"))), number(r.get("drop_pp")), number(r.get("nrmse"))] for r in record.get("softmax", [])])
        for key, title in (("layernorm_precision", "LayerNorm 九种精度组合"), ("layernorm_rsqrt", "LayerNorm 逆平方根组合")):
            lines.extend(["**%s**" % title, ""])
            rows = []
            for r in record.get(key, []):
                cfg = r["config"].get("layernorm", {})
                rows.append([cfg.get("norm_frac"), cfg.get("gamma_frac"), cfg.get("method"), cfg.get("lut_entries", "-"),
                             cfg.get("rsqrt_frac", "-"), cfg.get("iterations", "-"), r["status"], number(percent(r.get("top1"))),
                             number(r.get("drop_pp")), max(r.get("wide_required_bits", {}).values(), default="-")])
            table(lines, ["归一化 Q", "gamma Q", "方法", "表项", "逆平方根 Q", "迭代", "状态", "Top-1 (%)", "损失 (pp)", "宽临时量实测位宽"], rows)
    attrs = reports.get("softmax_attribution")
    lines.extend(["## Softmax 逐步损失", ""])
    if attrs is None:
        lines.extend(["pending：误差归因尚未完成或身份不匹配。", ""])
    else:
        for branch in attrs.get("end_to_end", []):
            lines.extend(["### 分支 " + branch["branch"], ""])
            table(lines, ["累计步骤", "Top-1 (%)", "相对前步损失 (pp)", "相对权重分支 (pp)", "相对 FP32 (pp)", "前步预测翻转"],
                  [[s["step"], number(percent(s["top1"])), number(s["loss_previous_pp"]), number(s["loss_weight_branch_pp"]),
                    number(s["loss_fp32_pp"]), s["prediction_flips_previous"]] for s in branch.get("cumulative", [])])
            table(lines, ["独立改动", "Top-1 (%)", "相对权重分支损失 (pp)", "相对 FP32 (pp)"],
                  [[s["step"], number(percent(s["top1"])), number(s["loss_branch_pp"]), number(s["loss_fp32_pp"])] for s in branch.get("single_factor", [])])
        lines.extend(["固定 score 回放将截断、指数编码和概率舍入分开；以下每一行取该步骤所有层中最大的最大误差，不能与全网 Top-1 损失相加。", ""])
        rows = []
        for replay in attrs.get("replay", []):
            metrics = {}
            for layer in replay.get("layers", {}).values():
                for step, values in layer.items():
                    if isinstance(values, dict) and "max_error" in values:
                        out = metrics.setdefault(step, {"max_error": 0., "row_sum": 0., "context": 0.})
                        out["max_error"] = max(out["max_error"], values["max_error"])
                        out["row_sum"] = max(out["row_sum"], values.get("max_row_sum_error", 0.))
                        out["context"] = max(out["context"], values.get("context_after_a8_max_error", values.get("context_max_error", 0.)))
            for step, values in sorted(metrics.items()):
                rows.append([replay.get("branch"), step, number(values["max_error"], 10), number(values["row_sum"], 10), number(values["context"], 10)])
        table(lines, ["分支", "局部步骤", "概率最大误差", "概率行和最大误差", "context 最大误差（有该指标时）"], rows)
    lines.extend(["## 完整验证冻结与正式测试", ""])
    frozen = reports.get("frozen_candidates")
    if frozen:
        lines.extend(["选择分区：%s；冻结状态：%s；数值候选数：%d。" % (frozen.get("selection_split"), frozen.get("status"), len(frozen.get("finalists", []))), ""])
        table(lines, ["配置", "状态", "条数", "Top-1 (%)", "损失 (pp)", "W4 数", "逻辑权重字节", "NRMSE", "W4 矩阵"], report_result_rows(frozen.get("finalists", [])))
    else:
        lines.extend(["完整验证与候选冻结 pending。", ""])
    acceptance = reports.get("acceptance")
    measured, package_errors = {}, []
    if acceptance is None or acceptance.get("status") != "complete":
        lines.extend(["正式测试/导出 pending%s。" % ("（当前状态 %s）" % acceptance.get("status") if acceptance else ""), ""])
    else:
        final_results = acceptance.get("results", [])
        table(lines, ["配置", "状态", "条数", "Top-1 (%)", "损失 (pp)", "通过", "MAC 实测位宽", "宽临时量位宽", "溢出", "CPU 秒"],
              [[r["config_id"], r["status"], r["count"], number(percent(r.get("top1"))), number(r.get("drop_pp")), r.get("pass", False),
                max(r.get("mac_required_bits", {}).values(), default="-"), max(r.get("wide_required_bits", {}).values(), default="-"),
                r.get("overflow_count", "-"), number(r.get("seconds"), 2)] for r in final_results])
        by_id = {r["config_id"]: r for r in final_results}
        for package in acceptance.get("packages", []):
            try:
                value = binary_package(package, by_id[package["config_id"]])
                measured.setdefault(package["config_id"], []).append(value)
            except (OSError, ValueError, KeyError) as error:
                package_errors.append("%s: %s" % (package.get("profile"), error))
        lines.extend(["### 实际部署文件与硬件位宽", "",
                      "下表权重字节来自已核对 SHA256 的部署 .bin 文件；不使用 .npy 容器大小充当压缩收益。", ""])
        rows = []
        for key, packages in sorted(measured.items()):
            for package in packages:
                hw = package["hardware"]
                summary = hw.get("observed_width_summary", {})
                soft = list(hw.get("softmax", {}).values())
                rows.append([key, package["gelu"], package["w4_arrays"], package["actual_w4_binary_bytes"], package["actual_w8_binary_bytes"],
                             package["actual_weight_binary_bytes"], package["actual_deployment_bytes"], summary.get("maximum_mac_signed_bits", "-"),
                             summary.get("maximum_wide_temporary_signed_bits", "-"), max((s["division_numerator_unsigned_bits"] for s in soft), default="-"),
                             package["golden_verified"]])
        table(lines, ["配置", "GELU", "W4 矩阵", "W4 .bin 字节", "W8 .bin 字节", "全部权重字节", "部署字节", "MAC 实测位宽", "临时量实测位宽", "Softmax 分子无符号位宽", "24 条 golden"], rows)
        lines.extend(["存储、查表、乘除法位宽、模式集合和 SRAM 容量分别比较；没有实际综合面积时不提供面积排名。",
                      "两种 GELU 结构的相同数值精度基于 256 码穷举及对应包核验；最终面积需考虑表、比较/旁路、端口和时序。", ""])
    if package_errors:
        lines.extend(["### 导出包检查问题", ""] + ["- " + error for error in package_errors] + [""])
    if rejected:
        lines.extend(["## 未采信的阶段文件", ""])
        table(lines, ["文件", "原因"], sorted(rejected.items()))
    lines.extend(["## 使用说明", "", "all_accuracy_results.csv 包含当前身份的全部已完成/失败配置（含尚未完成阶段中的独立结果），按配置和分区保留独立记录。",
                  "逻辑权重字节、实测二进制字节、CPU 时间、软件实测位宽分别陈列；CPU 时间不是 RTL 周期，实测位宽不是全合法域安全证明。",
                  "没有结果的项目保持 pending，不从旧身份文件或局部测试推断最终验收。", ""])
    csv_output = io.StringIO(newline="")
    writer = csv.DictWriter(csv_output, fieldnames=CSV_FIELDS)
    writer.writeheader()
    for _, item in sorted(evaluations.items(), key=lambda pair: (pair[1]["result"].get("split", ""), pair[1]["result"]["config_id"], pair[0])):
        r, sources = item["result"], item["sources"]
        cfg = r["config"]
        packages = measured.get(r["config_id"], [])
        physical = packages[0] if packages else {}
        row = {"result_id": r.get("id", ""), "config_id": r["config_id"], "stages": ";".join(sorted(s for s in sources if s.startswith("reports/"))),
               "split": r["split"], "status": r["status"], "count": r.get("count"), "correct": r.get("correct"),
               "top1_percent": percent(r.get("top1")), "float_top1_percent": percent(r.get("float_top1")),
               "drop_percentage_points": r.get("drop_pp"), "agreement_float_percent": percent(r.get("agreement_float")),
               "w4_matrix_count": len(w4_names(cfg)), "w4_matrices": ";".join(w4_names(cfg)),
               "logical_weight_bytes": r.get("weight_bytes"),
               "actual_w4_binary_bytes": physical.get("actual_w4_binary_bytes"), "actual_w8_binary_bytes": physical.get("actual_w8_binary_bytes"),
               "actual_weight_binary_bytes": physical.get("actual_weight_binary_bytes"),
               "deployment_bytes_by_gelu": canonical({p["gelu"]: p["actual_deployment_bytes"] for p in packages}) if packages else "",
               "gelu": cfg.get("gelu", "reference"), "softmax_json": canonical(cfg.get("softmax", {})),
               "softmax_by_block_json": canonical(cfg.get("softmax_by_block", {})), "layernorm_json": canonical(cfg.get("layernorm", {})),
               "layernorm_by_op_json": canonical(cfg.get("layernorm_by_op", {})), "mac_max_signed_bits": r.get("mac_max_bits"),
               "wide_max_signed_bits": r.get("wide_max_bits"), "residual_sum_max_signed_bits": r.get("residual_max_bits"),
               "saturation_count": r.get("saturation_count"), "overflow_count": r.get("overflow_count"), "encoder_seconds": r.get("seconds"),
               "samples_per_second": r.get("samples_per_second"), "partial_encoder_timing": r.get("partial_encoder_timing"),
               "diagnostic": r.get("diagnostic"), "nrmse": r.get("nrmse"), "max_error": r.get("max_error"), "pass": r.get("pass"),
               "error": r.get("error", ""), "config_json": canonical(cfg), "source_files": ";".join(sorted(sources))}
        writer.writerow(row)
    atomic_text(output / "analysis_summary.md", "\n".join(lines))
    atomic_text(output / "all_accuracy_results.csv", csv_output.getvalue(), encoding="utf-8-sig")
    return {"markdown": str(output / "analysis_summary.md"), "csv": str(output / "all_accuracy_results.csv"),
            "complete_evaluations": complete, "failed_evaluations": failed, "package_errors": package_errors}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    parser.add_argument("--experiment-root", help="Override the experiment folder under data-root")
    args = parser.parse_args()
    root = Path(args.experiment_root) if args.experiment_root else Path(args.data_root) / "experiments" / "w4w8_nonlinear_v1"
    print(json.dumps(generate_summary(root), indent=2, ensure_ascii=False))


if __name__ == "__main__":
    main()
