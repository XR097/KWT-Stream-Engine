# KSE 共享 SRAM 规格说明书（严格单口方案）

> 文档状态：Final
> 版本：v1.1（严格总线门铃方案）
> 日期：2026-11-13
> 关联 RTL：`rtl/kse_soc/kse_shared_sram.sv`、`rtl/kse_soc/kse_sram_ctrl.sv`、
> `rtl/kse_soc/kse_sys_bus.sv`、`rtl/kse_soc/kse_accel_sys.sv`
> 关联验证：`tb/kse_soc/tb_shared_sram.sv`、`tb/kse_soc/tb_sram_priority.sv`、
> `tb/kse_soc/tb_sram_restart.sv`、`tb/kse_soc/tb_sram_prio_contract.sv`、`tb/kse_soc/tb_kse_soc.sv`
> 依据：`docs/arch/kse-microarch.md` 共享 SRAM 与加载器一节、赛题指南第 3–4 页、E203 上游
> `third-party/e203/rtl/e203/general/sirv_gnrl_icbs.v`、`sirv_1cyc_sram_ctrl.v`

## 1. 文档说明

### 1.1 目的

本文定义严格总线方案下的 512 KB 共享 SRAM 子系统：

- 共享 SRAM 是 System Bus 上**一个** 32 位 ICB 从设备，地址
  `0x4000_0000..0x4007_FFFF`，每拍至多一笔事务；
- SRAM 从设备之前**只有一个** ICB 仲裁器，合并三个主设备：CPU（E203 BIU 的
  O5 mem 通路）、参数加载器、NPU DMA；
- 不存在 3×2 交叉开关、两 bank 并行、DMA 私有口或第二个 SRAM 端口。
  64 个 `RAMSP4096X16` 宏在内部组织成一个平坦的 128K×32 单口阵列。

### 1.2 范围

覆盖：ICB 从口时序、地址到宏的映射、三主口到单从口的仲裁、加载器写指针的
发布和 MMIO 读出、宏的仿真替换开关、单元测试和 SoC 级断言。

不覆盖：SoC 级地址译码（E203 `e203_subsys_mems` 的 O5 区域译码）、ECC/奇偶
校验、时钟门控和低功耗策略、加速器 DMA 的描述符格式。

### 1.3 术语

| 缩写 | 全称 | 说明 |
|---|---|---|
| ICB | Internal Chip Bus | E203 的片上命令/响应总线，valid/ready 握手 |
| 宏（macro） | RAMSP4096X16 | SMIC 40LL 单口 SRAM，4096×16，一拍读 |
| 组（group） | — | 一组并排的低/高 16 位宏，合起来是 4096×32 字 |
| 写指针 | loader_wptr | 加载器已提交到 SRAM 的字之后的字节地址 |
| REL_LAG | release lag | 放行规则中写指针之后额外要求的字节滞后，严格方案默认 0 |

## 2. 功能概述

共享 SRAM 是一个普通 System Bus 从设备。物理上 64 个 `RAMSP4096X16` 宏组成
32 个 4096×32 的组，合计 128K 字（512 KB）；逻辑上是一个 32 位、一拍读、
每拍至多一笔的单口从设备。三个主设备经同一个 ICB 仲裁器访问它：

- 主设备 0：CPU memory 通路（E203 BIU O5，`0x4000_0000`）；
- 主设备 1：参数加载器（测试平台 ICB 主设备，按顺序写参数镜像）；
- 主设备 2：NPU DMA（`kse_eng_icb` 的流式 DMA，读参数/输入、写输出）。

```text
 NPU DMA (m0)    ──┐
 参数加载器 (m1) ──┼──> kse_sys_bus（一个 sirv_gnrl_icb_arbt，3→1）
 CPU O5 mem (m2) ──┘         │
                             │ 单个 32 位 ICB 从口
                             v
                    kse_shared_sram（1 个控制器 + 32 组 × 2 宏）
                             │
                    64 × RAMSP4096X16（128K × 32，512 KB）
```

每一拍的性质：

- 从口最多接受一笔命令（`cmd_valid && cmd_ready` ≤ 1）；
- 整个宏阵列最多选中一个组（`grp_sel` 最多一位为 1），即最多访问一个
  32 位字（一个低/高 16 位宏对）；
