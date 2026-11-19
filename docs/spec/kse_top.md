# KSE 顶层规格

KSE（KWT Stream Engine）是只适配 KWT-1 全 W4 冻结方案的固定功能引擎。本文描述 `rtl/kse/` 的接口、
每层数据流与时序、行存储分区、参数流格式和数值单元。总体结构见 `docs/arch/kse-microarch.md`；
逐位语义以 `quantization/integer.py` 的整数参考实现和测试平台 golden 为准。

> 交付配置：R32×C32、参数预取 FIFO 128 行（PF128）、SM_LANES=8、LN_LANES=8。本文第 5 节记录
> v1 参数流格式（每层 6545 字），最终交付使用第 10 节的 v3 格式（每层 6584 字，12 层共 79008 字）；
> 第 10 节还记录了优化轮 1 的 16/16 路历史默认值，第 11 节及最终 PPA 以 8/8 路配置为准。两套配置
> 的数值语义和协议完全一致，仅并行路数、FIFO 深度和参数流补齐方式不同。

## 1. 设计点

| 项 | 取值 |
|---|---|
| 形状 | T=99 token，D=64，MLP 宽 256，单头注意力，12 层 |
| 数值 | A8、W4（逐通道 2 的幂尺度）、MAC 24 位、Softmax 紧凑 Q15 指数表 + P7、LayerNorm Q12/Q12、GELU middle ROM |
| MAC 阵列 | R=32 行（归约）× C=32 列，1024 个 s9×s8 乘法器，权重驻留、激活流式 |
| 驻留寄存器 | 每 PE 32 位：8 个 4 位槽（W4）或 4 个 8 位槽（K、V、W8） |
| 行存储 | A、B 各 16 个 RAMSP1024X16 并排，行宽 32 字节，1024 行 |
| Softmax | 8 路流水除法器（参数 `SM_LANES`），求和 32 路 |
| LayerNorm | 8 路流水除法器（参数 `LN_LANES`），每 token 一次 isqrt（两个迭代单元交替） |
| 时钟 | 目标 150 MHz（6.667 ns），SMIC40 TT 1.10 V 25°C |

`kse_top` 的 `R`、`C`、`SM_LANES`、`LN_LANES` 是参数。v1 的参数流格式和行存储地址按 R=C=32 生成，
`kse_top` 在 R、C 不等于 32 时编译报错；两个 LANES 参数可任意取 1–32。

## 2. 接口

一条命令执行一层编码器。所有握手都是 valid/ready，数据在 `valid && ready` 的上升沿被接收。

| 端口 | 方向 | 宽度 | 说明 |
|---|---|---|---|
| `clk`、`rst_n` | in | 1 | 时钟；异步低有效复位 |
| `cmd_valid`/`cmd_ready` | in/out | 1 | 命令握手；`cmd_ready` 只在空闲时为 1 |
| `cmd_layer` | in | 4 | 层号 0–11，选择 GELU ROM 表 |
| `cmd_in_en` | in | 1 | 1：先从 `act_in` 读入 X（第 0 层）；0：沿用行存储 A 中上一层的输出 |
| `cmd_out_en` | in | 1 | 1：层结束后把输出从 `act_out` 送出（最后一层；验证时可每层打开） |
| `param_valid`/`param_ready`/`param_data` | in/out/in | 1/1/32 | 本层参数流，引擎按消费顺序读取，目的单元未空闲时反压 |
| `act_in_valid`/`act_in_ready`/`act_in_data` | in/out/in | 1/1/32 | 1584 字 |
| `act_out_valid`/`act_out_ready`/`act_out_data` | out/in/out | 1/1/32 | 1584 字，可被反压 |
| `done` | out | 1 | 本层（含输出流）完成时拉高 1 拍 |
| `busy` | out | 1 | 非空闲 |

激活字格式：99×64 的 int8 张量按行优先展开，字 w 含字节 4w..4w+3，字节 4w 在 [7:0]（小端）。
v1 每层参数恰好 6545 字（第 5 节）；最终 v3 流每层 6584 字（第 10 节），命令完成前引擎一定把
本层参数全部读完。

命令序列（测试平台扮演 E203 和参数加载器）：第 0 层 `in_en=1`，第 11 层 `out_en=1`，
每条命令发出后从参数流第 `每层字数×layer` 字起送该层全部参数；`done` 后才能发下一条命令。

## 3. 每层数据流与时序

各阶段严格串行，参数加载器与之并行（第 7 节）。表中“读”“写”指行存储的 32 字节行访问；t 为 token，kb 为归约块，cb 为列块。

