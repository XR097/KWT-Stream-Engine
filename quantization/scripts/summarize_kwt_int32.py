"""Render verified full-test and golden artifacts without importing TensorFlow."""
import os
import argparse
import json
from pathlib import Path


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    args = parser.parse_args()
    root = Path(args.data_root)
    acceptance = json.loads((root / "reports/acceptance.json").read_text(encoding="utf-8"))
    results = json.loads((root / "reports/test_profiles.json").read_text(encoding="utf-8"))[0]
    golden = json.loads((root / "golden/W8A8_integer/golden_manifest.json").read_text(encoding="utf-8"))
    if acceptance.get("status") != "complete" or results.get("count") != 4890:
        raise ValueError("complete 4890-sample acceptance is required")
    if golden.get("verified_sample_count") != 24 or not golden.get("reload_bit_exact"):
        raise ValueError("all 24 golden samples must pass reload verification")
    mac_bits = max(results["mac_required_bits"].values())
    wide_bits = max(results["wide_temporary_required_bits"].values())
    lines = ["# KWT-1 W8A8 / int32 MAC 完整测试报告", "",
             "| 指标 | 实测 |", "|---|---:|",
             "| 测试样本数 | 4890 |",
             "| FP32 Top-1 | %.6f%% |" % (results["float_top1"] * 100),
             "| W8A8 Top-1 | %.6f%% (%d/4890) |" % (results["top1"] * 100, results["correct"]),
             "| 准确率下降 | %.6f 个百分点 |" % results["drop_percentage_points"],
             "| 前 4800 条 Top-1 | %.6f%% |" % (results["first4800"] * 100),
             "| 浮点预测一致率 | %.6f%% |" % (results["prediction_agreement_float"] * 100),
             "| MAC 最大所需位宽 | %d |" % mac_bits,
             "| 宽临时量最大所需位宽 | %d |" % wide_bits,
             "| 溢出次数 | %d |" % results["overflow_count"],
             "| 张量饱和次数 | %d |" % results["saturation_count"],
             "| 编码器 CPU 耗时 | %.2f 秒 |" % results["seconds"],
             "| 编码器吞吐量 | %.3f 样本/秒 |" % results["samples_per_second"],
             "| 本地精度验收 | %s |" % ("通过" if acceptance["pass"] else "未通过"), "",
             "本次固定使用已有测试缓存中的全部 4890 条，标签顺序与 FP32 缓存逐项核对，使用相同浮点分类头。",
             "验收标准为完整测试集 Top-1 下降不超过 2 个百分点且无 MAC 溢出。官方 600 条清单未公布，本报告不是官方评测结果。", "",
             "W8A8 指矩阵权重和普通算子激活位宽；Softmax 概率保持既有 uint16/Q15 编码，LayerNorm 参数、LUT 和内部统计量另有位宽。",
             "线性层、QKᵀ、概率×V 使用 int32 MAC 语义：NumPy int64 参考计算先证明部分和上界，再检查结果并转换为 int32；无截断回绕或隐式饱和。",
             "LayerNorm、Softmax、GELU、残差及重定标保留 int64 临时量。权重和张量的 NumPy 容器仍使用 int64，本轮没有实现紧凑 int8 文件打包。", "",
             "CPU 耗时为 batch32、开启 trace、位宽与溢出检查的主机实验结果；不代表原生 int32 内核性能、batch1 延迟或 E203 性能。", "",
             "## 12 层输出误差", "", "NRMSE = sqrt(sum(error²) / sum(reference²))；使用相同的官方浮点边界。", "",
             "| 层 | RMSE | NRMSE | 最大绝对误差 |", "|---|---:|---:|---:|"]
    for index in range(12):
        name = "b%02d.output" % index
        item = results["trace_errors"][name]
        lines.append("| %s | %.6g | %.6g | %.6g |" % (name, item["rmse"], item["nrmse"], item["max_error"]))
    lines += ["", "逐算子误差、全量饱和计数、混淆矩阵、MAC/宽临时量位宽和运行指纹见 test_profiles.json。",
              "宽临时量位宽为实测各个已记录整数值的最小有符号宽度；不能将它解释为硬件实现的安全总线宽度。", "",
              "## Golden 复核", "", "24 条验证样本逐条完成：原编码器重复运行、从包内 profile 和整数二进制输入重载、NumPy/二进制逐位比较。",
              "导出包位于 golden/W8A8_integer，profile/ 包含权重、尺度和 LUT；golden_manifest.json 列出输入输出 shape、dtype、布局、字节序及尺度。", "",
              "## 恢复执行", "", "```powershell",
              "conda run --no-capture-output -n kwt-quant python -u -m quantization evaluate --data-root kwt-data --repo-root . --resume",
              "conda run --no-capture-output -n kwt-quant python -m quantization export --data-root kwt-data --repo-root .",
              "python quantization/scripts/summarize_kwt_int32.py --data-root kwt-data", "```", "",
              "evaluate 每 32 条写入 cache/w8a8_int32_evaluate_progress.json；仅在代码/profile/数据/checkpoint 指纹一致时复用。未完成或失败的运行不会标记正式通过。", ""]
    path = root / "reports/W8A8_int32_report.md"
    path.write_text("\n".join(lines), encoding="utf-8")
    print(path)


if __name__ == "__main__":
    main()