- 同一拍不可能有两个主设备的数据通路同时写/读不同地址；
- 读命令在握手后下一拍返回数据，写命令在握手沿写入宏。

这与上游 `sirv_sram_icb_ctrl` / `sirv_1cyc_sram_ctrl`（`CUT_READY=0`）的
持续吞吐和空载读延迟一致。

## 3. 接口

### 3.1 时钟和复位

| 信号 | 方向 | 位宽 | 有效电平 | 说明 |
|---|---|---:|---|---|
| `clk` | I | 1 | 上升沿 | 单一时钟域（hfclk） |
| `rst_n` | I | 1 | 低 | 异步复位，同步释放由外部保证 |

复位期间响应 valid 为 0，`loader_wptr`/`loader_base` 为 0，
`loader_wptr_valid` 为 0，选组寄存器为 0。

### 3.2 从口 ICB（`cmd_*` / `rsp_*`）

| 信号 | 方向 | 位宽 | 描述 |
|---|---|---:|---|
| `cmd_valid` | I | 1 | 命令有效，主口在 `cmd_ready` 前必须保持稳定 |
| `cmd_ready` | O | 1 | 本拍可接收命令，`= ~rsp_valid | rsp_ready` |
| `cmd_addr` | I | 32 | SRAM 全地址/窗口内偏移，或完整门铃地址 |
| `cmd_read` | I | 1 | 1=读，0=写 |
| `cmd_wdata` | I | 32 | 写数据 |
| `cmd_wmask` | I | 4 | 字节写使能，高有效；读时忽略 |
| `rsp_valid` | O | 1 | 响应有效 |
| `rsp_ready` | I | 1 | 主口接收响应 |
| `rsp_rdata` | O | 32 | 读数据；写响应的值无定义 |
| `rsp_err` | O | 1 | SRAM 正常访问为 0；非法门铃/未映射地址为 1 |

握手规则：

- 命令在 `cmd_valid && cmd_ready` 的时钟沿生效；从口每拍至多一笔。
- 同步读，命令握手后下一拍 `rsp_valid` 有效，`rsp_rdata` 即该命令的数据。
- 响应被消费的同一拍可以接收新命令（无气泡，持续 1 字/拍）。
- 从口最多一笔未完成命令；`cmd_ready` 在有未消费响应时为 0，除非该响应
  本拍被消费。
- 写命令同样产生一拍响应，主口必须消费。

### 3.3 经 System Bus 发布加载进度

加载器与 SoC 边界仅有 32 位 ICB 命令/响应端口，全部非 ICB 进度输入已删除。
仲裁器后的 `kse_shared_sram` 在同一从口译码两个逻辑目标：512 KiB SRAM 和
`kse_load_progress`，后者只保存进度，不承载输入/参数数据。

| 地址 | 寄存器 | 读写语义 |
|---|---|---|
| 0x4008_0000 | BASE/INIT | 写 base，同时 WPTR=base、VALID=1、DONE=0 |
| 0x4008_0004 | WPTR | 写排他上界（字节地址），不改变 BASE/VALID/DONE |
| 0x4008_0008 | STATUS/DONE | 写 bit0=DONE；读 bit1=VALID、bit0=DONE |

门铃只接受对齐的 32 位全字写；0x4008_000C、非对齐/非全字门铃写、译码窗口
其余地址返回错误，不触发 SRAM 宏。响应一拍、支持反压，门铃与数据不能同拍各占一笔。
复位清除 BASE/WPTR/VALID/DONE。重新装载前须使上次 DMA 排空；BASE 提交后新间隔为空。

`loader_base/wptr/wptr_valid/done` 均为片内寄存器输出，仅送引擎；加载器没有
片外旁路。保留的 `wptr_rd_*` 是片内/单元测试观察口，不与加载器相连。
门铃覆盖数据的正确性由加载器顺序协议保障，硬件不保存逐字写历史；TB独立逐笔核验。

## 4. 地址映射

### 4.1 总体地址

共享 SRAM 在 SoC 中的窗口沿用平台工程：基地址 `0x4000_0000`，大小 512 KB
（`0x4000_0000..0x4007_FFFF`）。SRAM数据地址支持完整地址或**窗口内偏移**
（`0x00000..0x7FFFF`）。O5 译码为1 MiB以覆盖门铃；本模块进一步译码SRAM/门铃，
未映射地址返回错误。SRAM实际容量仍512 KiB。

