"""图 5-1：KSE 计分面积按逻辑功能划分的饼图（数据来自 KSE 整 SoC 综合层次面积报告，单位 µm²，各项含其中的 SRAM 宏）。"""
import math
import sys
from pathlib import Path
from figstyle import plt

PARTS = [  # (名称, 面积 µm², 颜色)；层次面积取自整 SoC 综合 area_hier
    ('MAC 阵列（32×32）', 605_661.65, '#2E6DA4'),
    ('行存储 A/B', 146_389.80 + 146_388.60, '#E08A2E'),
    ('LayerNorm 单元', 152_494.21, '#3A9A5B'),
    ('Softmax 单元', 69_534.21, '#8A5BB0'),
    ('参数通路（预取 FIFO、参数分发）', 27_329.35 + 25_696.00, '#C8463D'),
    ('后处理与矩阵定序（重定标、残差、GELU）', 652_706.15 - 605_661.65, '#2BA6A6'),
    ('层控制与系统接口（包装/DMA、总线仲裁、进度寄存器、PLIC 增量）',
     8_742.41 + 6_583.26 + 200.38 + 505.61 + 333.24 + 63.44, '#8C96A0'),
]
total = sum(v for _, v, _ in PARTS)
fig, ax = plt.subplots(figsize=(6.4, 3.2))
ax.grid(False)
wedges, _ = ax.pie([v for _, v, _ in PARTS], colors=[c for *_, c in PARTS], startangle=90,
                   counterclock=False, wedgeprops=dict(edgecolor='white', linewidth=1.2))
for w, (_, v, _) in zip(wedges, PARTS):   # 占比不小于 5% 的扇区内标百分比
    if v / total >= 0.05:
        a = math.radians((w.theta1 + w.theta2) / 2)
        ax.text(0.72 * math.cos(a), 0.72 * math.sin(a), f'{v / total * 100:.1f}%',
                ha='center', va='center', fontsize=8, color='white', fontweight='bold')
labels = [f'{n}  {v / 1e6:.4f} mm²（{v / total * 100:.1f}%）' for n, v, _ in PARTS]
ax.legend(wedges, labels, loc='center left', bbox_to_anchor=(1.0, 0.5))
ax.set_aspect('equal')
out = Path(sys.argv[1]) if len(sys.argv) > 1 else Path(__file__).resolve().parents[1] / 'fig5-1_area_pie.pdf'
fig.savefig(out)
print(out)
