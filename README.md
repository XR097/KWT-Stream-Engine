# KSE：KWT-1 关键词识别推理引擎与 SoC

KSE（KWT Stream Engine）是面向 **KWT-1 关键词识别 Transformer** 的固定功能 W4A8 推理引擎，
以及一个基于 **E203 (RV32IMAC)** 的 SoC 集成。目标工艺为 **SMIC 40LL RVT**，工作频率 150 MHz。
仓库包含引擎 RTL、SoC 集成、测试平台、固件、工具脚本、量化流程、设计文档，
以 Apache License 2.0 发布。

## 项目简介

- **模型**：KWT-1，12 层编码器，输入 99 个 token × 64 维，单头注意力，FFN 64→256→64，
  输出 12 类关键词；使用 Google Speech Commands 数据集。
- **引擎**：只适配该模型的固定功能数据通路，没有可编程命令流和架构寄存器堆；
  1024 个 s9×s8 乘法器、权重驻留/激活流式、32 字节行存储、参数预取 FIFO，
  Softmax / LayerNorm / GELU 全部为整数实现。
- **数值**：A8、W4（逐通道 2 的幂尺度）、MAC 24 位、Softmax Q15/P7、LayerNorm Q12/Q12、
  GELU middle ROM。
- **SoC**：E203 + 512 KiB 共享 SRAM + KSE；共享 SRAM 是 System Bus 上一个 32 位 ICB
  单口从设备，由一个上游 ICB 仲裁器合并 CPU、参数加载器和 NPU DMA。
- **工艺**：SMIC 40LL RVT，`tt_typical_max` 1.10 V / 25 °C，150 MHz。

## 关键结果

以下为最终 `strict-final` 配置（R32×C32、PF128、SM/LN 8 路）的实测结果。PPA 为 SMIC40
RVT TT 1.10 V / 25 °C、150 MHz、理想时钟、布线前、无 SPEF 的估算，不是物理签核。

| 指标 | 结果 |
|---|---:|
| 每任务周期 | **163328** |
| 吞吐 @150 MHz | **918.397335 tasks/s** |
| 整 SoC 面积 | 3.541626496 mm² |
| 计分面积 | **1.236966656 mm²**（上限 2.25 mm²） |
| 整 SoC 功耗 | **123.405948 mW** |
| 单任务能耗 | **134.377696 µJ** |
| 加速器 setup / hold | **+0.0102758 / +0.0138704 ns** |
| 12 任务 SoC 回归 | 12/12 PASS，每任务 6336 字节输出逐字节一致，0 失配 |
| 24 样本 × 12 层引擎回归 | 40468032 项逐位一致，0 失配 |

精度（全 W4 冻结方案，本地测量）：验证集 4445 条 Top-1 **97.2778%**，测试集 4890 条
**96.9734%**，固定 600 条 **97.3333%**；同口径 FP32 测试集为 97.6074%，下降约 0.63 个百分点。
官方评测集尚未公布，本地结果不替代官方验收。

## 目录结构

```text
rtl/kse/                 KSE 引擎 RTL（阵列、行存储、预取、加载器、非线性单元、顶层）
rtl/kse_soc/             E203 SoC 集成（总线仲裁、共享 SRAM、DMA/MMIO 包装、E203 工程副本）
tb/kse/                  引擎单元与顶层测试平台
tb/kse_soc/              SoC、共享 SRAM、仲裁与契约测试平台
tb/models/               RAMSP128X16 / RAMSP1024X16 / RAMSP4096X16 行为模型
tools/kse/               参数打包、ROM 生成、测试向量、仿真入口、综合脚本
tools/kse_soc/           SoC 仿真、数据生成、E203 副本生成、综合/功耗/时序脚本
firmware/kse/            E203 固件（逐层命令、WFI、PLIC 中断）
quantization/            W4/W8 数值实验、量化、golden 导出与测试
data/vectors/            小样本测试向量（输入、输出、逐层 trace）
docs/arch/               微架构说明
docs/spec/               引擎、SoC、共享 SRAM 规格
docs/quantization/       量化环境、数值实验与结果
docs/history.md          版本演进与各版实测数字
report/                  设计报告源稿（Markdown、图源）、构建脚本与 PDF
reports/strict-final/    strict-final 综合、功耗、仿真与 lint 的原始汇总报告
verification/uvm/        KSE UVM 验证环境（运行脚本在 tools/verif_tool/vcs）
scripts/compile_check.sh 只编译、不运行的全局编译检查
third-party/e203         E203 (hbirdv2) 子模块
third-party/kwt          ARM keyword-transformer 子模块（KWT 模型与 checkpoint）
```