| 偏移区间 | 资源 | 访问方式 |
|---|---|---|
| `0x00000..0x3FFFF` | 参数流区（256 KB），加载器写入、DMA 顺序读 | 读/写 |
| `0x40000..0x7FFFF` | CPU 数据区（256 KB） | 读/写 |

### 4.2 平坦宏组织（无 bank、无条带交织）

```text
word  = addr[18:2]          // 128K 字地址
group = word[16:12]         // 0..31，选 32 组中的一组
ma    = word[11:0]          // 组内宏字地址，0..4095
low   = 宏 u_ram_lo[ma]     // 32 位字的 [15:0]
high  = 宏 u_ram_hi[ma]     // 32 位字的 [31:16]
```

每个组覆盖 4096 字 = 16 KB，32 组连续覆盖 512 KB：

| 偏移 | 组 | 偏移 | 组 |
|---|---:|---|---:|
| `0x00000..0x03FFF` | 0 | `0x40000..0x43FFF` | 16 |
| `0x04000..0x07FFF` | 1 | `0x44000..0x47FFF` | 17 |
| … | … | … | … |
| `0x3C000..0x3FFFF` | 15 | `0x7C000..0x7FFFF` | 31 |

同一拍只有一个组 `CEN=0`；组内两个宏（低/高 16 位）同时输出/写入，拼成
32 位字。没有 `addr[12]` 分 bank，也没有相邻条带并行。

### 4.3 宏控制信号

- 读：`GWEN=1`，选中组两个宏同时输出，拼成 32 位。
- 写：`GWEN=0`，`WEN[15:0]` 按 ICB 字节掩码逐位取反：低宏
  `WEN={{8{~wmask[1]}},{8{~wmask[0]}}}`，高宏 `WEN={{8{~wmask[3]}},{8{~wmask[2]}}}`。
- `EMA=3'b010`（厂商默认值，与引擎内部宏一致）、`EMAW=2'b00`、`RET1N=1'b1` 固定。
- 响应组号在命令拍寄存（`grp_rsp_q`），保证背靠背访问不同组时读数据仍取自
  正确的组。

## 5. 时序

### 5.1 单笔读

```text
cycle        T        T+1       T+2
clk          ↑        ↑         ↑
cmd_valid    1        -         -
cmd_ready    1        -         -
cmd_addr     A        -         -
rsp_valid    0        1         0
rsp_rdata    -        Q(A)      -
```

命令在 T 拍握手，宏在 T 的时钟沿采样地址，Q 在 T+1 拍有效；控制器在 T 的
时钟沿把响应 valid 置 1，因此**一拍返回**。内部时序与上游
`sirv_1cyc_sram_ctrl`（`CUT_READY=0`）一致。

### 5.2 背靠背（无气泡）

```text
cycle        T          T+1          T+2
cmd_valid    1(A)       1(B)         ...
cmd_ready    1          1
rsp_valid    1(A-1)     1(A)         ...
```

T+1 拍同时发生“消费 A-1 的响应”和“接收 B 的命令”，因为
`cmd_ready = ~rsp_valid | rsp_ready`。持续供数时每拍一笔。

### 5.3 响应反压

```text
cycle        T        T+1      T+2      T+3
rsp_valid    0        1        1        1
rsp_ready    -        0        0        1
rsp_rdata    -        Q        Q        Q
cmd_ready    -        0        0        1
```

响应未被消费时 `cmd_ready=0`，宏 `CEN=1` 保持 Q 不变，因此响应数据在反压
期间稳定；消费响应的同一拍可以接收新命令。

### 5.4 写

写命令同样占用一拍，`ram_cs=1`、`ram_we=1`、选中组 `GWEN=0`、`WEN` 按字节
掩码有效，T+1 拍返回一笔响应（`rsp_rdata` 无意义）。写数据在 T 的时钟沿写入
宏。

## 6. 系统总线仲裁

### 6.1 结构

`kse_sys_bus` 例化 E203 上游的 `sirv_gnrl_icb_arbt`（只例化，不改
`third-party/` 源码），参数：

