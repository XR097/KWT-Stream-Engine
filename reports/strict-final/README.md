# strict-final 原始汇总报告

本目录收集 strict-final 阶段的汇总性原始输出，绝对路径、用户名、主机/IP 和 license 地址都换成了占位符。为了只保留汇总信息，下文“发布裁剪”一节列出的逐实例内容也删掉了。综合报告来自 DC，工艺角为 SMIC40 RVT TT 1.10 V、25 °C，目标时钟 150 MHz（周期约 6.667 ns）；功耗报告来自 PrimePower 的三种默认翻转率会话；sim 目录保存 KSE 单元、SoC 回归和负向检查的 VCS 日志。

## 关键数字

- SoC 总面积：3,541,626.496 um²（3.541626496 mm²）；计分面积 1,236,966.656 um²。
- 关键 setup slack（ns）：accel 0.010276，e203 0，core 0.580132，slow 105.574478，jtag 1.325920；各组 TNS 均为 0，hold 均非负。
- 三个 PrimePower 会话（tr_0.0、tr_0.1、tr_0.2）均为 123.405948 mW，internal/switching/leakage 分别为 85.332829/37.613307/0.459813 mW；每任务能耗 134.377696 uJ。
- unit 与 unit_pdk 的四项检查通过；12 个 SoC 窗口均通过，单任务周期 163328、吞吐 918.397335 tasks/s。negative.log 保留提前门铃预期失败证据。

## 文件说明

- `syn/area.rpt`、`area_hier.rpt`、`qor.rpt`、`check_design.rpt`、`check_timing.rpt`、`clocks.rpt`、`constraints.rpt`、`latches.rpt`、`path_groups.rpt`、`metrics.txt`：DC 综合面积、层次面积、QoR、设计/时序检查、时钟约束和路径组汇总。`path_groups.rpt` 只保留路径组名、权重和范围，路径组端点展开不附带。
- `power/tr_0.x/`：每个翻转率会话的 PrimePower `power*.rpt`、层次/组件/引擎 TSV、切换汇总、全局时序、时序指标、约束检查和 `pt.log`。三组目录结构一致。
- `sim/`：unit、unit_pdk、grain 对照、负向/verify 日志，以及 12 个 SoC `sim.log`。
- `lint/`：SpyGlass `lint/lint_rtl` 的原始日志、工程文件 `lint.prj` 和 `moresimple.rpt`。顶层为 `kse_accel_sys`，读入 `rtl/kse`、`rtl/kse_soc`、三个 SRAM 行为模型，以及 E203 的 `sirv_gnrl_{icbs,bufs,dffs}.v`；设置 `mthresh 70000`、`handle_large_bus yes`，用来覆盖 32768 位的权重寄存器和 SRAM 阵列。结果为 0 fatal、2 error、546 warning：
  - `CombLoop`（`third-party/e203/.../sirv_gnrl_icbs.v:177`）：这是 E203 原版 `sirv_gnrl_icb_arbt` 内部 rspid FIFO 的 bypass/ready 结构环，KSE 没有修改这部分 E203 代码。全部仿真回归都通过了，说明在当前用法下这个环不会形成振荡。
  - `W123`（`tb/models/RAMSP4096X16_beh.sv:39`）：SRAM 行为模型的存储阵列太大，lint 没有处理。这只是仿真模型，综合时会换成实际的 SRAM 宏单元。

## 发布裁剪

- `syn/path_groups.rpt`：删除各路径组 `-to` 后面的端点列表，约 8.4 万行；时序环提示里的实例名也删掉了。
- `syn/latches.rpt`：删除逐实例的 Cell、Reference、Library 明细，只保留总数和总面积。15 个锁存器全部是 E203 的时钟门控使能。
- `power/tr_0.x/timing_metrics.tsv`：删除 startpoint 和 endpoint 两列，只保留各组的 slack。
- `power/tr_0.x/power_components.tsv`：只保留 soc、cpu、engine、wrapper_and_engine、shared 五个汇总项，逐 SRAM 宏的功耗不附带。
- `power/tr_0.x/power_engine_hierarchy.tsv`：只保留引擎的七个一级模块（ldr、ln、mm、pf、sm、rsa、rsb）。
- `power/tr_0.x/{constraints,check_timing,switching_summary}.rpt` 和 `pt.log`：逐引脚、逐网络的条目合并成“<N instance/pin entries omitted>”。其中 `constraints.rpt` 的 max_capacitance 一项有 139 个引脚违例，最差约 -0.0015 pF。

所有附加文件均小于 10 MB。生成数据库、网表、约束/SAIF/FSDB、逐路径 setup/hold/accelerator 报告、宏活动明细、宏功耗报告、default_cells、refs、工具工作目录均未附加。

## 路径组汇总（与 `strict_final/report.md` 核对）

|组|setup WNS (ns)|hold WNS (ns)|TNS (ns)|
|---|---:|---:|---:|
|accel|0.010276|0.013870|0|
|e203|0|0.026240|0|
|core|0.580132|0.040273|0|
|slow|105.574478|0.040545|0|
|jtag|1.325920|0.065244|0|

## 脱敏和扫描

附加文件中 `<PDK>/...`、工作区路径、用户、主机/IP 和 license 地址均已替换为 `<PDK>`、`<WORK>`、`<USER>`、`<HOST>`、`<LICENSE>`。对附加文件逐字节扫描未发现黑名单命中，也未发现 SoC 层次中的相关名称；未发现 PDK/ARM 保密声明或版权声明。原始文件中发现的库文件路径只以 `<PDK>` 占位符保留。
