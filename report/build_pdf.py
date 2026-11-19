#!/usr/bin/env python3
"""把 draft/ch*.md 转成 LaTeX（ElegantPaper 模板）并用 tectonic 编译为 PDF。
用法：python3 build_pdf.py    输出：build/report.tex 与 build/设计报告初稿.pdf"""
import re, glob, os, subprocess, shutil, unicodedata

HERE = os.path.dirname(os.path.abspath(__file__))

def _font_dir():
    for d in ('/usr/share/fonts/opentype/noto', '/usr/share/fonts/google-noto-cjk'):
        if os.path.exists(os.path.join(d, 'NotoSansCJK-Regular.ttc')):
            return d
    return '/usr/share/fonts/opentype/noto'

FONT = 'Path=%s/,Extension=.ttc,FontIndex=2' % _font_dir()
TITLE = 'KSE：KWT-1 端侧推理加速器的设计与实现'
DATE = '2026 年 11 月'

UNI = {'²': r'\textsuperscript{2}', '³': r'\textsuperscript{3}', '⁴': r'\textsuperscript{4}', '⁸': r'\textsuperscript{8}',
       '¹': r'\textsuperscript{1}', '⁻': r'\textsuperscript{$-$}', '₀': r'\textsubscript{0}', 'ᵀ': r'\textsuperscript{T}',
       'µ': r'\textmu{}', 'μ': r'\textmu{}', '→': r'$\rightarrow$', '≥': r'$\geq$', '≤': r'$\leq$', '≈': r'$\approx$',
       '√': r'$\surd$', '÷': r'$\div$', '×': r'$\times$', '±': r'$\pm$', '−': r'$-$', 'Σ': r'$\Sigma$', 'Δ': r'$\Delta$',
       'γ': r'$\gamma$', 'δ': r'$\delta$', 'β': r'$\beta$', 'ε': r'$\varepsilon$', '°': r'\textdegree{}', '·': r'$\cdot$'}
ESC = {'\\': r'\textbackslash{}', '&': r'\&', '%': r'\%', '$': r'\$', '#': r'\#', '_': r'\_', '{': r'\{', '}': r'\}',
       '~': r'\textasciitilde{}', '^': r'\textasciicircum{}', '<': r'\textless{}', '>': r'\textgreater{}'}

def esc(s):
    return ''.join(ESC.get(c) or UNI.get(c) or c for c in s)

def esc_tt(s):
    out = esc(s)
    return re.sub(r'(\\_|/|\.|-)', r'\1\\allowbreak{}', out)

TOKEN = re.compile(r'(\*\*.+?\*\*|`[^`]+`|【[^】]*】|\$[^$]+\$)')
def inline(text):
    out = []
    for part in TOKEN.split(text):
        if not part: continue
        if part.startswith('**') and part.endswith('**'): out.append(r'\textbf{%s}' % inline(part[2:-2]))
        elif part.startswith('`'): out.append(r'\texttt{%s}' % esc_tt(part[1:-1]))
        elif len(part) > 2 and part[0] == '$' and part[-1] == '$': out.append(part)
        elif part.startswith('【'): out.append(r'\todo{%s}' % esc(part))
        elif part.startswith('$') and part.endswith('$') and len(part) > 2: out.append(part)
        else: out.append(esc(part))
    return ''.join(out)

def width(s):
    s = re.sub(r'\*\*|`', '', s)
    return sum(2 if unicodedata.east_asian_width(c) in 'WF' else 1 for c in s)

def table(rows, caption):
    cells = [[c.strip() for c in re.split(r'(?<!\\)\|', r.strip().strip('|'))] for r in rows]
    aligns, data = cells[1], [cells[0]] + cells[2:]
    n = len(data[0])
    data = [(r + [''] * n)[:n] for r in data]
    w = [max(width(r[j]) for r in data) for j in range(n)]
    small = n >= 7
    budget = 106 if small else 88           # 一行可容纳的半角字符数（估计）
    pad = 3 if small else 4
    def al(j):
        a = aligns[j] if j < len(aligns) else ''
        return 'r' if a.endswith(':') and not a.startswith(':') else ('c' if a.startswith(':') and a.endswith(':') else 'l')
    fit = sum(w) + pad * n <= budget
    spec = []
    if fit:
        spec = [al(j) for j in range(n)]
    else:
        # 窄列保持自然宽度，其余列按内容长度分配剩余宽度
        order = sorted(range(n), key=lambda j: w[j])
        fixed, remain = set(), budget - pad * n
        for j in order:
            share = remain / max(1, n - len(fixed))
            if w[j] <= share and len(fixed) < n - 1:
                fixed.add(j); remain -= w[j]
        flex = [j for j in range(n) if j not in fixed]
        tot = sum(min(w[j], 80) for j in flex)
        for j in range(n):
            if j in fixed: spec.append(al(j))
            else:
                hs = min(w[j], 80) / tot * len(flex)
                ra = {'l': r'\raggedright', 'r': r'\raggedleft', 'c': r'\centering'}[al(j)]
                spec.append(r'>{\hsize=%.3f\hsize%s\arraybackslash}X' % (hs, ra))
    L = [r'\begingroup', r'\footnotesize\setlength{\tabcolsep}{3.5pt}' if small else r'\small']
    cap = r'\caption*{%s}\\' % inline(caption) if caption else ''
    if fit:
        L.append(r'\begin{longtable}{%s}' % ''.join(spec))
    else:
        L.append(r'\begin{xltabular}{\textwidth}{%s}' % ''.join(spec))
    head = ' & '.join(r'\textbf{%s}' % inline(c) if c else '' for c in data[0]) + r' \\'
    L += [cap, r'\toprule', head, r'\midrule', r'\endfirsthead', r'\toprule', head, r'\midrule', r'\endhead',
          r'\bottomrule', r'\endfoot']
    for r in data[1:]:
        L.append(' & '.join(inline(c) for c in r) + r' \\')
    L += [r'\end{longtable}' if fit else r'\end{xltabular}', r'\endgroup', '']
    return '\n'.join(L)