| 阶段 | 驻留操作数 | 流式行 | 输出行 | 周期（sample_00 实测，第 1–10 层每层，时序修复后 RTL） |
|---|---|---|---|---|
| IN（仅 in_en） | — | act_in 每 8 字成一行 | A[X+r] | 1587 |
| QKV | Wq、Wk、Wv（加载器，W4） | A[X+2t+kb] | B[Q/K/V+2t+cb] | 1793 |
| SC：S=QKᵀ | K（列加载，从 B 读） | B[Q+2t+kb] | A[S+4t+cb] | 1002 |
| SM：Softmax | — | A[S+4t+k] | B[P+4t+k] | 1411 |
| PV：ctx=P·V | V（行加载，从 B 读） | B[P+4t+kb]（u8） | A[CTX+2t+cb] | 1002 |
| PJ：输出投影 | Wproj | A[CTX+2t+kb] | B[PJ+2t+cb] | 767 |
| LN1：残差+LN | — | A[X+2t+h]、B[PJ+2t+h] | A[X+2t+h]（原位） | 1049 |
| FC1+GELU | Wfc1 | A[X+2t+kb] | B[H+8t+cb] | 1602 |
| FC2 | Wfc2（K=256） | B[H+8t+kb] | A[F2+2t+cb] | 3686 |
| LN2：残差+LN | — | A[X+2t+h]、A[F2+2t+h] | A[X+2t+h]（原位） | 1131 |
| OUT（仅 out_en） | — | A[X+r] | act_out | 1588 |

矩阵阶段的循环：对每个列块（32 个输出通道）遍历全部 99 个 token，每个 token 连续 KB 拍（每拍读一行 32 字节），
第 KB 拍后该列块 32 个输出经后处理写成一行。KB：QKV/PJ/FC1/SC 为 2，PV 为 4（99 个 key 补到 128），FC2 为 8。
阵列流水为“读地址 → 存储数据 → S1 寄存 → S2 乘法与 4 输入部分和 → S3 累加 → 后处理三级 → 写回”，II=1。

- **SC**：每个列块先把 32 个 key 的 K 行（每 key 2 行）列加载进 PE 列（int8 槽 0、1），
  最后一个列块只有 key 96–98 有效，其余列一拍写 0；然后流式读 Q。
- **PV**：每个输出列块把 99 个 token 的 V 行行加载进 PE 行（int8 槽 kb=j/32，行 r=j%32），
  token 99–127 对应的行一拍写 0；P 的填充字节在 Softmax 中写为 0。V 不转置。
- **SM**：每个查询读 4 行（字节 j≥99 忽略），两个行缓冲交替：装载并求最大值 → 32 路查表求和 → 8 路除法；
  输出行写 B，字节 j≥99 写 0。
- **LN1/LN2**：每个 token 读两半（每半 32 通道的 x、y），残差 32 路并行，单遍统计 Σx、Σx²，
  3 个 token 缓冲：填充 → 统计/方差/isqrt → 8 路除法与仿射。输出写回 A 有优先权，读等待。

存储端口：每个阶段的读和写落在不同的行存储上（LN 阶段例外，见上），因此每个宏每拍至多一次访问。
RTL 中有仿真断言检查矩阵阶段的同存储读写冲突。

## 4. 行存储分区（32 字节行）

| 存储 | 行地址 | 内容 | 生命周期 |
|---|---|---|---|
| A | 0–197 | X（token t 占 2t、2t+1，通道 0–31、32–63） | IN/上一层 LN2 写；LN1 原位写 X1；LN2 原位写下一层 X |
| A | 200–595 | S（查询 t 占 4t..4t+3，字节 j=32k+i） | SC 写，SM 读 |
| A | 600–797 | ctx（2 行/token） | PV 写，PJ 读 |
| A | 800–997 | FC2 输出（2 行/token） | FC2 写，LN2 读 |
| B | 0–197 / 200–397 / 400–597 | Q / K / V（2 行/token） | QKV 写；SC 读 Q、K；PV 读 V |
| B | 0–395 | P（4 行/查询，覆盖 Q、K） | SM 写，PV 读 |
| B | 0–197 | proj（2 行/token） | PJ 写，LN1 读 |
| B | 200–991 | H=GELU(FC1)（8 行/token） | FC1 写，FC2 读 |

两个原位覆盖都安全：LN 阶段 token t 的输出行写入时，它的输入行已经读完；P 只覆盖 SC 结束后已无用的 Q、K。

## 5. 参数流格式 kse-param-stream-v2