| 参数 | 值 | 说明 |
|---|---:|---|
| `AW` / `DW` | 32 / 32 | 32 位地址/数据 |
| `ARBT_NUM` | 3 | CPU、加载器、NPU DMA |
| `ARBT_PTR_W` | 2 | 3 个端口 |
| `ARBT_SCHEME` | 0 | 固定优先级（端口 0 最高） |
| `FIFO_OUTS_NUM` | 1 | 一个响应 ID 表项 |
| `FIFO_CUT_READY` | 0 | 组合 ready，允许无气泡吞吐 |
| `ALLOW_0CYCL_RSP` | 1 | 兼容 0 拍/1 拍响应 |

仲裁器输出一个从口命令/响应通道，直接接 `kse_shared_sram` 的唯一从口。
`rspid` 单表项意味着整个总线最多一笔未完成事务；由于从口一拍返回，响应被
消费的同一拍可以接收下一笔命令，因此持续吞吐仍是 1 字/拍（由单元测试和
SoC 回归实测验证）。

### 6.2 优先级与理由

默认映射（参数 `DMA_OVER_LOADER=1`）：

```text
端口 0（最高） = NPU DMA
端口 1         = 参数加载器
端口 2（最低） = CPU
```

选择固定优先级而不是轮询的理由：

1. **单口下总事务数固定。** 一个任务必须完成
   80592（加载器写）+ 80592（NPU DMA 读）+ 1584（输出写）+ 1（CPU 写
   FLAG_DONE）= 162769 笔从口事务；任何无空闲的仲裁策略都受同一下限约束，
   轮询不会增加总带宽。
2. **NPU DMA 必须先得到服务。** 引擎的参数/输入流一旦断供，MM 阶段停摆；
   让加载器与 DMA 各得 0.5 时，MM 阶段正好被拉长约一倍（实测见 6.5）。
   固定优先级让 DMA 在每个可读字上立即抢到从口，加载器只在 DMA 的请求
   空档和达到放行上界时使用剩余周期，因此引擎不会因为仲裁器主动让出而
   额外等待。
3. **加载器仍能前进。** DMA 读流有限、单调、不重复，并受写指针放行规则
   约束：DMA 最多读到 `wptr - REL_LAG`（REL_LAG=0 时就是已提交的最后一字）。
   DMA 把可读的字读完后必须停下，加载器随即得到从口；加载器每写一个字，
   最多再产生一个字给 DMA，因此最坏情况是 1:1 交替，加载器不会饿死。
4. **CPU 不会死锁。** 固件只在窗口开始前写 FLAG_START、在全部层完成且
   DMA 已排空后写 FLAG_DONE；这两个时刻加载器/DMA 都不占用从口。窗口内
   固件只访问 MMIO（PPI O12）和 PLIC，不访问共享 SRAM，因此 CPU 的最低
   优先级不影响功能，也不构成“CPU 等待 SRAM 才能让 DMA 前进”的环。

### 6.3 上游仲裁器与“轮询模式”的限制

上游 `sirv_gnrl_icb_arbt` 的 `ARBT_SCHEME=1`（轮询）会例化
`sirv_gnrl_rrobin`，但本仓库固定的 E203 上游快照（`5895d5bf`）里没有这个
模块。由于本任务规定不改 `third-party/`，严格方案的默认实现使用上游的
固定优先级模式；没有自写仲裁器，也没有修改上游源码。若后续需要轮询，
可以单独补充该缺失叶子模块并复测，但这不属于本方案的交付路径。

### 6.4 单口证明与断言

RTL 和测试平台共同检查以下不变式（`ifndef SYNTHESIS` 断言 + TB 计数器）：

- `kse_sram_bank`：`$countones(grp_sel) <= 1`，即每拍至多一个 32 位字
  （一个低/高宏对）被访问；
- `kse_sys_bus`：`$countones(m_cmd_valid & m_cmd_ready) <= 1`，且从口握手
  `sram_cmd_valid & sram_cmd_ready` 恰好等于“有且仅有一个主设备握手”；
- `kse_shared_sram`：从口在上一笔响应未消费时不得接受新命令；
- `tb_kse_soc`：上述每个条件在计分窗口内逐拍复核，任一违反都判
  `TEST FAILED`。

