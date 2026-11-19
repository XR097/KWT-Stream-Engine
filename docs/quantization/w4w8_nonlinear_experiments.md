# W4/W8 与整数非线性联合优化实验

本实验在固定 KWT-1 checkpoint 上进行训练后量化。编码器为 12 层、边界输入输出为 `99 x 64`，普通激活固定 A8；音频前端、输入投影和分类头沿用浮点参考。实验不训练、不引入 A16、不改第三方源码。

完整测试的精度门槛为：同一 4890 条测试集、同一浮点分类头下，相对 FP32 的 Top-1 下降不超过 **2 个百分点**，并且 MAC、残差无溢出。此处是本地完整测试口径，不代表尚未提供清单的官方 600 条验收。

## 环境与执行

默认复用已安装的 `kwt-quant` Conda 环境：Python 3.8、TensorFlow 2.4.0、TensorFlow Addons 0.12.1、NumPy 1.19.5。实际版本以 `kwt-data/reports/kwt-quant-pip-freeze.txt` 为准。TensorFlow 2.4.0 是当前可用的正式版本，历史环境说明中的 `2.4.0rc1` 不应被误解为本轮实际安装版本。

在仓库根目录使用 PowerShell：

```powershell
.\quantization\scripts\run_mixed_nonlinear.ps1 -Resume
```

可指定并行工作进程数及现有数据根目录：

```powershell
.\quantization\scripts\run_mixed_nonlinear.ps1 -DataRoot kwt-data -Workers 4 -Resume
```

脚本的 `-Python` 参数用于指定独立环境的 Python 解释器，默认使用 PATH 中的 `python`。脚本禁用 GPU，限制 NumPy/BLAS 线程为 1，避免多个进程之间的线程过度竞争；TensorFlow 参考默认使用 4 个计算线程。本轮不需要安装 CUDA 或综合工具。

推荐使用上述 PowerShell 入口。它在权重扫描后调用独立选择器，保证真正 W4/W8 混合分支不会被全 W4 对照覆盖；`all` 按残差、权重、选择器、非线性、联合选择、正式测试的顺序执行。

直接使用 Python 时，应在外部设置 CPU、线程和禁止生成字节码的环境变量，并按以下顺序执行：

```powershell
python -B -u -m quantization experiment --data-root kwt-data --repo-root . --workers 4 --stage residual --resume
python -B -u -m quantization experiment --data-root kwt-data --repo-root . --workers 4 --stage weights --resume
python -B quantization/scripts/select_mixed_weight_branches.py --data-root kwt-data
python -B -u -m quantization experiment --data-root kwt-data --repo-root . --workers 4 --stage nonlinear --resume
python -B -u quantization/scripts/search_mixed_layerwise.py --data-root kwt-data --repo-root . --workers 4 --resume
python -B quantization/scripts/audit_final_mixed.py --data-root kwt-data --repo-root . --prepare
python -B -u -m quantization experiment --data-root kwt-data --repo-root . --workers 4 --stage final --resume
python -B quantization/scripts/audit_final_mixed.py --data-root kwt-data --repo-root . --audit
python -B quantization/scripts/summarize_mixed_nonlinear.py --data-root kwt-data
python -B quantization/scripts/report_hardware_candidates.py --data-root kwt-data
```

原始 `python -m quantization experiment --stage all` 保留原控制分支和搜索排程，不包含独立选择器和覆盖修正，因此不作为上述推荐流程的等价替代。

运行算子和导出相关回归测试：

```powershell
python -B -m pytest quantization/tests -q
```

所有新实验产物放在 `kwt-data/experiments/w4w8_nonlinear_v1`，与已有 `profiles/W8A8_integer`、原始报告和 golden 分离。数据准备、正式评估及大文件导出前检查可用空间；不足 10 GiB 时停止新增大体积输出，保留恢复信息。

## 阶段与恢复

`-Stage` 支持以下阶段。首次执行推荐使用 `all`；跳过前置阶段时，所需报告必须已经存在且指纹匹配。