仿真与综合的输出统一写到 `run/`（已被 `.gitignore` 忽略），不写回源码目录。

## 快速开始

### 1. 获取代码与子模块

```bash
git clone <repository-url> kse
cd kse
git submodule update --init third-party/e203 third-party/kwt
```

如果只跑 RTL 仿真，`third-party/e203` 是必需的；量化流程另需 `third-party/kwt` 中的
KWT-1 checkpoint。

### 2. 环境要求

- `bash`、Python 3（工具与量化流程）
- VCS（`vcs -full64`，RTL 编译与仿真）
- RISC-V GCC（默认 `riscv-none-elf-`，可用 `RISCV_PREFIX` 覆盖）
- 可选：Design Compiler / PrimeTime / PrimePower（综合、时序、功耗）
- 量化：Python 3.8 + TensorFlow 2.4.0，环境文件见 `quantization/environment/`

### 3. 全局编译检查

```bash
./scripts/compile_check.sh
```

脚本只编译引擎单元、引擎顶层、SoC、共享 SRAM 单元测试、UVM 顶层和固件，并做 Python 语法检查，
不执行生成的仿真二进制，不产生波形。需要 VCS 和 RISC-V GCC。含 FSDB 调用的 UVM 顶层需要设置 `VERDI_HOME`，未设置时这几项输出 SKIP；`tb_kse_soc_uvm` 通过后门访问厂商 SRAM 宏模型的内部阵列，只在 `KSE_PDK_MODELS=1` 时编译。

### 4. 引擎仿真

仓库自带小样本测试向量，可直接运行：

```bash
tools/kse/kse_sim.sh data            # 检查自带向量（或按 KSE_GOLDEN 重新生成）
tools/kse/kse_sim.sh units           # 4 个单元测试
KSE_SAMPLES=24 tools/kse/kse_sim.sh network net 4   # 24 样本 × 12 层，4 路并行
```

输出在 `run/kse/`（可用 `KSE_RUN` 改到其他目录）。如需从完整 golden 重新生成向量，设置 `KSE_GOLDEN=<golden-dir>`；
参数打包器为 `tools/kse/pack_params.py`，ROM 生成器为 `tools/kse/gen_roms.py`。

### 5. SoC 仿真

```bash
tools/kse_soc/kse_soc_sim.sh fw          # 编译固件
KSE_SOC_SAMPLES=0,2,4,6,8,10,12,14,16,18,20,22 \
  tools/kse_soc/kse_soc_sim.sh data      # 生成参数流与 12 个任务的装载镜像
KSE_TASKS=12 tools/kse_soc/kse_soc_sim.sh regress v1 4  # 12 任务回归
```

输出在 `run/soc/`（可用 `KSE_SOC_RUN` 改到其他目录）。12 任务回归的通过判据是 FLAG_DONE
为通过码、每任务 6336 字节输出逐字节一致、DMA 读写覆盖正确、加载器写指针逐笔复核、
单口/仲裁断言无违反。

共享 SRAM 单元测试：

```bash
KSE_SRAM_RUN=$PWD/run/shared_sram_beh ./tb/kse_soc/run_shared_sram.sh
```

### 6. 量化流程

```bash
conda env create -f quantization/environment/kwt-quant-environment.yml
conda activate kwt-quant
python -B -m pytest quantization/tests -q
python -B -m quantization prepare --data-root kwt-data
```

W4/W8 混合与非线性联合实验：

```bash
python -B -m quantization experiment --data-root kwt-data --repo-root . --workers 4 --stage all --resume
```

ASIC 数值方案实验：

```bash
python -B quantization/scripts/run_asic_numerics.py \
  --data-root kwt-data --repo-root . --reference-root third-party/kwt --workers 12 --resume
```

环境、数据准备、各阶段产物与结果解释见 `docs/quantization/`。

### 7. 设计报告与验证材料