由 `tools/kse/pack_params.py` 从冻结 profile 一次性生成（不计时的格式转换），`--verify` 逐字段解码回 profile 比对。
全部为 32 位小端字，按引擎消费顺序排列，每层 6545 字，12 层共 78540 字。

| 顺序 | 段 | 字数 | 编码 |
|---|---|---|---|
| 1 | 层头 | 5 | 见下表 |
| 2 | q、k、v：每个列块 cb=0,1 | 3×2×(6+256) | shift[6]、W[256] |
| 3 | proj：cb=0,1 | 2×(16+6+256) | bias[16]、shift[6]、W[256] |
| 4 | LN1 | 32+16 | gamma（u16，2 个/字）、beta（s8，4 个/字） |
| 5 | fc1：cb=0..7 | 8×(16+6+256) | 同 proj |
| 6 | fc2：cb=0,1 | 2×(16+6+1024) | bias、shift、W（K=256，8 个 kb） |
| 7 | LN2 | 48 | 同 LN1 |

- bias：s16，2 个/字，通道 2i 在低半字。q/k/v 的 bias 全为 0，打包器检查后删除。
- shift：每通道最终移位量 `e_out − e_in − weight_exponent`（s5，6 个/字，字段不跨字），已在离线完成指数运算。
- W：对每个 kb、每个 PE 行 r（输入通道 kb·32+r），4 个字依次覆盖输出列 8q..8q+7，字内 nibble j（s4，低位在前）是列 8q+j。
  4 个字恰好装满一个 PE 行的 32 个 4 位槽。

层头（s8 字段，字节 0 在低位；移位量采用统一的定点约定，正为最近偶数右移、负为左移）：

| 字 | 字节 0 | 字节 1 | 字节 2 | 字节 3 |
|---|---|---|---|---|
| 0 | score_sh = e_score − (e_q+e_k+attn_scale) | q8_sh = −8 − e_score | ctx_sh = e_ctx + 7 − e_v | gelu_tail = e_gelu − e_fc1 |
| 1 | res1_ax = e_res1 − e_input | res1_ay = e_res1 − e_proj | res2_ax = e_res2 − e_ln1 | res2_ay = e_res2 − e_fc2 |
| 2 | ln1_vsh = −(2e_res1+24) | ln1_nsh = −(e_res1+24) | ln1_ash = e_ln1 + 24 | gelu_lo |
| 3 | ln2_vsh | ln2_nsh | ln2_ash = e_output + 24 | gelu_hi |
| 4 | ln1_eps（u16，[15:0]） | | ln2_eps（u16，[31:16]） | |

打包器同时检查 RTL 数据通路的取值范围：score_sh、ctx_sh ∈ [0,24]，q8_sh ∈ [−15,0]，残差对齐 ∈ [−7,15]，
vsh ∈ [−20,0]，nsh ∈ [−23,0]，ash ∈ [0,20]，GELU 窗口宽度等于 ROM 表长，紧凑指数表、P7、LN Q12/Q12 与 RTL 硬连线一致。

### 5.1 对原 `pack_params.py`（v1）的审查与修改

| 问题 | 影响 | 处理 |
|---|---|---|
| 15 个指数和 LN epsilon 放在每层末尾 | 首个线性层的移位量要等全层参数读完才知道，无法流式 | 层头放在最前，并离线算成最终移位量 |
| 只打包原始 weight_exponents | 硬件要做逐通道指数减法 | 打包最终移位量 `e_out−e_in−w_exp` |
| 权重整矩阵行优先，bias 在整矩阵之后 | 与列块驻留的消费顺序不一致，需要大缓冲 | 按列块交织：bias、shift、权重块 |
| `layer["words"]` 在 `start` 赋值前计算，恒为 0 | sidecar 字数错误 | 重写，`params.json` 给出每段偏移 |
| q/k/v bias 直接丢弃，未检查是否为 0 | 若 profile 改变会静默出错 | 非零即报错 |
| `--verify` 只检查越界 | 不能证明打包正确 | 逐字段解码与 profile 比对（12 层 604476 个值） |

GELU 表和指数表不进参数流：`tools/kse/gen_roms.py` 生成 `kse_exp_rom.sv`（257×u16）和 `kse_gelu_rom.sv`
（按层号选表，12 层共用 2 张不同的表）。

## 6. 数值单元

逐位语义与 `quantization/integer.py` 的整数参考实现一致；所有除法和开方都是寄存的恢复迭代，没有组合 `/`、`%`。

