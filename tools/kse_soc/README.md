# KSE SoC 综合与功耗

输出默认放在 `run/soc`，不提交数据库、网表、活动文件或工具日志。

## 资源限制（严格优化轮）

启动重任务前检查 `grep MemAvailable /proc/meminfo`，至少18GB可用再启动。DC/PrimePower的完整SoC会话含子进程峰值约11.3GB，使用16G上限；VCS使用10G。全部禁止swap，DC仍保持 `set_host_options -max_cores 2`。

```bash
# DC / PT / PrimePower：一次一个，与VCS编译和仿真互斥
systemd-run --user --scope -p MemoryMax=16G -p MemorySwapMax=0 <command>
# VCS编译 / simv：最多两个重任务（包含回归脚本子进程）
systemd-run --user --scope -p MemoryMax=10G -p MemorySwapMax=0 <command>
```

下文命令均须置于上述scope中运行；回归及活动采集并行度至多2。FSDB转SAIF后立即删除。结束时检查本轮scope及工具进程均已退出。

交付默认R32×C32、PF128、SM/LN各8 lanes。复现16 lanes对照：综合用 `KSE_LANES16=1`，SoC VCS用 `+define+KSE_LANES16`；旧的 `KSE_LANES8` 命令仍与默认8 lanes一致。通过wrapper显式传播参数，不使用会被实例参数覆盖的模块默认值 `-pvalue+kse_top.*`。

R16独立候选保留供复现，因实测评分下降而未采用：综合同时设置 `KSE_ARRAY_R16=1 KSE_LANES16=1`，SoC VCS同时用 `+define+KSE_ARRAY_R16 +define+KSE_LANES16`；数据生成用 `KSE_ARRAY_R=16 kse_soc_sim.sh data`。引擎TB显式用 `-pvalue+tb_kse_top.ARRAY_R=16 -pvalue+tb_kse_top.SM_LANES=16 -pvalue+tb_kse_top.LN_LANES=16`。R16仍为79008参数字，C32下展平权重顺序不变。

## 完整 SoC 综合

`KSE_REPO` 指向仓库，`KSE_SYN_FILES` 是绝对路径、一行一个源文件的列表（沿用 `kse_soc_sim.sh` 的完整 SoC 源集合，排除 testbench 和功能 SRAM 模型，宏从 DB 解析）。
在新的输出目录中运行：

```bash
KSE_REPO=<repo> KSE_SYN_FILES=<files.txt> KSE_SAIF=<soc_12win.saif> \
  dc_shell -no_home_init -f <repo>/tools/kse_soc/synth_soc.tcl > dc.log 2>&1
```

必须检查 `SYN_DONE`、所有 Error、link/check_design、latch 清单、setup/hold 报告，不能仅凭退出码判断。严格方案只有一个32-bit SRAM从口及一个上游仲裁器；报告时保守纳入整个 PLIC 的时序端点。E203 独立成组。计分面积排除共享SRAM和固定平台，包含引擎、包装/DMA、新总线及PLIC新增源增量；整SoC功耗仍全部计入。

## 12 个计分窗口活动

```bash
tools/kse_soc/kse_soc_sim.sh fw
KSE_VCS_OPTS="+define+KSE_FSDB -debug_access+r" tools/kse_soc/kse_soc_sim.sh build fsdb
KSE_ACT_DIR=<new-activity-dir> tools/kse_soc/act12.sh 2
```

`act12.sh` 以 6.667 ns 周期运行每个任务，在计分窗口内 dump FSDB，转换后逐信号累加 SAIF 的 T0/T1/TX/TC/IG 和 DURATION。`-flatten_genhier` 必不可少：缺少它会丢失 generate 块前缀，同一作用域出现重复信号名，导致共享 SRAM/TCM 输出无法正确反标。不能把“有活动值”当作“直接由 SAIF 标注”。RTL 流水改变时必须重建活动，不能使用旧周期数或旧 SAIF。

## PrimePower

```bash
tools/kse_soc/run_power.sh <synthesis-dir> <soc_12win.saif> <new-power-dir>
python3 tools/kse_soc/summarize_power.py <new-power-dir> <SAIF-duration-ns> > <new-power-dir>/summary.json
```