### 6.5 实测对比

12 任务 SoC 回归，同一固件/golden，三个变体各跑 12 任务（每任务结果逐字节
一致）：

| 变体 | 仲裁顺序 / REL_LAG | 窗口周期 | tasks/s | 相对默认 |
|---|---|---:|---:|---:|
| **默认（采用）** | DMA > loader > CPU，REL_LAG=0 | **163015** | **920.16** | — |
| 旧放行粒度 | DMA > loader > CPU，REL_LAG=4096 | 163182 | 919.22 | +0.10% |
| 加载器优先 | loader > DMA > CPU，REL_LAG=0 | 180358 | 831.68 | +10.64% |

数据来源：12 任务 SoC 回归的 `summary.log` 与各分片日志（`run/soc/`）。

结论：

- 默认策略达到单口事务下限（见第 11 节），窗口的 99.85% 周期从口在传输；
- REL_LAG 从 4 KB 降到 0 去掉的是旧两 bank 方案为相位分离付出的尾部追赶，
  严格方案下不需要，而且 0 滞后是更强的安全规则（只读已提交字）；
- 加载器优先会让引擎在整个装载期间拿不到参数，窗口显著变长，故不采用；
- 轮询模式因上游叶子缺失未作为交付实现；从总事务数下限和 1:1 交替分析，
  它不会优于默认优先级。

## 7. 宏模型与仿真替换

- 行为模型 `tb/kse_soc/RAMSP4096X16_beh.sv` 与 PDK 模型同端口名：`CLK`、
  `CEN`（低有效）、`WEN[15:0]`（逐位低有效）、`A[11:0]`、`D[15:0]`、
  `Q[15:0]`、`EMA[2:0]`、`EMAW[1:0]`、`GWEN`（低有效）、`RET1N`；一拍读延迟。
- `rtl/kse_soc/kse_shared_sram.sv` 用 `` `ifdef ARM_UD_MODEL `` 选择 PDK 的
  `RAMSP4096X16`，否则用行为模型。PDK 模型需要 `+define+ARM_UD_MODEL`
  （并建议 `+nospecify +notimingcheck`）。
- 行为模型把存储初始化为 0 便于仿真；真实宏没有复位，未写过的地址读出 X。
  单元测试在流式阶段前先用 CPU 主口把高 256 KB 清零，低 256 KB 由加载器
  镜像写入，两种模型都能通过。
- 32 个组共 64 个宏实例；每组只有被选中的一组两个宏 `CEN=0`；其它 62 个
  宏 `CEN=1`。

## 8. 参数加载器与写指针流控

`tb/kse_soc/kse_param_loader.sv` 是测试平台组件（不可综合）：

- 从 `$readmemh` 文件读入参数镜像（默认 `kse_sram_img.hex`，可用
  `+LOADER_IMAGE=<file>` 覆盖）；文件在仿真时间 0 由测试平台生成，组件在 #1
  读取。
- `start` 后从 `base_addr` 起按顺序写 `length` 个字，每拍最多一笔；
  `cmd_wmask=4'hF`。
- start 后先发 BASE/INIT 总线写；收齐响应后开始数据写。默认每 1024 字
  发布 WPTR（`+PUBLISH_WORDS=N` 可改），尾段写最终 WPTR，再写 DONE。
  每次发布前必须收齐此前全部数据写响应，门铃自身也等响应后再继续。
  零长度仍依次发 BASE、最终 WPTR、DONE，不放行任何字。

- 被反压时保持 `cmd_valid` 和地址/数据不变，直到握手；响应侧 `rsp_ready=1`。
- 写完且所有响应返回后 `done` 置位并保持，直到下一次 `start`；零长度装载在
  BASE、WPTR、DONE 三笔响应返回后完成，不写任何 SRAM 字。
- 可以不复位直接重新 start（须先排空旧 DMA）：BASE 写握手把共享水位回退到新 base。

严格方案的放行规则（`REL_LAG=0`）：

```text
允许读 4 字节字 A  <=> loader_wptr_valid
                       且 A >= loader_base
                       且 A + 4 <= loader_wptr
```