| 单元 | 模块 | 运算 | 位宽 / 流水 |
|---|---|---|---|
| 后处理（32 路） | `kse_post_lane` | `sat8(shift(acc24 + bias16, sh))`；FC1 再查 GELU | 3 级（加 bias / 移位饱和 / GELU） |
| GELU | `kse_gelu` | `x<lo → 0`，`x>hi → sat8(shift(x, tail))`，否则 ROM[x−lo] | 组合，在后处理第 2 级 |
| Softmax | `kse_softmax_core` | `q8=shift(s−max, q8_sh)`，`idx=rne(min(−q8,4096),4)`，`e=q8<−4096?0:EXP[idx]`，`p=clip(div_rne(e<<7, Σe),0,255)` | 输入寄存、32 输入最大值树；指数通道先寄存地址再查表；除法 23/22 位、8 位商、2 位/级，输入寄存 |
| 残差（32 路） | `kse_residual` | `sat8(shift(x,ax)+shift(y,ay))` | 组合，寄存一级 |
| LayerNorm | `kse_ln_core` | 见下 | 除法输入寄存，38/24 位、30 位商、2 位/级 16 拍；钳位/gamma 乘/移位/beta 饱和各一级 |
| 整数开方 | `kse_isqrt` | floor sqrt，36 位输入，每拍 2 位结果 | 9 拍迭代，两个单元交替服务 token |

LayerNorm 单遍统计：S=Σr，Q=Σr²，`square_sum = 64²·Q − 64·S²`，在整数上与参考的 Σ(64r−S)² 恒等；
`variance = rne(square_sum, 18)`；`vq = shift(variance, vsh) + eps`；`den = 64·isqrt(vq)`；
`n = div_rne(shift(64r−S, nsh), den)`；`out = sat8(shift(n·gamma, ash) + beta)`。
商超过 30 位（只在方差接近 0 时出现）时钳到 2³⁰−1：此时 |n·gamma| ≥ 2²⁹，ash ≤ 20 时移位后 ≥ 2⁹，加 beta 后必然饱和，
结果与精确商相同；gamma=0 时两者都为 0。打包器检查 ash ≤ 20。

阵列：S2 内每 PE 根据槽号选 4 位（符号扩展）或 8 位操作数，与 9 位流式操作数（int8 符号扩展或 u8 零扩展）相乘，
每列 8 个 4 输入部分和寄存；S3 求和并累加到 24 位（二进制补码回绕；冻结方案已验证不溢出）。

## 7. 参数加载与驻留槽管理

`kse_loader` 按第 5 节顺序消费参数流，只在目的单元空闲时拉高 `param_ready`：

- **列块序号** cbseq：一层 18 个列块（q0 q1 k0 k1 v0 v1 p0 p1 fc1_0..7 fc2_0 fc2_1）。
- **元数据**：bias/shift 写入 4 项缓冲的第 cbseq%4 项；条件 `cbseq < post_cb_done + 4`（该项上一使用者已后处理完）。
- **驻留槽**：8 个 W4 槽组成环；列块占 KB 个连续槽，起点为累计槽数 mod 8。条件 `ld_slot + KB − fr_slot ≤ 8`，
  `fr_slot` 在列块最后一拍到达 S2（读驻留寄存器）时增加。K=64 的线性层最多预装 4 个列块；FC2（KB=8）占满全部槽。
- **注意力门控**：SC/PV 用 int8 槽装 K、V，加载器在 PV 结束前不装 proj/fc1/fc2 的权重（`lin_gate_hi`）。
- LN1 参数在 proj 之后装入；LN2 参数等 LN1 阶段完成后才装（共用一组 gamma/beta 寄存器）。
- `kse_mm` 对线性列块等待 `ld_cb > cbseq` 后才开始流式计算。

## 8. 验证可见性

测试平台通过层次引用观察：行存储 A/B 的写端口（q/k/v/score/softmax/context/proj/ln1/gelu/fc2/output）、
后处理第 1 级输出 `u_mm.tap_pre`（fc1，GELU 前）、残差寄存输出 `u_ln.tap_res`（res1/res2）。这些都是被综合的 RTL 本身的信号，
没有另设参考接口或行为模型。

## 9. 已知限制（v1 历史）

- 阶段严格串行，参数流在 SC、SM、PV 阶段停顿（驻留寄存器被 K/V 占用），层与层之间不预取下一层参数。
- FC2 的列块占满 32 位驻留寄存器，第 2 个列块的 1046 字只能在第 1 个列块算完后装入。
- 性能实测与版本演进见 `docs/history.md`。

## 10. 优化轮 1 的改动（2026-11-09）

本节覆盖前文与之冲突的描述；第 3 节表中周期为优化前数据。

