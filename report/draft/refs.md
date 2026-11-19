# 参考文献调研与核实（KWT-1 与关键词识别专用芯片）

说明：
- “已核实”表示已下载原文 PDF（或官方摘要页）并逐字核对了下列数字。
- 共 2 条，均对应报告正文的引用。

---

## [1] KWT 原论文

- **引用**：A. Berg, M. O'Connor, M. Tairum Cruz, "Keyword Transformer: A Self-Attention Model for Keyword Spotting", Proc. Interspeech 2021, pp. 4249–4253，DOI 10.21437/Interspeech.2021-1286，arXiv:2104.00769。
  - DOI 按 ISCA Archive 命名规则推断，待核。
- **定量结论**（摘要、表 1）：
  - KWT-1 的配置为 dim 64、mlp-dim 256、1 个 head、12 层，参数量 607K。
  - KWT-3 在 Google Speech Commands V2-12 上准确率 98.6%，V2-35 上 97.7%（摘要所称 SOTA）。
- **核实状态**：已对原文核实。
- **报告用法**：作为模型描述的出处，见报告第 2 章 2.1.1 节。

## [2] 65 nm 时间稀疏感知 KWS 芯片

- **引用**：Q. Chen, K. Kim, C. Gao, S. Zhou, T. Jang, T. Delbruck, S.-C. Liu, "A 65nm 36nJ/Decision Bio-inspired Temporal-Sparsity-Aware Digital Keyword Spotting IC with 0.6V Near-Threshold SRAM", arXiv:2405.03905, 2024。
  - 正式发表的会议/期刊未在原文中确认，待补。
- **定量结论**（摘要）：
  - 工艺 65 nm，面积 0.78 mm²，含特征提取和 24 kB 近阈值 SRAM。
  - 使用 ΔRNN 分类器，在 11 类 GSCD 上准确率 90.5%，能耗 36 nJ/decision。
  - 在 87% 时间稀疏度下，延迟降低 2.4 倍，能耗降低 3.4 倍。
- **核实状态**：已对原文（arXiv）核实。
- **报告用法**：作为关键词识别专用芯片的背景参照，见报告第 1 章 1.1 节。