# 插图：单独一行 ![图 2-1 标题](figures/xxx.pdf)，可在标题末尾或行尾附 {width=0.7}
FIG = re.compile(r'^!\[(.*?)\s*(?:\{width=([\d.]+)\})?\]\(([^)]+)\)\s*(?:\{width=([\d.]+)\})?$')
def figure(m):
    cap, path, w = m.group(1).strip(), m.group(3).strip(), m.group(2) or m.group(4)
    full = path if path.startswith('/') else os.path.join(HERE, path)
    if not os.path.exists(full):
        print('警告：图片不存在', full)
        return r'\figtodo{%s（缺少 %s）}' % (esc(cap), esc(path))
    wd = r'%s\linewidth' % w if w else r'\linewidth'
    texpath = os.path.relpath(full, os.path.join(HERE, 'build'))
    return '\n'.join([r'\begin{figure}[htbp]', r'\centering',
                      r'\includegraphics[width=%s,height=0.42\textheight,keepaspectratio]{\detokenize{%s}}' % (wd, texpath),
                      r'\caption*{%s}' % inline(cap), r'\end{figure}', ''])

def convert(md):
    lines, out, i, cap = md.split('\n'), [], 0, None
    while i < len(lines):
        ln = lines[i].rstrip()
        if not ln.strip(): i += 1; continue
        # 行间公式：单独一行 $$ LaTeX $$ (2-1)
        m = re.match(r'^\$\$(.+?)\$\$\s*(?:[（(]([\w.-]+)[）)])?\s*$', ln.strip())
        if m:
            tag = r'\tag{%s}' % m.group(2) if m.group(2) else ''
            out.append(r'\begin{equation*}%s %s\end{equation*}' % (m.group(1).strip(), tag)); i += 1; continue
        m = re.match(r'^(#{1,3})\s+(.*)', ln)
        if m:
            lv, t = len(m.group(1)), m.group(2).strip()
            cmd = ['section', 'subsection', 'subsubsection'][lv - 1]
            m2 = re.match(r'^(\d+(?:\.\d+)*)\s+(.*)', t)
            if m2:
                if lv == 1: out.append(r'\clearpage')
                out.append(r'\%s{%s}' % (cmd, inline(m2.group(2))))
            else:
                if lv == 1 and t != '摘要': out.append(r'\clearpage')
                out.append(r'\%s*{%s}' % (cmd, inline(t)))
                out.append(r'\addcontentsline{toc}{%s}{%s}' % (cmd, inline(t)))
            i += 1; continue
        if ln.lstrip().startswith('|'):
            j = i
            while j < len(lines) and lines[j].lstrip().startswith('|'): j += 1
            out.append(table(lines[i:j], cap)); cap = None; i = j; continue
        if re.match(r'^表\s*\d+-\d+\s', ln) and width(ln) < 110:
            cap = ln.strip(); i += 1; continue
        m = re.match(r'^\s*[-*]\s+(.*)', ln)
        if m:
            out.append(r'\begin{itemize}')
            while i < len(lines) and re.match(r'^\s*[-*]\s+(.*)', lines[i]):
                out.append(r'\item ' + inline(re.match(r'^\s*[-*]\s+(.*)', lines[i]).group(1))); i += 1
            out.append(r'\end{itemize}'); continue
        m = re.match(r'^\s*\d+\.\s+(.*)', ln)
        if m:
            out.append(r'\begin{enumerate}')
            while i < len(lines) and re.match(r'^\s*\d+\.\s+(.*)', lines[i]):
                out.append(r'\item ' + inline(re.match(r'^\s*\d+\.\s+(.*)', lines[i]).group(1))); i += 1
            out.append(r'\end{enumerate}'); continue
        m = FIG.match(ln.strip())
        if m:
            out.append(figure(m)); i += 1; continue
        if re.match(r'^【图[^】]*】$', ln.strip()):
            out.append(r'\figtodo{%s}' % esc(ln.strip()[1:-1])); i += 1; continue
        m = re.match(r'^\[(\d+)\]\s+(.*)', ln)
        if m:
            out.append(r'\refitem{%s}{%s}' % (m.group(1), inline(m.group(2)))); i += 1; continue
        out.append(inline(ln.strip()) + '\n'); i += 1
    return '\n'.join(out)

