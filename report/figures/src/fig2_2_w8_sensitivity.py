"""图 2-2：72 个矩阵单独改 W8 的验证精度变化 + 贪心累积曲线。
数据来源：origin/feat/asic:docs/quantization/asic_numerics_report.md 5.2 节（完整验证集 4445 条实测）。"""
import os, sys, numpy as np
from figstyle import plt, BLUE, ORANGE, PURPLE, INK, GRAY
from matplotlib.colors import TwoSlopeNorm, LinearSegmentedColormap

TYPES = ['q', 'k', 'v', 'proj', 'fc1', 'fc2']
# Δacc（百分点），行 = 层 b00..b11，列 = q k v proj fc1 fc2
DACC = np.array([
    [-0.0225, 0.1125, 0.0675, -0.1350, 0.0450, 0.0000],
    [0.0450, 0.1125, -0.0450, 0.0000, -0.1125, 0.0675],
    [0.0450, -0.0225, 0.0000, -0.0225, -0.0450, 0.0225],
    [0.0900, 0.0675, 0.0225, 0.0225, -0.0450, -0.0900],
    [0.1575, 0.0225, 0.0225, 0.0000, 0.1350, 0.0000],
    [0.2025, 0.1125, 0.0900, 0.0450, 0.0225, 0.1125],
    [0.0000, 0.1125, -0.0225, 0.0450, 0.0675, -0.0225],
    [0.0675, 0.0675, 0.0675, 0.1125, -0.0450, 0.0000],
    [0.1350, 0.1125, 0.0900, 0.0225, 0.0450, 0.0225],
    [0.0450, -0.0900, 0.1575, 0.0225, 0.0675, -0.0225],
    [0.0675, 0.0225, -0.0225, 0.0675, 0.1125, 0.0900],
    [0.0450, 0.0225, 0.1125, 0.0675, 0.0225, 0.0225],
])
# 贪心曲线（标注为 层号.矩阵，层号从 1 起）：参数增量 %，验证 / 测试 Top-1 %
GREEDY = [  # 点, 新加入矩阵, +%, val, test
    (0, '全 W4', 0.0000, 97.2778, 96.9734),
    (1, '+6.q', 0.6102, 97.4803, 96.8507),
    (2, '+5.q', 1.2204, 97.4353, 96.7280),
    (3, '+10.v', 1.8307, 97.4578, 96.8507),
    (4, '+9.q', 2.4409, 97.3678, 96.8712),
    (5, '+1.k', 3.0511, 97.3453, 96.9121),
]

fig, (a1, a2) = plt.subplots(1, 2, figsize=(7.0, 3.2), gridspec_kw={'width_ratios': [1.05, 1]})
cmap = LinearSegmentedColormap.from_list('div', [ORANGE, '#F2F2F2', BLUE])
lim = 0.21
im = a1.imshow(DACC.T, cmap=cmap, norm=TwoSlopeNorm(0, -lim, lim), aspect='auto')
for (l, t), v in np.ndenumerate(DACC):   # 只标出最大与最小两格
    if v in (DACC.max(), DACC.min()):
        a1.text(l, t, f'{v:+.2f}', ha='center', va='center', fontsize=6.5, color='white')
a1.set_xticks(range(12)); a1.set_xticklabels(range(1, 13))   # 层号从 1 起，与正文“第 6 层”一致
a1.set_yticks(range(6)); a1.set_yticklabels(TYPES)
a1.set_xlabel('层号'); a1.grid(False)
for s in a1.spines.values(): s.set_visible(False)
a1.tick_params(length=0)
cb = fig.colorbar(im, ax=a1, fraction=0.05, pad=0.02)
cb.set_label('验证精度变化（百分点）'); cb.outline.set_visible(False); cb.ax.tick_params(labelsize=7.5)
a1.set_title('(a) 单矩阵改 W8 的验证精度变化（其余 71 个 W4）', loc='left', fontsize=9)

x = [g[2] for g in GREEDY]
for k, (name, c, m) in enumerate([('验证 4445 条', BLUE, 'o'), ('测试 4890 条', ORANGE, 's')]):
    y = [g[3 + k] for g in GREEDY]
    a2.plot(x, y, color=c, lw=1.6, marker=m, ms=5, label=name, zorder=3)
for g in GREEDY[1:]:
    a2.annotate(g[1], (g[2], g[3]), textcoords='offset points', xytext=(0, 6), ha='center', fontsize=6.5, color=GRAY)
a2.set_xlabel('参数字数增量（%）'); a2.set_ylabel('Top-1 精度（%）')
a2.set_xticks(x); a2.set_xticklabels([f'{v:.1f}' for v in x])
a2.legend(loc='upper center', bbox_to_anchor=(0.5, -0.2), ncol=2, handlelength=1.6, columnspacing=1.0)
a2.set_ylim(96.6, 97.65)
a2.set_title('(b) 贪心累积（每点均为组合实测）', loc='left', fontsize=9)
fig.tight_layout(w_pad=1.2)
fig.savefig(sys.argv[1] if len(sys.argv) > 1 else os.path.join(os.path.dirname(os.path.abspath(__file__)), '..', 'fig2-2_w8_sensitivity.pdf'))
