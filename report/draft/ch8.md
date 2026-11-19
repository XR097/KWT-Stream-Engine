# 参考文献

[1] A. Berg, M. O'Connor, M. Tairum Cruz. Keyword Transformer: A Self-Attention Model for Keyword Spotting. Proc. Interspeech, 2021, pp. 4249–4253.

[2] Q. Chen, K. Kim, C. Gao, S. Zhou, T. Jang, T. Delbruck, S.-C. Liu. A 65nm 36nJ/Decision Bio-inspired Temporal-Sparsity-Aware Digital Keyword Spotting IC with 0.6V Near-Threshold SRAM. arXiv:2405.03905, 2024.

# 附录

## 附录 A 寄存器与地址映射表

KSE 的寄存器基地址为 0x1100_0000，中断接 PLIC 源 17。

表 A-1 KSE MMIO 寄存器

| 偏移 | 名称 | 读写 | 说明 |
|---|---|---|---|
| 0x000 | ID | RO | 固定值 0x4B534531（"KSE1"） |
| 0x004 | CTRL | RW | 层完成中断使能、错误中断使能 |
| 0x008 | STATUS | RO | 忙、未完成工作、待执行命令数、队列满、加载器完成等状态 |
| 0x00C | IRQ_STATUS | W1C | 层完成、错误中断状态 |
| 0x010 | PARAM_ADDR | RW | 下一条命令的参数段字节偏移 |
| 0x014 | PARAM_LEN | RW | 参数段字数 |
| 0x018 | IN_ADDR | RW | 输入字节偏移（带输入的命令使用） |
| 0x01C | OUT_ADDR | RW | 输出字节偏移（带输出的命令使用） |
| 0x020 | CMD | WO | 写入层号和输入/输出使能即入队，同时锁存当前地址寄存器 |
| 0x024 | LDR_WPTR | RO | 加载器最近一次发布的写指针（门铃 WPTR 的镜像） |
| 0x028 | LDR_BASE | RO | 加载器本次装载的起始地址 |
| 0x02C | DONE_CNT | RO | 复位以来完成的层数 |
| 0x030 | ERR | RO | 命令溢出、DMA 响应错误 |

表 A-2 KSE SoC 地址映射

| 区域 | 地址 | 说明 |
|---|---|---|
| ITCM | 0x8000_0000，64 KiB | 固件代码，MROM 0x1000 跳转到此 |
| DTCM | 0x9000_0000，64 KiB | 固件数据、bss、栈 |
| 共享 SRAM | 0x4000_0000–0x4007_FFFF | 系统总线上的 32 位从设备，E203、参数加载器、KSE DMA 经同一仲裁器访问 |
| 加载进度门铃 | 0x4008_0000 / 0x4008_0004 / 0x4008_0008 | BASE/INIT、WPTR、DONE，加载器经同一仲裁器写入 |
| KSE MMIO | 0x1100_0000–0x1100_0FFF | 外设总线槽的前 4 KiB，其余地址返回错误 |
| PLIC | 0x0C00_0000 | KSE 中断为源 17 |

表 A-3 共享 SRAM 内的任务布局

| 偏移 | 字数 | 内容 | 写者 / 读者 |
|---|---:|---|---|
| 0x00000–0x018BF | 1584 | 输入激活（99×64 int8） | 加载器 / 引擎 DMA |
| 0x018C0–0x4EB3F | 79008 | 参数流（12 层 × 6584 字，第 L 层起于 0x018C0 + 26336·L） | 加载器 / 引擎 DMA |
| 0x60000–0x618BF | 1584 | 输出激活 | 引擎 DMA / 测试平台比对 |
| 0x7F000 | 1 | FLAG_START，固件写 1 后测试平台启动加载器 | E203 |
| 0x7F004 | 1 | FLAG_DONE，通过时为 0x600D000C，失败时为 0xBAD0_00xx | E203 |

## 附录 B 独立验证需求追踪摘要

独立验证以需求追踪表组织，每条需求对应规格条款、被测对象、测试与检查器以及结果。表 B-1 按模块统计。

表 B-1 需求追踪统计

| 模块 | 条目数 | 其中 P0 | 已执行 |
|---|---:|---:|---:|
| 数值单元 | 14 | 11 | 14 |
| 参数存储与调度 | 8 | 6 | 8 |
| 引擎与十二层网络 | 10 | 8 | 10 |
| 共享 SRAM | 12 | 10 | 12 |
| 寄存器、命令队列与 DMA | 12 | 11 | 12 |
| SoC 集成 | 9 | 7 | 8 |
| 端到端 | 5 | 5 | 5 |
| 验证环境 | 7 | 6 | 7 |
| 合计 | 77 | 64 | 76 |
