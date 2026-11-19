"""图 3-4：KSE 层内阶段时序甘特图，串行版本 vs 最终版本。
(a) 串行版本：各阶段周期为实测值（origin/feat/asic:docs/spec/kse_top.md 第 3 节表，sample_00，第 1–10 层每层，优化前 RTL）。
(b) 最终版本：只表示阶段之间的重叠关系（依据 kse_top.md 第 10/11 节与报告 3.3.2、3.6 节），
    RTL 文档没有给出最终版逐阶段起止周期，因此 (b) 为示意，横向长度不代表实测。"""
import os, sys
from figstyle import plt, BLUE, ORANGE, PURPLE, INK, GRAY
from matplotlib.patches import Patch

MM, NL, ATT = BLUE, ORANGE, PURPLE   # 矩阵阶段 / 非线性阶段 / 注意力矩阵阶段
SERIAL = [('QKV', 1793, MM), ('SC', 1002, ATT), ('SM', 1411, NL), ('PV', 1002, ATT), ('PJ', 767, MM),
          ('LN1', 1049, NL), ('FC1', 1602, MM), ('FC2', 3686, MM), ('LN2', 1131, NL)]
# 最终版示意：(名称, 起点, 长度, 颜色, 行)；单位为任意，只表达先后与重叠
FINAL = [('QKV', 0, 18, MM, 0), ('SC', 18, 10, ATT, 0), ('SM', 18.6, 13, NL, 1), ('PV', 28, 5, ATT, 0),
         ('PJ', 33.5, 6.5, MM, 0), ('LN1', 34.5, 8.5, NL, 1), ('FC1', 40.5, 16, MM, 0),
         ('FC2', 56.5, 33, MM, 0), ('LN2', 85.5, 8.5, NL, 1)]
NOTES = [(23, 'SC/SM/PV 重叠', 'center'), (50, 'LN1 跟随 PJ；FC1 在 LN1 期间启动', 'center'), (95, 'LN2 在 FC2 末列块期间启动', 'right')]

fig, (a1, a2) = plt.subplots(2, 1, figsize=(7.0, 3.3), gridspec_kw={'height_ratios': [1, 1.55], 'hspace': 0.75})
x = 0
for n, w, c in SERIAL:
    a1.barh(0, w, left=x, height=0.55, color=c, edgecolor='white', linewidth=1.2)
    a1.text(x + w / 2, 0, n, ha='center', va='center', color='white', fontsize=7.5)
    x += w
a1.set_xlim(0, x * 1.005); a1.set_yticks([]); a1.grid(axis='y', visible=False)
a1.spines['left'].set_visible(False)
a1.set_xlabel('周期（实测，第 1–10 层每层）')
a1.set_title(f'(a) 串行版本：各阶段依次执行，合计 {x:,} 拍', loc='left', fontsize=9)

for n, s, w, c, r in FINAL:
    a2.barh(-r, w, left=s, height=0.55, color=c, edgecolor='white', linewidth=1.2)
    a2.text(s + w / 2, -r, n, ha='center', va='center', color='white', fontsize=7.5)
for xn, t, ha in NOTES:
    a2.annotate(t, (xn, -1.4), ha=ha, va='top', fontsize=7.5, color=GRAY, annotation_clip=False)
a2.set_ylim(-1.9, 0.5); a2.set_xlim(0, 95)
a2.set_yticks([0, -1]); a2.set_yticklabels(['矩阵阵列', 'Softmax / LN'])
a2.set_xticks([]); a2.grid(visible=False); a2.spines['bottom'].set_visible(False)
a2.tick_params(axis='y', length=0)
a2.set_title('(b) 重叠调度：阶段重叠示意（长度不按比例；末层输出跟随 LN2 写出的 token 送出）', loc='left', fontsize=9)
fig.legend(handles=[Patch(color=MM, label='线性层矩阵乘'), Patch(color=ATT, label='注意力矩阵乘'), Patch(color=NL, label='非线性单元')],
           loc='upper right', ncol=3, bbox_to_anchor=(0.99, 1.04))
fig.savefig(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fig3-4_layer_gantt.pdf'))