- **参数流 v3**：每个字段补零到 4 字的整数倍（层头 8 字、shift 8 字），每层 6584 字，12 层 79008 字。
- **参数预取 FIFO**（`kse_pfifo`，`PF_DEPTH=1024`）：8 个 RAMSP1024X16 并排成 1024×128 位，参数口持续接收（与阶段和层边界无关），
  加载器每拍取一行 128 位（一个 PE 行的 32 个 W4 权重）。读优先，输入行先进 2 行暂存，只在无读的拍写入宏；输出 4 行缓冲。
  测试平台从第 0 层命令握手起连续送全任务参数。
- **驻留槽逐 kb 门控**：加载器对每个归约块单独检查 `ld_slot + 1 − fr_slot ≤ 8`，FC2 第一个列块的前 6 个 kb 在 FC1 最后一个列块计算时就装入。
- **P 移到 B 行 600–995**，Softmax 不再覆盖 Q/K。
- **阶段重叠**（存储口上不可停顿的写者优先，另一方的读等待）：
  - Softmax 与 SC 同时启动，查询 t 在 S(t,3) 写入后才开始（SC 写 A 优先，Softmax 读 A 等待；Softmax 写 B 优先，SC 读 B 等待）。
  - PV 在 SC 结束后立即启动（V 装载与 Softmax 并行），流式 token t 等 P(t) 四行写完。
  - FC1 在 LN1 期间启动，token t 等 LN1 两行写回 A（LN1 用 A 时 FC1 读等待；FC1 写 B 时 LN1 读等待）。
  - LN2 在 LN2 参数装入后（FC2 最后一个列块期间）启动，token t 等 F2(t,1) 写入；LN 输出经 4 行队列写 A，FC2 写 A 优先。
- **LayerNorm**：6 个 token 缓冲、信用计数代替固定冷却、除法阶段 token 间无气泡。
- **默认路数** SM_LANES=16、LN_LANES=16。
- 第 1–10 层每层 8223 拍；单任务（命令握手沿到第 11 层 done 沿）101792 拍。

## 11. 优化轮 2：消融选择（历史）

公平基线与当前RTL采用完全相同的综合/活动/功耗脚本。选中`ln_live`：SoC 100794拍/任务（-2.67%），计分面积1.396560 mm²（-0.09%），整SoC功耗165.355168 mW，能耗111.117614 µJ（-1.45%），Δ分+0.505833。所有数字来自实际日志，非模型估算。

默认参数：ATT_VCTX=0、ATT_PROB=0、PROB_BANKED=0、SM_BUFFERS=2、USE_SHADOW=0。逻辑A/B写回tap保持不变，继续逐位检查。

A/B各16个RAMSP1024X16与参数FIFO的8个RAMSP1024X16保留；不实例化额外注意力V/ctx或P宏。所有物理宏为单口：Softmax写P时矩阵读等待，PV写ctx时Softmax读S等待，PJ读ctx与LN访问A仲裁。SC成对调度使用既有32bit/PE驻留槽，不增加容量。Softmax信用数与实际缓冲深度参数一致。

LN1跟随PJ已写token启动；末层输出跟随LN2已写token，复用原输出FIFO，接受反压，排空后才完成。提前命令/层头握手保留；USE_SHADOW=0时取消PJ影子、FC2影子复用和下一层Q0预装，因此不声称具有下一层实际QKV MAC与旧LN2的重叠。TB仅在USE_SHADOW=1时要求真实跨层MAC重叠，所有数值/协议/错误检查不变。

LN仿射gamma/beta直接读取loader，loader顺序保证LN排空前不覆盖；仅保留层头标量快照。仿真断言检查LN活动期间仿射参数稳定。

ATT_VCTX/ATT_PROB/PROB_BANKED和USE_SHADOW保留为可复现实验参数；额外宏和寄存器仅在启用时综合存在。V/ctx列bank复用、P普通单口宏、P分beat宏分别做全量回归、SoC综合和12窗口功耗后按边际评分选择，结果见最终报告。

输入按token/QKV及安全字水位方案已实现并实测（含同bank交仲裁），因SoC变慢回退；当前第0层先完整加载输入，仍采用共享SRAM文档中的4KB规则。实验patch、契约验证和否定周期保留在历史记录中。FIFO仍1024行。

24样本×12层共40468032项逐位一致；四单元、四SRAM/契约、12任务SoC、12层输出反压测试通过。PPA为SMIC40 RVT TT 1.10V 25°C、150MHz、理想时钟、布线前结果。strict 合规版与 strict-final 的后续改动见 `docs/history.md`。