| 阶段 | 实际工作 |
|---|---|
| `prepare` | 来源审计、旧缓存官方重生成验证、冻结完整验证分区和浮点权重缓存 |
| `residual` | 全部 4890 条原/新残差逐层逐位对照，核对历史完整测试输出哈希，生成残差实测范围及合法输入域证明 |
| `weights` | 生成不变前缀缓存，执行单矩阵 W4、对照及 W4/W8 组合筛选；PowerShell 入口随后自动调用混合分支选择器 |
| `nonlinear` | 分支内 GELU、Softmax、LayerNorm 单项和全局组合；生成 Softmax 误差归因 |
| `joint` | 逐层混合搜索、完整验证评估，写入测试前冻结候选 |
| `final` | 冻结候选的完整测试、硬件需求报告、通过方案的打包 profile 和 golden |
| `report` | 验证准备状态及无损映射，根据现有结果重写 Markdown 报告 |
| `all` | PowerShell 入口按阶段执行全部实验，在 `weights` 后插入混合分支选择器 |

例如，仅恢复已完成权重筛选后的非线性实验：

```powershell
.\quantization\scripts\run_mixed_nonlinear.ps1 -Stage nonlinear -Resume
```

`report` 也会执行数据准备入口及有限域映射检查，不是只打开文本文件。即使使用 `-Resume`，数据准备仍会初始化官方 TensorFlow 处理器并校验来源文件；正常恢复时不会重复生成已经验证的旧样本或完整验证批次。

配置使用规范 JSON 的 SHA256 前 20 位作为 `config_id`。数值结果缓存另包含配置、分区、诊断模式、起始层及实验身份，避免把预筛、后缀加速或正式诊断结果混用。实验身份包含量化源码、NumPy 版本、基准 profile 全部文件、浮点权重、校准统计、旧三分区缓存及完整验证缓存的指纹。前置阶段报告在载入时检查身份；配置或依赖变化后，不能以旧报告继续冻结新候选。

评估每 32 条保存进度，结果文件只在配置完成或明确失败后落盘。前缀缓存仅用于未变化的前层，允许 W4 单矩阵和组合扫描从首个变化层继续；正式测试从第 0 层运行。恢复同一配置会复用已完成批次。改变实验代码会改变身份，因此长实验运行中应避免编辑 `quantization` 源码。

结果中的 `seconds` 是该候选各批次 `IntegerEncoder.run` 调用的累计主机墙钟时间，正式诊断时包含逐层 trace 开销，不包括外部浮点分类头、浮点误差参照和文件导出。`samples_per_second` 由样本数除以该时间得到。本轮使用 8 个并行候选工作进程、每批最多 32 条，因此这些数据不等同于独占 CPU 的单任务 batch=1 延迟，也不是 RTL 周期或 E203 性能。

## 数据口径与来源

| 用途 | 条数 | 数据位置与选择规则 |
|---|---:|---|
| 训练校准 | 1200 | 读取原 `cache/training.npz`；保持原样本顺序，实际不是每类恰好 100 条 |
| 验证预筛 | 120 | 原 500 条验证缓存中，每类按原顺序取前 10 条 |
| 验证复核 | 500 | 原 `cache/validation.npz` |
| 完整验证 | 4445 | 官方处理器重建的整个验证分区，首次实际顺序写入来源清单后冻结 |
| 正式本地测试 | 4890 | 原 `cache/testing.npz` 全部样本，保持顺序和标签 |
| Golden | 24 | 原 500 条验证缓存中，每类按原顺序取前 2 条 |

当前官方处理器使用 checkpoint 的 `split_data=1` 和官方 hash 分区算法。Windows 下 `gfile.Glob` 枚举顺序可能变化，导致未知类抽样及打乱顺序也变化，因此不能将新处理器索引直接认定为旧缓存来源。

数据准备通过旧缓存的精确 PCM16 波形、标签及官方 hash 分区匹配原始 WAV，然后使用官方 `get_batch` 重新生成全部旧样本。波形要求精确匹配；边界和 logits 分别检查 `atol=rtol=1e-6`、`1e-4`，且预测必须一致。实际最大误差、样本数及状态记录在 `cache/legacy_verification.json`。

每条真实语音记录相对路径、原文件 SHA256、`_nohash_` 前的说话人标识和标签。存在多个相同 PCM 来源时，明确保留 `source_candidates`，不虚构唯一来源。泄漏检查使用全部候选来源，分别检查校准训练、验证和测试间的路径、文件内容及说话人交叉。silence 是不混背景的合成零波形，单独记录且不作为真人语音进行泄漏比较。

