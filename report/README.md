# KSE 设计报告

本目录存放 KSE 设计报告的源稿、生成脚本和生成结果。正文与全部 PPA 数字使用
strict-final 口径：每任务 163,328 拍、918.4 任务/秒、计分面积 1.237 mm²、
整 SoC 功耗 123.41 mW、单任务能耗 134.38 µJ。

## 目录结构

| 路径 | 内容 |
| --- | --- |
| `draft/ch1.md` – `ch8.md` | 报告正文源稿（Markdown）。`ch1` 含摘要和第 1 章，`ch2`–`ch7` 对应第 2–7 章，`ch8` 为参考文献和附录 |
| `draft/refs.md` | 文献调研与核实记录，不进入报告正文 |
| `build_pdf.py` | 把源稿转成 LaTeX 并编译为 PDF |
| `build_report.py` | 把源稿合成为 Word 文档（备用） |
| `figures/` | 报告插图（矢量 PDF）；`figures/src/` 为生成源（TikZ `.tex` 与 matplotlib `.py`），`bash report/figures/src/make_all.sh` 一键重新生成 |
| `build/` | 生成结果：`设计报告初稿.pdf`（`report.tex` 是中间文件，构建后可删除） |

修改报告内容时只改 `draft/` 下的 Markdown，`build/` 下的文件都由脚本生成，不要手工编辑。

## 生成 PDF

### 所需工具

- Python 3（只用标准库）
- [tectonic](https://tectonic-typesetting.github.io/) 0.15.0：单文件的 XeTeX 引擎，首次编译时自动联网下载所需宏包（包括 ElegantPaper 模板），不需要安装 TeX Live
- Noto CJK 字体：`Noto Sans CJK SC` 与 `Noto Serif CJK SC`（Ubuntu 下为 `fonts-noto-cjk` 和 `fonts-noto-cjk-extra` 两个包）

tectonic 的安装方式（不需要 sudo）：

```bash
curl -sSL -o tectonic.tar.gz \
  https://github.com/tectonic-typesetting/tectonic/releases/download/tectonic%400.15.0/tectonic-0.15.0-x86_64-unknown-linux-musl.tar.gz
tar xzf tectonic.tar.gz && mv tectonic ~/.local/bin/
```

### 调用方式

```bash
python3 report/build_pdf.py
```

输出 `report/build/设计报告初稿.pdf`。首次运行需要联网下载宏包，耗时几分钟；之后约十几秒。脚本会先写 `report/build/report.tex` 再编译，构建完成后请删除该中间文件，避免把本机字体路径带进发布包。

封面只有作品名称和日期，可在 `build_pdf.py` 开头的 `TITLE`、`DATE` 两个变量里填写。`build_pdf.py` 会自动在 `/usr/share/fonts/opentype/noto` 和 `/usr/share/fonts/google-noto-cjk` 中查找 Noto CJK 字体；如果字体装在别处，修改 `_font_dir()` 的搜索路径。

## 重新生成插图

```bash
bash report/figures/src/make_all.sh            # 全部
bash report/figures/src/make_all.sh fig3-3     # 只生成文件名以 fig3-3 开头的图
```

框图为 standalone TikZ 文档（共用 `common.tex` 中的配色与样式），用 tectonic 编译；数据图用 matplotlib（共用 `figstyle.py`），默认使用 `~/.venvs/figs/bin/python`，可用环境变量 `PY` 指定。安装 matplotlib：`python3 -m venv ~/.venvs/figs && ~/.venvs/figs/bin/pip install matplotlib`。

## 生成 Word 文档（备用）

```bash
pip install --user python-docx
python3 report/build_report.py
```

输出 `report/build/设计报告初稿.docx`。默认生成简单封面；如需套用单位模板，用环境变量 `REPORT_TEMPLATE` 指向模板 `.docx`。

## 源稿写法约定

转换脚本只支持以下 Markdown 写法：

- 标题：`# 2 章名`、`## 2.1 节名`、`### 2.1.1 小节名`，编号写在标题里
- 管道表格；表题写在表格上一行，形如 `表 2-1 标题`
- 无序列表（`- `）和有序列表（`1. `），不支持嵌套
- `**粗体**` 和 `` `等宽` ``
- `【待补：说明】`：留空项，PDF 中显示为红色
- `【图 2-1 待绘制：说明】`：单独成行，PDF 中显示为灰色占位框
- 插图：单独成行写 `![图 2-1 标题](figures/fig2-1_kwt_layer.pdf)`，路径相对 `report/`。生成居中浮动图，宽度默认为版心宽（`\linewidth`），高度不超过 0.42 倍版心高；图题放在图下方，形如“图 2-1 标题”，不自动编号。需要缩小时在标题末尾加 `{width=0.7}`（版心宽的比例），如 `![图 3-4 标题{width=0.8}](figures/fig3-4_layer_gantt.pdf)`。图片文件不存在时会打印警告并显示灰色占位框
- 参考文献条目：`[1] 作者. 题目. 出处.`

## 数据口径

`draft/` 中的周期、吞吐、面积、功耗、能耗只取自 strict-final 的实测结果；不要
把不同版本或不同总线结构的数字混进同一张表。报告只描述 KSE 一款设计，不包含
任何对照方案的内容。

## 提交前检查

- 报告及其源稿中不得出现单位、姓名、队伍名等身份信息
- 最终提交 PDF，大小不超过 50 MB
- 全文搜索“待补”和“待绘制”，确认没有遗留
- 按共同任务书的黑名单词表扫描 `draft/`、`figures/src/` 和 PDF 全文
- 构建后删除 `build/.tectonic-cache`、`figures/src/__pycache__` 等缓存
