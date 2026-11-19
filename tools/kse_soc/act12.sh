#!/bin/bash
# Activity of the 12 scoring windows for power analysis, at real 150 MHz time.
# Per task: run the FSDB-enabled simv on that task only (window dumping only),
# convert exactly the window [on, off] to SAIF with fsdb2saif, delete the FSDB;
# then sum the 12 window SAIFs (merge_saif.py).  Needs a simv built with
#   KSE_VCS_OPTS="+define+KSE_FSDB -debug_access+r" kse_soc_sim.sh build fsdb
# usage: act12.sh [jobs]   (outputs in $RUN/act12)
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
RUN=${KSE_SOC_RUN:-$REPO/run/soc}
DATA=${KSE_DATA:-$REPO/data/vectors}
J=${1:-2}
ACT_DIR=${KSE_ACT_DIR:-$RUN/act12}
[[ $J =~ ^[1-2]$ ]] || { echo "jobs must be 1..2" >&2; exit 2; }
one() {
  set -euo pipefail
  t=$1; d=$ACT_DIR/t$(printf %02d $t); rm -rf "$d"; mkdir -p "$d"; cd "$d"
  while [ "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" -lt 18874368 ]; do sleep 5; done
  "$RUN/fsdb/simv" +DATA="$DATA/tasks" +FW="$RUN/fw/kse_fw.itcm.hex" +LOADER_IMAGE="$DATA/tasks/task_00_img.hex" \
     +TASK0=$t +NTASK=1 +CLK_HALF_NS=3.3335 +ACT=fsdb +ACT_TASK=-1 +ACT_FILE=win.fsdb > sim.log 2>&1
  grep -q "TEST PASSED" sim.log || { echo "FAIL task $t sim"; return 1; }
  bt=$(grep -m1 "ACTIVITY fsdb on" sim.log | sed 's/.*t_ns=//'); et=$(grep -m1 "ACTIVITY fsdb off" sim.log | sed 's/.*t_ns=//')
  fsdb2saif win.fsdb -flatten_genhier -bt ${bt}ns -et ${et}ns -s /tb_kse_soc/u_soc -o win.saif > f2s.log 2>&1
  test -s win.saif
  rm -f win.fsdb
  echo "task $t window $bt..$et ns signals $(grep -c '(TC ' win.saif)"
}
export -f one; export RUN ACT_DIR DATA
seq "${KSE_FIRST_TASK:-0}" 11 | xargs -P $J -I{} bash -lc 'one {}'
inputs=()
for t in {00..11}; do inputs+=("$ACT_DIR/t$t/win.saif"); done
python3 "$REPO/tools/kse_soc/merge_saif.py" "$ACT_DIR/soc_12win.saif" "${inputs[@]}"