完整验证的实际顺序、来源及 SHA256 固定在本实验目录；后续恢复不依赖再次枚举得到的顺序。训练各类数量、预筛及 golden 的固定索引见实验根目录 `metadata.json`。旧缓存保持不变。

## 数值配置与实验矩阵

所有普通激活使用静态对称 A8，零点为 0，尺度为 2 的幂，采用最近偶数舍入和显式饱和。线性层 `XW+b`、`QK^T`、概率乘 V 以及残差加法采用受检查的 int32 语义；软件参考通过宽整数执行必要的安全检查，不代表已经使用原生优化的 int32 内核。LayerNorm、非线性和重定标临时量保留受检查的宽整数。

### W4/W8 权重

72 个线性矩阵逐个探索 W4，另设全 W4、仅 FFN W4 对照。W4 按输出通道量化到 `[-8,7]`，重新编码关联 bias。保留训练校准的普通激活尺度，不使用测试集进行重标定。

所有单矩阵配置先运行 120 条预筛，前 24 个进入 500 条验证；随后在固定顺序下构建保守压缩与高压缩两条路径，验证精度损失门槛分别为 1.0、1.5 个百分点，最多评估 64 个组合。保留 W8A8 及去重后的混合权重分支，继续后续非线性实验。最终选择依据是实测组合，不能将单项准确率变化简单相加。

独立 `select_mixed_weight_branches.py` 从当前身份的 64 条组合报告中恢复两条路径：偶数索引为保守路径，奇数索引为高压缩路径。每条路径只接受完整 500 条验证、满足对应损失门槛且 W4 矩阵数为 1–71 的配置，依次按权重字节最少、正确数最多、配置 ID 排序选择并去重。W8A8 固定保留；去重后总分支不足三个时，将原全 W4 结果作为明确命名的 `all_w4_control` 保留，不让其竞争或替代真正混合分支。所有选择仅使用验证结果。

选择器首次保存原报告至 `weight_branches_control_selection.json`，随后原子写入修正的 `weight_branches.json`；重复执行保留原备份且结果幂等。`weight_branch_selection.json` 记录选择规则、路径、角色、脚本 SHA256 和实验 identity。该修正不改量化源码及数值结果，因此原计算指纹与缓存保持有效。全 W4/仅 FFN W4 的完整对照测量仍保留在 `weight_single_validation.json`。

### GELU

保留原 `INT8 -> Q16 -> Q20 LUT + 插值 -> INT8` 参考实现。`direct` 对实际输入/输出尺度生成最终 INT8 的 256 项映射；`middle` 仅存储需要查表的中间段，负尾部输出零，正尾部执行对应尺度转换及饱和。所有实际尺度组合都穷举全部 256 种输入，验证最终映射及饱和语义。

当前冻结尺度对应的表项和中段阈值由 `reports/lossless_maps.json` 给出。通过的最终数值候选分别导出 `direct`、`middle` 两套等价结构，并各自生成硬件需求报告。中段结构减少表项，但增加比较和旁路逻辑，软件结果不能单独决定它的净综合面积更小。

### Softmax

保留原 4097 项指数表作参考，压缩表保留每隔 16 项的值，共 257 项。使用当前全部 score 尺度及合法 INT8 score 差值验证无损压缩，score 相减保留足够位宽。

每个权重分支测试六种组合：指数 Q24/Q15 与概率 U16/Q15、U12/Q11、U8/Q7。降低概率小数位时同步改变概率乘 V 的重定标，保持独立最近偶数舍入，不额外修正概率行和。

`softmax_attribution.json` 同时报告单因素与累计链：参考、压缩表、指数 Q15、概率 Q11、概率 Q7。记录每一步相对前一步、当前权重分支及 FP32 的 Top-1 变化，并统计预测翻转。固定 score/V 回放另外分解截断、指数编码、归一化舍入、概率行和、变零比例和 context 误差。误差可能抵消，累计变化不等于各项损失之和。

指数最大编码 `2^24` 需要 25 位无符号表示，Q15 指数最大编码 `2^15` 需要 16 位。Q15 指数和 Q15 概率的最大除法分子为 `2^30`，硬件需求使用包含端点的真实位宽。

