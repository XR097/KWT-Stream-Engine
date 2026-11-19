"""Summarize completed global W4 experiments and export 24-sample binary golden packages."""
import argparse
import hashlib
import json
import os
import sys
from pathlib import Path

for _k in ("OMP_NUM_THREADS", "OPENBLAS_NUM_THREADS", "MKL_NUM_THREADS"):
    os.environ.setdefault(_k, "1")
sys.path.insert(0, str(Path(__file__).resolve().parents[2]))
import numpy as np
from quantization.integer import IntegerEncoder, configure_profile
from quantization.export import load_profile, export_golden, export_operator_vectors
from quantization.experiments import check_space


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data-root", default=os.environ.get("KWT_DATA_ROOT", str(Path(__file__).resolve().parents[2] / "kwt-data")))
    args = ap.parse_args()
    root=Path(args.data_root)
    folder=root/"experiments"/"w4w8_nonlinear_v1"
    report=json.loads((folder/"reports"/"global_w4_modes.json").read_text(encoding="utf-8"))
    if report.get("status") != "complete" or len(report["configs"]) != 2:
        raise RuntimeError("global W4 full evaluation is not complete")
    p0,a0=load_profile(root/"profiles"/"W8A8_integer")
    with np.load(folder/"cache"/"weights.npz") as src:
        weights={k:src[k] for k in src.files}
    selection=json.loads((folder/"reports"/"audit_selections.json").read_text())["selections"]["golden"]
    with np.load(selection["source_cache"]) as src:
        samples=src["boundary"][selection["indices"]]
    report["packages"]=[]
    for item in report["configs"]:
        test=item["testing"]
        if test["status"]!="complete" or test["count"]!=4890 or test["overflow_count"]!=0:
            raise RuntimeError("incomplete/overflowing testing result")
        if item["validation_full"]["count"] != 4445:
            raise RuntimeError("incomplete validation")
        check_space(folder)
        p,a=configure_profile(p0,a0,weights,item["config"])
        if p["accumulator_bits"]!=32 or p["residual_accumulator_bits"]!=32:
            raise RuntimeError("int32 accumulators required")
        dest=folder/"golden"/item["name"]
        manifest=export_golden(dest,samples,IntegerEncoder(p,a),weights,p["exponents"]["b00.input"],layer_traces=True)
        operators=export_operator_vectors(dest/"operators",IntegerEncoder(p,a))
        report["packages"].append({"name":item["name"],"path":str(dest),"count":manifest["count"],
                                  "reload_bit_exact":manifest["reload_bit_exact"],
                                  "repeat_bit_exact":manifest["repeat_bit_exact"],
                                  "numpy_binary_bit_exact":manifest["numpy_binary_bit_exact"],
                                  "operator_count":operators["count"],"operators_status":operators["status"]})
        print(item["name"],"golden and operator binaries verified",flush=True)
    stream=json.loads((folder/"reports"/"softmax_row_stream.json").read_text())
    if stream["status"]!="verified" or any(m["samples"]!=24 for m in stream["modes"]):
        raise RuntimeError("24-sample row-stream verification incomplete")
    report["stream_verification"]="softmax_row_stream.json"
    report["traffic_model"]="attention_dataflow.json"
    report["delivery_status"]="verified"
    report["sample_selection"]=selection
    report["script_sha256"]={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in
                             (Path(__file__),Path(__file__).with_name("run_global_w4_modes.py"),
                              Path(__file__).with_name("verify_softmax_row_stream.py"),
                              Path(__file__).with_name("report_attention_dataflow.py"))}
    (folder/"reports"/"global_w4_modes_delivery.json").write_text(json.dumps(report,indent=2),encoding="utf-8")
    lines=["# 全 W4 全局格式与注意力调度实验", "", "FP32 与候选使用同一完整 4890 条测试及浮点分类头；不以测试结果调参。", "",
           "| 格式 | 验证 Top-1 | 测试 Top-1 | 相对 FP32 下降(pp) | 一致率 | int32 MAC 最大实测位宽 | 溢出 |", "|---|---:|---:|---:|---:|---:|---:|"]
    for item in report["configs"]:
        v,t=item["validation_full"],item["testing"]
        lines.append("| %s | %.4f%% | %.4f%% | %.4f | %.4f%% | %d | %d |" %
                     (item["name"],100*v["top1"],100*t["top1"],t["drop_pp"],100*t["agreement_float"],max(t["mac_required_bits"].values()),t["overflow_count"]))
    lines += ["", "两种格式均为 A8、72 个矩阵全 W4；MAC 和残差为受检查的 int32。LayerNorm 等统计临时量按冻结数值规格使用更宽整数。", "",
              "行/tile 核对：24 条固定验证 golden，12 层，tile=1/8；score、P、context 逐位一致，逐个归约步骤检查 int32 部分和。软件调度核对不替代 RTL 验证。", "",
              "各格式已导出 24 条逐层 golden 和 108 组算子向量，NumPy/小端二进制互验、重复推理和包重载逐位一致。", "",
              "资源比较见 attention_dataflow.md。真实面积、150 MHz 时序和总线性能尚待统一 RTL 与 SRAM 宏验证。", ""]
    (folder/"reports"/"global_w4_modes.md").write_text("\n".join(lines),encoding="utf-8")
    print(folder/"reports"/"global_w4_modes.md",flush=True)


if __name__=="__main__":
    main()