`done` 不再放宽任何地址：因为 `A + 4 <= loader_wptr` 已经是“最后一个已提交
字”的精确上界。旧两 bank 方案的
`(A + 4096 <= loader_wptr || 加载器已 done)` 是为“加载器写第 k+1 条带、DMA
读第 k 条带”的相位分离服务的；单口顺序流没有这种跨 bank 并行，保留 4 KB
滞后只会让 DMA 在加载器 done 后还要追赶 4096 字（实测多约 4 千拍）。因此严格
方案把滞后粒度设为 0：取消额外的 4 KB 滞后（允许读的地址集合因此变大），
同时保留同一个“只读已提交字”的安全不变量，`done` 也不能绕过 `A + 4 <= wptr`。

安全性：加载器先收齐数据写响应，再经同一仲裁器提交 WPTR；DMA看到水位时覆盖数据已经写入。`A >= base` 防止重启后读到旧数据；
`A + 4 <= wptr` 防止读未提交字。

边界（`REL_LAG=0`）：

| 场景 | base | wptr | done | A | 允许 |
|---|---|---:|---:|---:|---|
| 零长度装载 | 0x3000 | 0x3000 | 1 | 0x3000 | 否（A+4 > wptr） |
| 零长度装载 | 0x3000 | 0x3000 | 1 | 0x2FFC | 否（A < base） |
| 正常装载 | 0x2000 | 0x2010 | 1 | 0x200C | 是 |
| 正常装载 | 0x2000 | 0x2010 | 1 | 0x2010 | 否（A == wptr） |
| 尾条带不满 4 KB | 0x4000 | 0x5018 | 1 | 0x5014 | 是（最后一字） |
| 尾条带不满 4 KB | 0x4000 | 0x5018 | 0 | 0x5014 | 是（已提交） |

## 9. 复位、错误与未实现项

- 复位：异步低有效。复位清除响应 valid、选组寄存器、写指针、base 和
  `loader_wptr_valid`（复位后 valid=0，直到第一次 BASE 门铃发布初始水位）。
- `rsp_err` 对未映射地址、非对齐/非全字门铃写置1。SRAM仍支持字节掩码，无权限或ECC检查。
- 不支持多笔 outstanding、写合并、读写同拍、低功耗时钟门控。
- `wptr_rd_*` 仅为片内/单元测试读桩；引擎MMIO状态镜像由 `kse_eng_icb` 提供，进度写侧使用3.3所列真实ICB门铃。
- 从口没有上游 `sirv_sram_icb_ctrl` 的 bypbuf 弹性缓冲：反压时 `cmd_ready`
  立即下降。空载读延迟和持续吞吐与上游一致，反压下的额外命令弹性不复刻。

## 10. 验证

### 10.1 单元测试结构

四个单元测试共用 `tb/kse_soc/kse_sram_sys_wrap.sv`（仲裁器 + 单从口 SRAM 的
测试平台包装，三个主口与旧 DUT 同名）：

1. **主测试 `tb_shared_sram`**
   - 初始化：CPU 主口把高 256 KB 写 0（65536 字），低 256 KB 由加载器写
     参数镜像。
   - 流式阶段：加载器写 64K 伪随机字（256 KB），DMA 从同一区域顺序读，读
     地址至少落后 `loader_wptr` 一个条带；CPU 主口在另一 256 KB 区域做随机
     读写（含随机字节掩码），并随机读加载器已提交区域做交叉检查。
   - 由于 CPU 在严格总线上优先级最低，流式阶段会让它先完成初始化；待加载器
     和 DMA 安静后，再让 CPU 跑 600 笔随机读写，然后进入阶段 2。
   - 反压阶段：三个随机主口在全 512 KB 上各发 4000 笔随机读写，`rsp_ready`
     在响应 pending 时以 35% 概率随机拉低；检查响应数据、无丢失、无重复、
     保序、反压期间数据稳定。
   - 扫尾：单主口顺序读全部 131072 字，与影子存储器逐字比对。
2. **优先级/单口 `tb_sram_priority`**（替代旧 `tb_sram_fairness`）
   - 三个主口同时持续请求：只服务 DMA；DMA 停后只服务加载器；再停后只服务
     CPU。每个窗口的接受数、响应数逐笔核对。
   - 最后让最高优先级 DMA 的 `rsp_ready=0`，验证单口在响应未消费时阻塞所有
     主设备，且没有第二个主口偷偷握手。
   - 逐拍断言：主口握手数 ≤1、从口握手与主口握手一致、每主口未完成数 ≤1、
     不丢/不重响应。