### LayerNorm

方差维持 Q24，epsilon 保留非零编码 `17 * 2^-24`；归一化结果和 gamma 的小数位分别从 20、16、12 中选择，共九种组合。gamma 从冻结浮点权重直接生成，不反复降低已有整数编码精度。

保留整数平方根及除法参考，另测试规格化至 `[1,4)` 的逆平方根查表乘法：64/256 项、16/20 位小数、0/1 次 Newton 修正，共八种配置，与两个入选的非参考精度组合配对。均值、方差、epsilon、归一化及 gamma 的精度分别定义；降低小数位不会自动保证所有迭代临时乘积变窄。

### 联合选择与冻结

每分支比较六种 Softmax 与三个入选 LayerNorm 的全局组合，再进行最多 64 个逐层精度/算法调整。使用最多四个候选的队列，保留准确率与独立硬件需求轴上的 Pareto 候选，不构造未经综合校准的单一面积分数。

独立搜索脚本 `quantization/scripts/search_mixed_layerwise.py` 每轮优先覆盖全部 12 个块，再生成补充候选；每个提案只修改一个 Softmax 或 LayerNorm 算子。已有匹配指纹的逐层结果同样计入每分支 64 个预算。覆盖记录保存提案父配置、操作、层号及脚本 SHA256，避免恢复运行后遗漏层或重复扩大预算。最终完整验证和冻结保留权重分支覆盖与准确率最优代表。

最多 12 个配置进入完整验证，最多 6 个数值配置在正式测试前写入 `frozen_candidates.json`。完整测试只用于判断冻结候选通过或失败，不用于再次调整层位宽、尺度或近似参数。每个候选是否完成、实际测试条数、Top-1、相对 FP32 下降和失败原因，以其结果 JSON 为准。

## 导出格式与硬件需求边界

profile v3 支持逐矩阵权重位宽、逐块 Softmax、逐算子 LayerNorm 和 GELU 映射。旧 profile 仍可加载。权重矩阵沿用 `[input, output]`、行优先布局。

W8 以 int8 导出；W4 的 `.npy` 为 int8 镜像，部署 `.bin` 按二补码双 nibble 紧密打包，先低半字节再高半字节，奇数元素末尾高半字节补零。bias 明确为 int32；其他整数参数按可容纳其编码的最小整数容器导出。所有二进制均为小端，manifest 明确逻辑位宽、物理 dtype、shape、布局、打包方式及校验和。

独立加载器优先读取部署二进制，验证尺寸和 SHA256，并在 NumPy 镜像存在时交叉核对。Golden 包包含自身 profile、24 条浮点边界、整数输入输出、逐层关键张量及算子边界向量；重复推理、二进制解码、独立包重载及逐层结果一致后才写入 verified 标记。

正式测试前，外部审计脚本预固定 golden 与每类 50 条本地 600 检查集的索引、标签和源缓存 SHA256。完成后独立审计冻结记录、完整测试及全部导出文件，补充前 4800 条和本地 600 条指标；这两种附加口径不用于正式验收。共享 `runtime` 目录复制冻结的最小整数运行时，仅依赖 NumPy，在不导入仓库、TensorFlow 或 checkpoint 的子进程中重放每个包；每包 `provenance.json` 记录来源和运行时 SHA256。正式通过仍以完整 4890 条为准。

`report_hardware_candidates.py` 读取完整验收和已校验的二进制包，按独立硬件需求轴生成 `reports/hardware_candidates.json` 与 `.md`，并给出低权重容量、较高准确率、较窄数据通路的优先综合代表。全表和中段 GELU 均保留，报告不产生未经工艺库校准的单一面积分数。

硬件需求报告区分逻辑编码大小、实际部署二进制、诊断数组和完整归档开销；NumPy 参考容器的内存不等于 RTL 存储。报告还包括：

- 乘法操作数位宽/符号、int32 累加范围、残差移位和逐任务操作次数。
- Softmax 指数、分母及除法分子位宽，整矩阵和逐行概率缓冲容量。
- LayerNorm 参考/逆平方根配置、仿射乘法、除法/平方根调用量、迭代保守范围及实测位宽。
- GELU 表项、在线插值乘法、尾部比较需求，以及共享与独立数据通路的模式集合。
- 紧密打包、16 位字对齐、`16 x 4096/1024/128` SRAM 的容量取整示例。

