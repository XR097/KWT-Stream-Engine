# KWT-1 ASIC 数值方案实验计划

依据：任务书《量化任务书：为 KWT-1 固定功能 ASIC 选定数值方案》（下称“任务书”，节号沿用任务书）。
结论与数据写入 `docs/quantization/asic_numerics_report.md`，本文只规定做什么、怎么判。

## 0. 环境与目录

| 项目 | 取值 |
|---|---|
| Python | `kwt-quant` 环境（3.8.18 / TF 2.4.0 / NumPy 1.19.5），路径由调用者通过环境或命令行指定 |
| CPU | 整数评估按机器核数并行，每进程 BLAS 1 线程，`CUDA_VISIBLE_DEVICES=-1` |
| 数据根 | `kwt-data`（可用 `KWT_DATA_ROOT` 或 `--data-root` 改到其他磁盘） |
| 新结果 | `<数据根>/experiments/asic_numerics_v1/`；已有目录和缓存只读 |

已有可复用资产：`cache/{training,validation,testing}.npz`、`experiments/w4w8_nonlinear_v1/cache/validation_full*.npz`（4445 条完整验证）、`metadata.json` 中的 golden / 600 条固定索引。

## 1. 统一口径（任务书 5.1）

- 数据划分：采用仓库的确定性划分（`reference.py` 对 WAV 列表排序）。先核对现有 `testing.npz` 与 4445 条完整验证是否与确定性划分逐条一致。不一致时，在 `asic_numerics_v1/cache/` 下重新生成，旧缓存不动，报告中写明差异。
- 浮点参考：同一 checkpoint、同一浮点分类头。验证 4445、测试 4890、600 条检查集（沿用 `audit_final_mixed.py` 的每类 50 条固定索引；若索引定义在旧测试缓存上，按同一规则在新测试缓存上重取并记录）。
- 三个配置 × 三个口径：FP32、冻结配置 `all_w4_q15_p7_ln12`、全 W8A8（非线性同冻结配置）。

## 2. 代价模型与目标函数

- 全 W4 基准每层 6992 字（权重 6144、int32 bias 576、其他 272），全模型 83904 字。
- 矩阵改 W8，权重字数翻倍：q/k/v/proj 各 +512，fc1/fc2 各 +2048。`Δ% = 额外字数 / 83904 × 100`。
- 精度分 `A = min(10, 10 − drop_val/0.2)`，`drop_val = FP32_val − quant_val`（百分点）。
- 目标 `J = A − 0.2 × Δ%`。只在验证集上计算和选择。
- 合格：测试集 drop < 2 pp；所有矩阵 MAC 前缀部分和、加 bias 后和 ≤ 24 位有符号；无溢出；输出有限。

## 3. 代码改造（一次改完，之后冻结源码再跑长实验）

1. 累加器 24 位：受检算术支持 `accumulator_bits=24`，前缀部分和与 bias 和超过 24 位即判失败；每矩阵记录实测最大位宽。
2. Softmax P8：新增 `prob_frac=8`，u8 存储，1.0 饱和到 255；P·V 重定标同步。P11 保留为对照，标注需要两遍。
3. 位宽报告：逐层 bias 范围/位宽、逐通道移位码范围、LayerNorm 归一化商和仿射乘积位宽（商需 ≤ 17 位有符号）、Softmax 指数/分母/分子/商位宽。
4. 新驱动脚本（建议 `quantization/scripts/run_asic_numerics.py` + `.ps1` 入口），复用现有评估、前缀缓存和 `--resume` 进度机制，按阶段执行：`baseline / single / greedy / structure / nonlinear / final / stats / golden / report`。
5. 为新增功能补单元测试；`python -B -m pytest quantization/tests -q` 全部通过。

## 4. 实验矩阵

| 阶段 | 内容 | 规模（4445 条验证） |
|---|---|---|
| single | 72 个矩阵各自单独改 W8，记录 Δacc 与 Δ字数 | 72 配置 |
| greedy | 按 Δacc/千字降序依次加入 W8 矩阵，每个点实测组合；Δacc ≤ 0 的矩阵不加入；当 J 连续 4 点不升或 Δ% > 40% 时停止 | ≤ 30 点 |
| structure | 按层整层 W8（12 个）；按类型 W8：q+k、v、proj、fc1、fc2、全注意力、全 FFN；再试“对 J 贡献为正的层/类型”的并集 | ≈ 20 配置 |
| nonlinear | 取 3 个代表点（J 最优、Δ% ≤ 5% 中 J 最优、精度最高）。Softmax P7/P8/P11；LayerNorm norm/gamma 12/12、16/16、20/16、16/12、20/20；GELU direct 与 middle 逐位核对 | 3 × ≈ 8 |
| final | 选出 2–3 个推荐方案，测试集 4890 与 600 条各跑一次，不再回调 | 3 配置 |

推荐方案：(a) J 最优；(b) Δ% ≤ 5% 的 J 最优；(c) 满足约束的验证集精度最高者。
曲线上的每个点（不仅推荐方案）都补测测试集和 600 条，便于报告；这些测试结果不参与选择。

## 5. 统计与交付（任务书 5.4、7）

- 压缩统计：W4 值分布、逐矩阵经验熵和 64 元素块熵、按熵估计的可省字数；冻结方案每层/全模型字节数（W4 紧密打包、bias 按实际位宽、其他参数）。
- 600 条波动：在测试集 4890 条上做 bootstrap（10000 次，固定种子）抽 600 条，给出各推荐方案相对 FP32 下降量的分布（均值、标准差、5/50/95 分位、超过 2 pp 的概率），并给出固定 600 条的实测值。
- golden：每个推荐方案导出 profile v3、24 条逐层 trace、算子边界向量；由 `export_sim_golden.py` 导出 sim_manifest，再由整数参考模型逐位核验。
- 汇总：`asic_numerics_v1/summary.json`；报告 `docs/quantization/asic_numerics_report.md`（中文，结论表在前）。

## 6. 规则

- 测试集只用于确认；不训练、不微调；不改 `third-party/`；`kwt-data/` 不进 git。
- 做不了或结果异常的项目写明原因和现状，不用估计值代替实测值。