3. **重启/水位 `tb_sram_restart`**
   - 不复位连续装载五次（0x1000→0→0x3000 零长度→0x2000→0x4000 的 1030 字，
     最后一个条带只有 6 个字）。每次先毒化目标区；reader 使用参考 DMA 判据
     （valid、base、wptr、done 显式传入），只在规则允许时读。
   - start 当拍检查 valid 为 0、下一拍检查 wptr/base/本地指针/MMIO 已更新；
     零长度、A=wptr、A=base-4、尾条带等边界逐项检查。
4. **契约 `tb_sram_prio_contract`**
   - 加载器 24000 字；DMA 遵守 `valid && A>=base && A+4<=wptr`（严格 0 滞后），
     随机空闲突发（模拟预取 FIFO 满）和 25% 响应反压，读完后写 1584 字输出；
     CPU 在私有 64 KB 区域随机带掩码读写、30% 响应反压。
   - 检查加载器完成、每个 DMA 读返回加载器写入值、输出和 CPU 数据正确、
     无死锁；加载器最长连续等待 < 4200 拍。实测最长 119 拍，说明在 DMA
     优先、0 滞后的组合下加载器仍持续前进。

### 10.2 单元测试结果

| 项目 | 结果（行为模型 / PDK 模型） |
|---|---|
| 主测试 `tb_shared_sram` | **TEST PASSED / TEST PASSED** |
| 优先级/单口 `tb_sram_priority` | **TEST PASSED / TEST PASSED** |
| 重启/水位 `tb_sram_restart` | **TEST PASSED / TEST PASSED** |
| 契约 `tb_sram_prio_contract` | **TEST PASSED / TEST PASSED** |
| 加载器写速率（65536 字） | **0.504 字/拍**（130048 拍，64512 拍仲裁等待） |
| DMA 读速率（65536 字） | **0.504 字/拍**（130049 拍，0 拍总线等待） |
| 稳态窗口（loader+8192..+61440） | 加载器 **0.500**，DMA **0.500** 字/拍 |
| 加载器与 DMA 同拍握手 | 0 拍（单口，结构上不可能） |
| CPU 随机事务 | 600 笔，读数据错误 0 |
| 随机反压阶段 | 3×4000 笔，反压拍 2241/2176/2257，错误 0 |
| 全存储扫尾 | 131072 字 / 131077 拍，错误 0 |
| 优先级窗口 | 接受 1000/1000/1011，响应 1000/1000/1011，单口断言 0 违反 |
| 契约测试 | 加载器 24000 字完成，最长等待 119 拍，逐字数据正确 |
| 重启装载 | 5 个场景（非零 base、回退到 0、零长度、再次非零 base、1030 字尾条带）全过 |
| DMA 边界规则 | 零长度 A=base 拒绝；A=wptr 拒绝；base-4 拒绝；已提交尾字放行 |

行为模型日志与 PDK 模型日志分别保存在 `run/shared_sram_beh/`、`run/shared_sram_pdk/`。

### 10.3 SoC 回归

`tools/kse_soc/kse_soc_sim.sh regress v1 3`，12 任务全部 PASS：

- 每任务窗口 163015 拍，12 任务总 1956180 拍，平均 163015.0 拍，
  150 MHz 下 **920.16 tasks/s**；
- 每任务 6336 字节输出逐字节等于 golden，0 失配；
- DMA 读 80592 字各一次、值等于加载器写入；DMA 写 1584 字各一次；
  加载器写 80592 字并 done；12 条命令、12 次层完成；
- 放行规则逐笔复核 0 违反；
- 新增总线/宏断言：主口多握手 0、从口握手不一致 0、宏组并行访问 0；
- 12 任务结果完全一致（固定任务流），日志见 `run/soc/` 的 `part{0,1,2}.log` 与
  `summary.log`。

> 最终门铃方案在 strict-final 中为每任务 163328 拍、918.397335 tasks/s；门铃与收尾
> 开销使事务下限变为 162850 笔，详见 `docs/spec/kse_soc.md` 第 17 节与 `docs/history.md`。