- 设计报告：[report/build/设计报告初稿.pdf](report/build/设计报告初稿.pdf)。源稿在 `report/draft/`，构建方法见 [report/README.md](report/README.md)。
- 原始汇总报告：[reports/strict-final/](reports/strict-final/README.md)，包括 DC 面积、QoR 和时序检查，三种翻转率下的 PrimePower 功耗，单元和 SoC 回归的 VCS 日志，以及 SpyGlass lint。为了只保留汇总信息，逐实例的路径、库单元和逐宏功耗明细已经删去，README 里列出了删掉的内容。
- UVM 验证环境：[verification/README.md](verification/README.md)。覆盖率数字见设计报告第 4.4 节。

### 8. 综合、时序与功耗（可选）

综合与功耗脚本需要用户自备 SMIC40 库，通过环境变量指定（仓库不附带 `.lib` / `.db`）：

```bash
export SMIC40_STDCELL_DB=/path/to/smic40ll_rvt_tt_1p10v_25c.db
export SMIC40_RAM128_DB=/path/to/RAMSP128X16_tt_1p10v_25c.db
export SMIC40_RAM1024_DB=/path/to/RAMSP1024X16_tt_1p10v_25c.db
export SMIC40_RAM4096_DB=/path/to/RAMSP4096X16_tt_1p10v_25c.db

# 引擎综合
KSE_REPO=$PWD dc_shell -no_home_init -f tools/kse/synth_kse.tcl
```

完整 SoC 综合、12 窗口活动采集、PrimePower 与 STA 的入口和资源限制见
`tools/kse_soc/README.md`。

## PDK 与第三方依赖说明

- 本仓库**不包含**任何厂商 PDK、标准单元库、SRAM `.lib`/`.db`/`.lef`/`.gds` 或网表。
  仿真默认使用 `tb/models/` 下自写的行为模型，行为模型只用于功能验证，不代表真实时序、
  面积或功耗。
- 综合、时序和功耗需要用户自备有许可证的 SMIC 40LL 库，并按上一节设置
  `SMIC40_STDCELL_DB`、`SMIC40_RAM128_DB`、`SMIC40_RAM1024_DB`、`SMIC40_RAM4096_DB`。
- 如要用厂商 SRAM 模型做仿真，设置 `KSE_PDK_MODELS`（引擎/SoC 仿真）或 `PDK_SRAM_V`
  （共享 SRAM 单元测试），并自行确认模型许可。
- `third-party/e203` 和 `third-party/kwt` 通过 git submodule 引入，分别遵循其上游
  Apache-2.0 许可证；KWT-1 checkpoint 来自 `third-party/kwt`。
- 数据集不随仓库分发；量化脚本可按 `docs/quantization/quant_environment.md` 的说明
  下载并校验 Google Speech Commands。

## 许可证

本项目以 **Apache License 2.0** 发布，全文见 [LICENSE](LICENSE)。第三方组件与数据集的
归属声明见 [NOTICE](NOTICE)：

- E203 (hbirdv2)：Apache-2.0
- ARM keyword-transformer（KWT 模型）：Apache-2.0
- Google Speech Commands 数据集：CC BY 4.0

## 文档索引

| 文档 | 内容 |
|---|---|
| [docs/arch/kse-microarch.md](docs/arch/kse-microarch.md) | KSE 微架构、数据流、数值单元与最终结果 |
| [docs/spec/kse_top.md](docs/spec/kse_top.md) | 引擎顶层接口、参数流格式、行存储与调度 |
| [docs/spec/kse_soc.md](docs/spec/kse_soc.md) | E203 SoC 结构、地址映射、MMIO、DMA、固件与验证 |
| [docs/spec/kse_shared_sram.md](docs/spec/kse_shared_sram.md) | 共享 SRAM 单口从设备、仲裁、门铃与单元测试 |
| [docs/history.md](docs/history.md) | 各版本的关键改动与实测 PPA |
| [docs/quantization/](docs/quantization/) | 量化环境、数值实验与结果 |
| [report/](report/README.md) | 设计报告源稿、图与 PDF |
| [reports/strict-final/](reports/strict-final/README.md) | 综合、功耗、仿真和 lint 的原始汇总报告 |
| [verification/](verification/README.md) | UVM 验证环境 |