SRAM 示例未决定端口、banking、时序及工艺外围面积；动态操作次数也不是算术单元实例数。共享 W8 乘法器时，部分矩阵改为 W4 不一定缩小乘法器本体。CPU 耗时不能转换为 E203 周期。

赛题硬件口径：内部存储采用 `16 bits x 128/1024/4096` 的单端口或双端口 SRAM 宏组合，统一工作频率和逻辑综合时序目标为 **150 MHz**；面积为**新增加速器、接口逻辑及内部 SRAM 宏面积之和**，上限 **2.25 mm²**。标准单元按指定库的综合映射结果统计，SRAM 宏按组委会提供的面积数据统计，不得遗漏或重复计入。复用的 E203、512 KB 共享 SRAM 及固定总线和外设不计入该面积预算，其面积单列报告；以逻辑综合结果核验，不作物理边长或布局布线验收。

上述容量形状已有赛题依据，但容量取整示例尚未选择实际单/双端口宏、banking 或绑定官方宏面积数据，不能据此比较真实面积。本轮交付满足精度条件、适合后续 RTL 对照和综合的候选，`estimated_area` 保持空值。真实最小面积须在统一架构、官方工艺库及 SRAM 模型下完成综合，并满足上述 150 MHz、2.25 mm² 及统一计入要求后确定；吞吐、功耗和面积须来自同一冻结配置，不得拼接不同配置的最优结果。

## 结果位置与判读

默认实验根目录：`kwt-data/experiments/w4w8_nonlinear_v1`。

| 路径 | 内容 |
|---|---|
| `metadata.json` | 数据口径、缓存路径、来源审计状态、固定索引和权重/完整验证指纹 |
| `cache/legacy_sources.json`、`validation_full_sources.json` | 样本来源与冻结顺序 |
| `cache/legacy_verification.json`、`leakage_audit.json` | 官方重生成和语音泄漏检查结果 |
| `progress/`、`results/` | 配置级批次恢复点、完成/失败结果 |
| `reports/run_identity.json` | 当前实验身份 |
| `reports/residual_int32.json` | 全量残差逐位回归、实测位宽和输入域安全证明 |
| `reports/weight_*.json`、`nonlinear_*.json`、`joint_*.json` | 单项筛选与联合搜索过程 |
| `reports/weight_branch_selection.json`、`weight_branches_control_selection.json` | 混合分支选择算法/脚本指纹，以及未修正的原控制选择报告 |
| `reports/softmax_attribution.json`、`softmax_replay_*.json` | Softmax 全网消融及固定输入误差归因 |
| `reports/frozen_candidates.json` | 正式测试前冻结的完整验证候选 |
| `reports/acceptance.json`、`experiment_report.md` | 最终机器可读结果与汇总报告 |
| `profiles/candidate_<id>_<gelu>/` | 打包 profile 及 `hardware_requirements.json` |
| `golden/candidate_<id>_<gelu>/` | 自包含 golden 及 `operator_vectors` |

长实验未完成时，读取 `acceptance.json` 的 `status` 及配置实际条数，不将部分结果当作通过。通过方案必须具有完整 4890 条测试结果、精度门槛满足、无溢出且对应 golden 核验成功。最终准确率、性能、位宽和推荐配置均引用本轮结果文件；本说明不预写尚未完成的实验结论。

### 独立分析汇总

无需导入 TensorFlow，可随时从当前身份的已完成结果生成便于浏览的摘要及 CSV：

```powershell
python -B quantization/scripts/summarize_mixed_nonlinear.py --data-root kwt-data
```

脚本只新增或覆盖 `reports/analysis_summary.md` 与 `reports/all_accuracy_results.csv`，不改原阶段报告。未完成阶段明确显示 pending，旧身份报告不采信；CSV 也收录尚未完成阶段中已经单独落盘的完整/失败配置。最终导出存在时，脚本核对部署二进制的大小及 SHA256，再分别给出真实 W4/W8 权重字节数和各 GELU 结构的部署字节数，不用 NumPy 容器或单一资源分数代替实际面积。