### 10.4 复现

```sh
# 在仓库根目录，VCS 环境已加载
export KSE_SOC_RUN=$PWD/run/soc
tools/kse_soc/kse_soc_sim.sh fw
tools/kse_soc/kse_soc_sim.sh data
tools/kse_soc/kse_soc_sim.sh regress v1 3

# 单元测试（行为 / PDK）；PDK 模型路径由 PDK_SRAM_V 指定
export KSE_SRAM_RUN=$PWD/run/shared_sram_beh
./tb/kse_soc/run_shared_sram.sh
PDK_SRAM_V=<licensed-sram-model.v> KSE_SRAM_RUN=$PWD/run/shared_sram_pdk \
  ./tb/kse_soc/run_shared_sram.sh --pdk
```

PDK 模型路径由环境变量 `PDK_SRAM_V` 指定（本仓库不附带厂商模型），编译加
`+define+ARM_UD_MODEL +nospecify +notimingcheck`。

## 11. 性能与面积

- 单从口峰值 1 字/拍；没有两 bank 并行，也没有第二个口。strict 基线的任务总事务数
  162769，理论下限 162923 拍（含 154 拍 E203 收尾），实测 163015 拍，
  比下限高 92 拍（0.056%）；从口利用率 99.85%。最终门铃方案的下限更新为 162850 笔，
  实测 163328 拍，见 `docs/spec/kse_soc.md` 第 17 节。
- 与 asic-soc-v2（两 bank 交叉开关、DMA 私有口）对比：v2 为 100794 拍、
  1488.18 tasks/s；严格方案 163015 拍、920.16 tasks/s，周期 +61.7%，
  吞吐 −38.2%。这是“共享 SRAM 必须是 System Bus 上单个普通从设备”的
  直接代价：加载器和 DMA 的 161184 笔读写事务在 v2 中可以两 bank 并行，
  严格方案只能顺序占用同一个 32 位口。
- 宏数量：64 × RAMSP4096X16；面积和功耗本轮未重新综合（任务书明确本任务
  不做 DC 综合和功耗，后续另派）。历史 v2 面积/功耗数字见
  `docs/spec/kse_soc.md` 第 13/14 节，不代表严格方案。
- 共享 SRAM 不计入加速器面积，功耗按规则计入整机（后续功耗轮次处理）。

## 12. 限制与后续

1. 单口把加载器写和 DMA 读串行化，引擎 MM 阶段被拉长（实测 QKV/FC1/FC2
   约 2 倍，非 MM 阶段不变）；这是严格合规的固有成本，不是仲裁器缺陷。
2. 固定优先级在“所有主口持续打同一地址”的对抗性流量下会让低优先级主口
   饿死；这不是 KSE DMA 契约（有限、单调、受水位约束）内的场景。契约测试
   和 12 任务 SoC 已验证加载器前进。
3. 没有 ECC/奇偶校验、地址越界错误和读改写原子操作。
4. 没有复刻上游 `sirv_sram_icb_ctrl` 的 bypbuf 弹性缓冲；反压时 `cmd_ready`
   立即下降。验收若要求 wrapper 级完全一致，应加入同样的旁路缓冲并复测。
5. 没有轮询模式：上游固定快照缺少 `sirv_gnrl_rrobin` 叶子模块；本任务不改
   `third-party/`，故只用上游的固定优先级模式。
6. 面积/功耗未在严格方案下重新测量；后续 DC/PrimePower 轮次需重新生成
   网表、SAIF 和活动文件。

## 13. 参考

1. `docs/arch/kse-microarch.md` 共享 SRAM 与加载器一节：共享 SRAM 与参数加载器的决定。
2. 赛题指南第 3–4 页：共享 SRAM 512 KB、加速器经 System Bus 接入与分层参数装载。
3. E203（hbirdv2）`third-party/e203/rtl/e203/general/sirv_gnrl_icbs.v`
   （`sirv_gnrl_icb_arbt`）、`sirv_1cyc_sram_ctrl.v`、`sirv_gnrl_bufs.v`。
4. `docs/spec/kse_top.md` 第 5 节参数流格式；`tools/kse/pack_params.py`。
