"""Render every required ASIC table from completed fresh measurement records."""
from pathlib import Path
from .asic import MATRICES,OPS


def render_report(s,path):
    lines=["# KWT-1 ASIC 数值实验报告（重新实测）",""]
    def prose(text): lines.extend([text,""])
    def table(headers,rows):
        lines.append("|"+"|".join(headers)+"|")
        lines.append("|"+"|".join(["---"]*len(headers))+"|")
        lines.extend("|"+"|".join(str(v) for v in row)+"|" for row in rows)
        lines.append("")
    def pct(x): return "%.4f"%(x*100)
    def f(x): return "%.4f"%x
    fp=s["baseline"]["fp32"]; final=s["final"]; rec=final["recommendations"]
    aliases={r["validation"]["config_id"]:"R%d"%(i+1) for i,r in enumerate(rec)}
    roles={"J_best":"J 最优","under_5pct":"≤5% 内 J 最优","highest_accuracy":"约束内验证精度最高"}
    prose("## 结论表")
    table(["方案/选择角色","W8 矩阵列表","总字数","增加 %","验证 4445 Top-1 %","测试 4890 Top-1 %","固定 600 Top-1 %","下降 val/test/600 pp","J","最大 MAC 位宽"],
          [[aliases[v["config_id"]]+" / "+"、".join(roles[k] for k,x in final["roles"].items() if x==v["config_id"]),", ".join(v["w8"]) or "全 W4",v["total_words"],f(v["extra_percent"]),pct(v["top1"]),pct(r["testing"]["top1"]),pct(r["check600"]["top1"]),
            "/".join(f(x) for x in [v["drop_pp"],r["testing"]["drop_pp"],(fp["check600"]["top1"]-r["check600"]["top1"])*100]),f(v["J"]),max(max(v["mac_required_bits"].values()),max(r["testing"]["mac_required_bits"].values()))] for r in rec for v in [r["validation"]]])
    prose("所有选择仅使用完整验证集；推荐角色在测试确认前冻结。若 J 最优与 ≤5% 内最优重合，第三个不同配置作为额外可比较方案；其角色明确保留，不根据测试集改选。P11 是两遍 P·V 的超预算对照，不参与原生 u8 硬件推荐。")
    table(["简称","配置 ID","Softmax","LN norm/gamma","GELU"],[[aliases[v["config_id"]],v["config_id"],"Q15/P%d"%v["config"]["softmax"]["prob_frac"],"%d/%d"%(v["config"]["layernorm"]["norm_frac"],v["config"]["layernorm"]["gamma_frac"]),v["config"]["gelu"]] for r in rec for v in [r["validation"]]])
    prose("## 数据、来源与计分")
    prose("本次全部准确率来自 `asic_numerics_v1/measurements_v2/` 的新运行；旧 `w4w8_nonlinear_v1` 只作为校准 profile、checkpoint 权重一致性及输入顺序比较的依据，没有用其准确率或预测代替实验。源文件 SHA256、NumPy、校准 profile 全文件、数据和本地整数 C 核的 SHA256 冻结在 `run_identity.json`；源代码在长实验前通过 pytest 并提交。空 worktree 子模块不写入：上游模型/checkpoint 从 E 盘已有 checkout 只读加载，并逐数组核对校准权重完全一致。")
    prose("官方 WAV 列表排序后按固定种子建分区；重新运行 TensorFlow 2.4 官方音频前端、同一 checkpoint 与同一分类头，得到完整验证 4445、测试 4890。每批 32 条保存输入/FP32 进度，600 条遵循旧审计规则在确定性新顺序每类取前 50 条，golden 每类前 2 条；索引在 `cache/selections.json` 中冻结。")
    table(["分区","条数","旧缓存同位置标签差异","与旧缓存逐值相同 boundary 行数","新 FP32 Top-1 %","旧 FP32 Top-1 %（只作审计）"],[[k,fp[k]["count"],v["label_mismatches"],v["boundary_rows_identical"],pct(fp[k]["top1"]),pct(v["old_top1"])] for k,v in s["preparation"]["cache_comparison"].items()])
    prose("代价严格按计划：全 W4=83904 个 32 位字；q/k/v/proj 每个 W8 回退 +512 字，fc1/fc2 每个 +2048 字。故全 W8 实际增量为 73728 字、+87.8719%（此前报告 +43.9% 少算一半）；不以压缩统计重定本次搜索的评分分母。`A=min(10,10−drop_val/0.2)`，`J=A−0.2×Δ%`；drop 用百分点。压缩字节是另行统计的紧密参数流，不是已改变的硬件协议。")
    prose("## 5.1 三口径统一基线")
    rows=[["FP32",pct(fp["validation_full"]["top1"]),pct(fp["testing"]["top1"]),pct(fp["check600"]["top1"]),"0 / 0 / 0"]]
    for name in ("all_w4_q15_p7_ln12","all_w8a8"):
        r=s["baseline"][name]
        rows.append([name,pct(r["validation_full"]["top1"]),pct(r["testing"]["top1"]),pct(r["check600"]["top1"])," / ".join(f(x) for x in [r["validation_full"]["drop_pp"],r["testing"]["drop_pp"],(fp["check600"]["top1"]-r["check600"]["top1"])*100])])
    table(["配置","验证 4445 %","测试 4890 %","固定 600 %","相对 FP32 下降 val/test/600 pp"],rows)
    prose("## 5.2 权重敏感度、实测组合与结构回退")
    prose("72 项单矩阵实验均在完整 4445 验证集实测，其余 71 个矩阵为 W4。前缀加速仅重用本次冻结 all-W4/P7/LN12 的逐值相同层输入；从首个变化层重新执行，前层位宽统计也来自同一本次冻结运行。")
    table(["W8 矩阵","验证 Top-1 %","Δacc pp","额外字数","增益 pp/1000 字"],[[r["matrix"],pct(r["top1"]),f(r["delta_acc_pp"]),r["extra_words"],f(r["gain_per_1000_words"])] for r in s["single"]])
    prose("按正的单项 Δacc/千字排序，逐个累积 W8；每个组合实际评估，不相加单项收益。停止原因："+s["greedy"]["stop"]+"。下表的测试与 600 是冻结曲线之后的确认值。")
    table(["点","W8 矩阵列表","总字数","+%","验证 %","测试 %","600 %","下降 val/test/600 pp","J"],[[i,", ".join(v["w8"]) or "全 W4",v["total_words"],f(v["extra_percent"]),pct(v["top1"]),pct(t["top1"]),pct(t["check600"]["top1"])," / ".join(f(x) for x in [v["drop_pp"],t["drop_pp"],(fp["check600"]["top1"]-t["check600"]["top1"])*100]),f(v["J"])] for i,r in enumerate(final["pareto"]) for v,t in [(r["validation"],r["testing"])]])
    prose("结构回退：每层整层（12 项）与七类矩阵组均实测；J 超过 all-W4 的层/类型再取并集实测，没有正贡献时不虚构并集。")
    table(["结构","W8 列表","总字数","+%","验证 %","下降 pp","J"],[[r["structure"],", ".join(r["w8"]),r["total_words"],f(r["extra_percent"]),pct(r["top1"]),f(r["drop_pp"]),f(r["J"])] for r in s["structure"]])
    prose("## 5.3 非线性对照（完整验证 4445）")
    prose("代表点按验证集角色选择；角色重合时补入下一不同且合格的高 J 点，仍测足三个。每个代表点测 P7/P8/P11 和 LN 12/12、16/16、20/16、16/12、20/20（相同基准项去重）。P8 的 1.0=256 饱和至 255，P·V 使用 Q8；原始除法结果和实际存储位宽分别列出。超过 17 位的 LN 商仅作数值对照，不能推荐。")
    def widths(r):
        ranges=r["ranges"]
        maximum=lambda suffix,key:max([v.get(key,0) for k,v in ranges.items() if k.endswith(suffix)] or [0])
        return [maximum(".normalization_quotient","required_signed_bits"),maximum(".affine_product","required_signed_bits")]+[maximum(".softmax",k) for k in ("exp_required_unsigned_bits","denominator_required_unsigned_bits","numerator_required_unsigned_bits","quotient_required_unsigned_bits","stored_required_unsigned_bits")]
    table(["W8 列表","P","LN norm/gamma","验证 %","J","LN商 s","仿射积 s","exp u","分母 u","分子 u","原商 u","存储 u","原生约束"],[[", ".join(r["w8"]) or "全 W4",r["config"]["softmax"]["prob_frac"],"%d/%d"%(r["config"]["layernorm"]["norm_frac"],r["config"]["layernorm"]["gamma_frac"]),pct(r["top1"]),f(r["J"]),*widths(r),"满足" if r["eligible"] else "超限对照"] for r in s["nonlinear"]])
    table(["层","穷举输入数","direct 项数","middle 项数","逐位差异数"],[[r["layer"],r["inputs"],r["direct_entries"],r["middle_entries"],r["mismatches"]] for r in s.get("gelu",[])])
    prose("## 5.4 参数压缩统计（冻结全 W4，不改变数值）")
    st=s["stats"]
    table(["矩阵","bias min","bias max","bias 位","shift min","shift max","shift 位"],[[r["matrix"],r["bias_min"],r["bias_max"],r["bias_bits"],r["shift_min"],r["shift_max"],r["shift_bits"]] for r in st["matrices"]])
    prose("下表 histogram 的顺序固定为 −8,−7,…,7。H 为每矩阵零阶经验熵；块熵按导出 row-major 顺序每 64 元素一块。省字估计为 `N×(4−H)/32`，只表示理想无损编码 payload 的下界收益，未计码本/块头，不是已实现的压缩结果。")
    table(["矩阵","W4 histogram −8…7","H bit/权重","块64 H均/最小/最大","矩阵熵可省字","块熵可省字"],[[r["matrix"],", ".join(map(str,r["histogram_minus8_to7"])),f(r["entropy_bits"]),"/".join(f(r[k]) for k in ("block64_entropy_mean","block64_entropy_min","block64_entropy_max")),f(r["ideal_saved_words_matrix"]),f(r["ideal_saved_words_block64"])] for r in st["matrices"]])
    prose("参数流按每数组实际位宽紧密打包并向上取整至字节；shift 码替代逐通道 weight exponent，不重复计数。LN gamma/beta 使用其实际范围。共享 LUT 按实际 key 去重，另计外部 FP32 前端/分类头；不含容器 JSON/NPY 头、总线对齐及未规定的元数据。golden v3 bias 为兼容协议仍保留 int32，以下是可无损压缩的统计，尚未改变 golden 格式。")
    table(["层","W4 字节","bias 实宽字节","shift 实宽字节","LN 实宽字节","其他合计字节","层参数总字节"],[[r[k] for k in ("layer","w4_bytes","bias_actual_width_bytes","shift_actual_width_bytes","layernorm_actual_width_bytes","other_bytes","parameter_bytes")] for r in st["layers"]])
    table(["范围","字节"],[["12 层编码器参数",st["encoder_parameter_bytes"]],["共享 Softmax/GELU ROM",st["shared_lut_bytes"]],["外部 FP32 前端/头",st["external_fp32_bytes"]],["全模型含 LUT",st["total_model_bytes"]]])
    prose("## 推荐配置的逐矩阵与逐层位宽")
    prose("以下位宽取完整验证与完整测试中的最大值；MAC 前缀按实际 K 顺序逐项累加，包含所有前缀，bias 和单独检查。每步使用整数核，与 NumPy 受检后备实现交叉测试；没有用最终和或理论上界冒充实测前缀宽度。所有已完成测量溢出数为 0，分类输出有限。")
    def mac(r,key): return max(r["validation"]["mac_required_bits"][key],r["testing"]["mac_required_bits"][key])
    table(["矩阵"]+[aliases[r["validation"]["config_id"]]+" 前缀/bias和" for r in rec],[[key]+["%d/%d"%(mac(r,key+".matmul"),mac(r,key+".accumulator")) for r in rec] for key in MATRICES])
    table(["注意力 MAC"]+[aliases[r["validation"]["config_id"]]+" 前缀位" for r in rec],[["b%02d.%s"%(i,op)]+[mac(r,"b%02d.%s.matmul"%(i,op)) for r in rec] for i in range(12) for op in ("score","context")])
    def range_max(r,key,field): return max(r[split]["ranges"][key][field] for split in ("validation","testing"))
    table(["层"]+[aliases[r["validation"]["config_id"]]+" bias位 q/k/v/proj/fc1/fc2" for r in rec],[["b%02d"%i]+["/".join(str(range_max(r,"b%02d.%s.bias"%(i,op),"required_signed_bits")) for op in OPS) for r in rec] for i in range(12)])
    table(["方案","层","LN1商/仿射积 s","LN2商/仿射积 s","SM exp/分母/分子/原商/存储 u"],[[aliases[r["validation"]["config_id"]],"b%02d"%i,*["%d/%d"%(range_max(r,"b%02d.ln%d.normalization_quotient"%(i,j),"required_signed_bits"),range_max(r,"b%02d.ln%d.affine_product"%(i,j),"required_signed_bits")) for j in (1,2)],"/".join(str(range_max(r,"b%02d.softmax.softmax"%i,k)) for k in ("exp_required_unsigned_bits","denominator_required_unsigned_bits","numerator_required_unsigned_bits","quotient_required_unsigned_bits","stored_required_unsigned_bits"))] for r in rec for i in range(12)])
    prose("## 600 条配对 bootstrap")
    prose("从完整测试 4890 条上按同一索引有放回抽取 600 条，共 10000 次（seed=20261108）。每条差值为 FP32 正确指示减整数方案正确指示，故统计的是相对 FP32 的下降，而非整数方案自身错误率；测试与固定 600 都不参与选择。")
    table(["方案","固定600下降 pp","均值 pp","标准差 pp","P5 pp","P50 pp","P95 pp","P(drop>2pp)"],[[aliases[r["validation"]["config_id"]],f((fp["check600"]["top1"]-r["check600"]["top1"])*100),*[f(r["bootstrap"][k]) for k in ("mean_pp","std_pp","p05_pp","p50_pp","p95_pp","prob_gt_2pp")]] for r in rec])
    prose("## Golden 与逐位核验")
    table(["方案","包目录","profile","trace样本","算子向量","manifest"],[[aliases[r["config_id"]],r["package"],"v3 / MAC24",r["manifest"]["samples"],r["operator_vectors"],r["manifest"]["status"]] for r in s["golden"]])
    prose("## 复现、偏离与限制")
    prose("入口：`python -B quantization/scripts/run_asic_numerics.py --data-root <data-root> --repo-root . --reference-root <reference-repo> --workers 12 --resume`；设置 CUDA_VISIBLE_DEVICES=-1、OMP/OPENBLAS/MKL_NUM_THREADS=1；可选设置 KWT_ASIC_MAC_LIBRARY。可用 --stage 按阶段恢复；FP32 每32条、整数每8条落盘进度，身份改变拒绝混用。原生整数核逐项检查前缀位宽；未加载时回退 NumPy。Golden 导出检查重复推理、重载与二进制一致性，包验证检查校验和与张量格式；这些检查不替代 RTL 验证。")
    prose("机器汇总位于数据根目录的 `experiments/asic_numerics_v1/summary.json`；测量、进度和 golden 在其 `measurements_v2` 子目录。准确率为本地样本测量；熵数字为理论估计，未实现编码器或测量 RTL 面积和周期。")
    Path(path).write_text("\n".join(lines),encoding="utf-8")
