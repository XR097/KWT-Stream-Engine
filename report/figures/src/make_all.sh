#!/usr/bin/env bash
# 一键重新生成 report/figures/ 下全部插图。
#   TikZ 框图：fig*.tex（standalone，tectonic 编译，共用 common.tex）
#   数据图：fig*.py（matplotlib，共用 figstyle.py）
# 用法：bash report/figures/src/make_all.sh [图名前缀...]   例：make_all.sh fig3-3 fig5_1
set -euo pipefail
cd "$(dirname "$0")"
OUT=..
PY=${PY:-$HOME/.venvs/figs/bin/python}     # 需安装 matplotlib
TECTONIC=${TECTONIC:-$(command -v tectonic || echo "$HOME/.local/bin/tectonic")}
want() { [ $# -eq 0 ] && return 0; local f=$1; shift; for p in $PATTERNS; do [[ $f == $p* ]] && return 0; done; return 1; }
PATTERNS="$*"
for f in fig[0-9]*.tex; do
  [ -n "$PATTERNS" ] && ! want "$f" && continue
  echo "[tex] $f"
  log=$("$TECTONIC" -o "$OUT" "$f" 2>&1); rc=$?
  printf '%s\n' "$log" | grep -E -i "error|missing character|^!" || true
  [ $rc -eq 0 ] || { echo "tectonic failed: $f (rc=$rc)" >&2; exit 1; }
done
for f in fig[0-9]*.py; do
  [ -n "$PATTERNS" ] && ! want "$f" && continue
  echo "[py ] $f"
  "$PY" "$f"
done
ls -1 "$OUT"/*.pdf