PRE = r'''\documentclass[lang=cn,a4paper,11pt,chinesefont=nofont]{elegantpaper}
\setCJKmainfont{NotoSerifCJK-Regular}[%(F)s,BoldFont=NotoSansCJK-Bold,BoldFeatures={FontIndex=2},ItalicFont=NotoSerifCJK-Regular,ItalicFeatures={FontIndex=2}]
\setCJKsansfont{NotoSansCJK-Regular}[%(F)s,BoldFont=NotoSansCJK-Bold,BoldFeatures={FontIndex=2}]
\setCJKmonofont{NotoSansCJK-Regular}[%(F)s]
\usepackage{xltabular,array,enumitem,textcomp,fancyhdr,tcolorbox,graphicx}
\geometry{left=2.6cm,right=2.6cm,top=2.8cm,bottom=2.6cm,headheight=15pt,headsep=14pt}
\setlength{\parindent}{2em}\setlength{\parskip}{0.35em}
\linespread{1.25}
\setlist{leftmargin=2.6em,itemsep=0.15em,topsep=0.3em}
\setlength{\LTpre}{0.6em}\setlength{\LTpost}{0.8em}
\renewcommand{\arraystretch}{1.25}
\captionsetup{font=small,labelfont=bf,skip=4pt}
\newcommand{\todo}[1]{\textcolor{red!75!black}{#1}}
\newcommand{\figtodo}[1]{\begin{center}\begin{tcolorbox}[width=0.86\textwidth,colback=black!3,colframe=black!35,boxrule=0.5pt,arc=2pt,halign=center]\small\color{black!60}#1\end{tcolorbox}\end{center}}
\newcommand{\refitem}[2]{\par\noindent\hangindent=2.2em\hangafter=1\makebox[2.2em][l]{[#1]}#2\par}
\pagestyle{fancy}\fancyhf{}
\fancyhead[L]{\small %(T)s}\fancyhead[R]{\small 作品设计报告}
\fancyfoot[C]{\small\thepage}
\renewcommand{\headrulewidth}{0.4pt}
\setcounter{tocdepth}{2}
\emergencystretch=2em
\begin{document}
\hypersetup{pdfauthor={},pdftitle={%(T)s},pdfsubject={KSE 设计报告}}
\begin{titlepage}
\centering
\vspace*{0.6cm}
\includegraphics[width=5.6cm]{\detokenize{%(LOGO)s}}\par
\vspace{2.4cm}
{\fontsize{30}{38}\selectfont\bfseries 作品设计报告\par}
\vfill
{\fontsize{15}{22}\selectfont\renewcommand{\arraystretch}{1.8}
\begin{tabular}{@{}>{\fontsize{15}{22}\selectfont}l@{\hspace{1em}}>{\fontsize{15}{22}\selectfont\centering\arraybackslash}p{11cm}@{}}
作品名称： & %(TC1)s \\ \cline{2-2}
 & %(TC2)s \\ \cline{2-2}
\end{tabular}\par}
\vspace{2.2cm}
{\fontsize{15}{22}\selectfont 日期：%(D)s\par}
\vspace{1.5cm}
\end{titlepage}
\pagenumbering{roman}
%(ABS)s
\clearpage
\tableofcontents
\clearpage
\pagenumbering{arabic}
'''

def main():
    files = sorted(glob.glob(os.path.join(HERE, 'draft', 'ch*.md')), key=lambda f: int(re.search(r'ch(\d+)', f).group(1)))
    md = '\n\n'.join(open(f, encoding='utf-8').read() for f in files)
    a = md.index('# 1 引言')
    T = esc(TITLE)
    logo = os.path.relpath(os.path.join(HERE, 'figures', 'cover_logo.png'), os.path.join(HERE, 'build'))
    tex = PRE % dict(F=FONT, T=T, TC1=T.split('：', 1)[0], TC2=T.split('：', 1)[-1], D=DATE, LOGO=logo, ABS=convert(md[:a]))
    body = convert(md[a:]).replace(r'\clearpage', '', 1)
    tex += body + '\n\\end{document}\n'
    d = os.path.join(HERE, 'build'); os.makedirs(d, exist_ok=True)
    open(os.path.join(d, 'report.tex'), 'w', encoding='utf-8').write(tex)
    r = subprocess.run(['tectonic', 'report.tex'], cwd=d, capture_output=True, text=True)
    msgs = [l for l in (r.stdout + r.stderr).split('\n') if 'downloading' not in l and l.strip()]
    print('\n'.join(msgs[-12:]))
    if r.returncode == 0:
        os.replace(os.path.join(d, 'report.pdf'), os.path.join(d, '设计报告初稿.pdf'))
        print('OK ->', os.path.join(d, '设计报告初稿.pdf'))

if __name__ == '__main__':
    main()
