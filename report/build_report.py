#!/usr/bin/env python3
"""把 draft/ch*.md 合成为报告 docx（保留模板封面）。用法：python3 build_report.py"""
import re, glob, os
from docx import Document
from docx.shared import Pt, RGBColor
from docx.enum.text import WD_ALIGN_PARAGRAPH, WD_BREAK
from docx.enum.table import WD_TABLE_ALIGNMENT
from docx.oxml.ns import qn
from docx.oxml import OxmlElement

HERE = os.path.dirname(os.path.abspath(__file__))
TEMPLATE = os.environ.get('REPORT_TEMPLATE', '')   # 可选：指向单位模板 .docx
OUT = os.path.join(HERE, 'build', '设计报告初稿.docx')
os.makedirs(os.path.dirname(OUT), exist_ok=True)
TITLE = 'KSE：KWT-1 端侧推理加速器的设计与实现'

doc = Document(TEMPLATE) if TEMPLATE else Document()

def set_font(run, size=None, bold=None, east='宋体', west='Times New Roman', color=None):
    run.font.name = west
    rpr = run._element.get_or_add_rPr()
    rf = rpr.find(qn('w:rFonts'))
    if rf is None:
        rf = OxmlElement('w:rFonts'); rpr.append(rf)
    rf.set(qn('w:eastAsia'), east); rf.set(qn('w:ascii'), west); rf.set(qn('w:hAnsi'), west)
    if size: run.font.size = Pt(size)
    if bold is not None: run.font.bold = bold
    if color: run.font.color.rgb = color

TOKEN = re.compile(r'(\*\*.+?\*\*|`[^`]+`|【[^】]*】)')
def add_inline(p, text, size=10.5, bold=False):
    for part in TOKEN.split(text):
        if not part: continue
        if part.startswith('**') and part.endswith('**'):
            set_font(p.add_run(part[2:-2]), size, True)
        elif part.startswith('`') and part.endswith('`'):
            set_font(p.add_run(part[1:-1]), size, bold, west='Consolas')
        elif part.startswith('【'):
            set_font(p.add_run(part), size, bold, color=RGBColor(0xC0, 0x00, 0x00))
        else:
            set_font(p.add_run(part), size, bold)

def body(text, indent=True, align=None, size=10.5):
    p = doc.add_paragraph()
    pf = p.paragraph_format
    pf.line_spacing = 1.35; pf.space_after = Pt(4)
    if indent: pf.first_line_indent = Pt(size * 2)
    if align is not None: p.alignment = align
    add_inline(p, text, size)
    return p

def heading(text, level):
    p = doc.add_paragraph(style='Heading %d' % level)
    for r in list(p.runs): r._element.getparent().remove(r._element)
    set_font(p.add_run(text), {1: 16, 2: 14, 3: 12}[level], True, east='黑体', color=RGBColor(0, 0, 0))
    p.paragraph_format.space_before = Pt(12 if level == 1 else 8)
    p.paragraph_format.space_after = Pt(6)
    return p

def borders(tbl):
    pr = tbl._tbl.tblPr
    b = OxmlElement('w:tblBorders')
    for e in ('top', 'left', 'bottom', 'right', 'insideH', 'insideV'):
        x = OxmlElement('w:' + e)
        x.set(qn('w:val'), 'single'); x.set(qn('w:sz'), '4'); x.set(qn('w:space'), '0'); x.set(qn('w:color'), '000000')
        b.append(x)
    pr.append(b)

def table(rows):
    cells = [[c.strip() for c in r.strip().strip('|').split('|')] for r in rows]
    aligns = cells[1]; data = [cells[0]] + cells[2:]
    n = len(data[0])
    t = doc.add_table(rows=len(data), cols=n)
    t.alignment = WD_TABLE_ALIGNMENT.CENTER
    borders(t)
    for i, row in enumerate(data):
        for j in range(n):
            txt = row[j] if j < len(row) else ''
            p = t.cell(i, j).paragraphs[0]
            a = aligns[j] if j < len(aligns) else ''
            p.alignment = WD_ALIGN_PARAGRAPH.CENTER if i == 0 else (
                WD_ALIGN_PARAGRAPH.RIGHT if a.endswith(':') and not a.startswith(':') else WD_ALIGN_PARAGRAPH.LEFT)
            add_inline(p, txt, 9, bold=(i == 0))
    doc.add_paragraph().paragraph_format.space_after = Pt(2)

def page_break():
    doc.add_paragraph().add_run().add_break(WD_BREAK.PAGE)

# 封面：模板填作品名称；无模板时生成简单封面
if TEMPLATE:
    for p in doc.paragraphs:
        if p.text.startswith('作品名称'):
            p.runs[1].text = TITLE
            p.runs[1].font.size = Pt(9)
else:
    p = doc.add_paragraph()
    p.alignment = WD_ALIGN_PARAGRAPH.CENTER
    set_font(p.add_run(TITLE), 18, True, east='黑体')
    doc.add_paragraph()

files = sorted(glob.glob(os.path.join(HERE, 'draft', 'ch*.md')), key=lambda f: int(re.search(r'ch(\d+)', f).group(1)))
first = True
for f in files:
    lines = open(f, encoding='utf-8').read().split('\n')
    i = 0
    while i < len(lines):
        ln = lines[i].rstrip()
        if not ln.strip(): i += 1; continue
        m = re.match(r'^(#{1,3})\s+(.*)', ln)
        if m:
            lv = len(m.group(1))
            if lv == 1 and not first: page_break()
            first = False
            heading(m.group(2), lv); i += 1; continue
        if ln.lstrip().startswith('|'):
            j = i
            while j < len(lines) and lines[j].lstrip().startswith('|'): j += 1
            table(lines[i:j]); i = j; continue
        m = re.match(r'^\s*[-*]\s+(.*)', ln)
        if m:
            p = body('• ' + m.group(1), indent=False); p.paragraph_format.left_indent = Pt(21); i += 1; continue
        m = re.match(r'^\s*(\d+)\.\s+(.*)', ln)
        if m:
            p = body('%s. %s' % (m.group(1), m.group(2)), indent=False); p.paragraph_format.left_indent = Pt(21); i += 1; continue
        if re.match(r'^(表|图)\s*\d+-\d+\s', ln) and len(ln) < 60:
            body(ln, indent=False, align=WD_ALIGN_PARAGRAPH.CENTER, size=9.5); i += 1; continue
        if re.match(r'^【图[^】]*】$', ln.strip()):
            body(ln.strip(), indent=False, align=WD_ALIGN_PARAGRAPH.CENTER); i += 1; continue
        body(ln.strip()); i += 1

doc.save(OUT)
print('saved', OUT)