三个默认翻转率（0.1、0、0.2）各启动一个独立 `pt_shell`，串行使用 license；不能在同一会话仅修改变量并 `update_power`，因为传播活动可能缓存。参考时钟为最快时钟，默认静态概率 0.5。`SYNOPSYS_LC_ROOT` 只在此脚本环境中设置。

- `power_components.tsv`：W，internal/switching/leakage/total，含整个 SoC、CPU 子树、引擎、包装子树、共享存储子树及每个 SRAM 宏。
- `macro_activity.tsv`：每个 SRAM 宏输入/输出引脚的翻转率及来源。`switching_after_update.rpt` 的 Memory 行仅统计宏输出驱动的网络。
- `default_cells.tsv`：触及默认活动网络的单元功耗小计；这是明确定义的单元集合，不能解释为默认活动造成的因果功耗。0/0.2 独立会话之差反映对默认翻转率的敏感性。
- `timing_metrics.tsv`：路径组 × 发起时钟 × setup/hold 的最差路径，完整路径见相应 timing 报告。NA/无路径不能当作 0 ns。
- `inputs.sha256`：网表、约束、映射和 SAIF 的来源校验。

平均功耗为 12 个完整窗口的加权平均。单任务能耗 = 平均功耗 × SAIF 实际总时长 / 12。所有宏使用 Liberty 功耗；没有布线寄生，不能称为布线后签核。

若要检查正裕量路径的完整单元链，另在新目录中运行（串行等待功耗会话结束）：

```bash
KSE_NETLIST=<mapped.v> KSE_SDC=<mapped.sdc> \
  pt_shell -f <repo>/tools/kse_soc/timing_soc.tcl < /dev/null > pt.log 2>&1
```

检查 `TIMING_AUDIT_DONE`。该脚本显式放宽报告的 slack 筛选阈值（不修改时序约束），保留 9 位小数，并额外报告被禁用的时序弧。

## 无旁路加载器（最终方案）

SoC 加载器边界只有十个 32 位 ICB 命令/响应信号。进度通过同一个主口写
0x4008_0000(BASE/INIT)、0x4008_0004(WPTR)、0x4008_0008(DONE)。
每次发布先等覆盖数据的全部响应。默认1024字发布一次；用 `+PUBLISH_WORDS=256`
可复现对照（164338拍，对比1024字的163328拍）。全部门铃计入窗口。
`make_e203_copies.py --check` 检查端口封闭集合及生成副本。

负向测试用 `+NEG_EARLY_DOORBELL +NTASK=1`，经真实ICB发布超前门铃，日志必须
出现 `ERROR early doorbell` 及 `TEST FAILED`，不能当作正常回归PASS。
12任务仍检查6336字节、逐字DMA读覆盖/实际已写数据、每拍至多一笔和全部原判据。
活动可用同一FSDB构建完成12任务回归；每窗口转换SAIF后删除FSDB。

面积须计入新增 `u_shram/u_progress` 及 `u_shram` 局部译码/响应胶合，不能因其位于
SRAM包装内而把进度逻辑算入共享SRAM豁免。固件和 `rtl/kse` 未改时无需重跑24×12。


## Portable library and simulation setup

Simulation uses the three local `tb/models` behavioral SRAM models by default.
Set `KSE_PDK_MODELS` to a space-separated list of user-supplied Verilog models
for all three macros to select `ARM_UD_MODEL` instead. No foundry files ship here.
The behavioral models zero-initialize memory for deterministic tests, implement
active-low CEN/GWEN/bit WEN and register read data on the rising clock edge.
Tie-off and analog/timing behavior are not modeled.

Synthesis, power and timing require `SMIC40_STDCELL_DB`, `SMIC40_RAM128_DB`,
`SMIC40_RAM1024_DB`, and `SMIC40_RAM4096_DB` to point to licensed local libraries.
`run_power.sh` also requires `SYNOPSYS_LC_ROOT`. Set `RISCV_PREFIX` for firmware,
`KSE_RUN` / `KSE_SOC_RUN` for build output, `KSE_DATA` for converted vectors,
`KSE_GOLDEN` for raw exported golden data, and `KSE_PY` for a NumPy-enabled Python.
Bundled vectors contain two engine samples and two SoC tasks; default regression
sizes are two. Full data requires regeneration and explicit `KSE_SAMPLES=24`,
`KSE_TASKS=12`, and `KSE_SOC_SAMPLES=0,2,4,6,8,10,12,14,16,18,20,22`.
