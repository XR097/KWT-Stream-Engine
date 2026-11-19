"""matplotlib 图的统一样式：Noto Sans CJK SC，灰蓝配色。"""
import os
import matplotlib
matplotlib.use('pdf')
import matplotlib.pyplot as plt
from matplotlib import font_manager as fm

FONT_DIR = '/usr/share/fonts/opentype/noto/'
if not os.path.exists(os.path.join(FONT_DIR, 'NotoSansCJK-Regular.ttc')):
    FONT_DIR = '/usr/share/fonts/google-noto-cjk/'
for f in ('NotoSansCJK-Regular.ttc', 'NotoSansCJK-Bold.ttc'):
    path = os.path.join(FONT_DIR, f)
    if os.path.exists(path):
        fm.fontManager.addfont(path)

BLUE, ORANGE, PURPLE = '#2E6DA4', '#C9732E', '#8A5BB0'   # 已用 dataviz 校验脚本验证（含色觉缺陷）
INK, GRAY, GRID = '#25303B', '#5B6670', '#D9DDE1'

plt.rcParams.update({
    'font.family': ['Noto Sans CJK SC'],
    'font.size': 9, 'axes.titlesize': 10, 'axes.labelsize': 9,
    'xtick.labelsize': 8.5, 'ytick.labelsize': 8.5, 'legend.fontsize': 8.5,
    'axes.edgecolor': GRAY, 'axes.labelcolor': INK, 'text.color': INK,
    'xtick.color': GRAY, 'ytick.color': GRAY, 'axes.linewidth': 0.7,
    'axes.spines.top': False, 'axes.spines.right': False,
    'axes.grid': True, 'grid.color': GRID, 'grid.linewidth': 0.5,
    'axes.axisbelow': True, 'legend.frameon': False,
    'axes.unicode_minus': False, 'pdf.fonttype': 42,
    'savefig.bbox': 'tight', 'savefig.pad_inches': 0.03,
})
