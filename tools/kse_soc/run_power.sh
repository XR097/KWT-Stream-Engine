#!/bin/bash
# Fresh, serial PrimePower sessions; preserve each activity sensitivity report.
# Usage: run_power.sh <synthesis-dir> <merged-saif> <new-output-dir>
set -euo pipefail
REPO=$(cd "$(dirname "$0")/../.." && pwd)
SYN=$(realpath "$1"); SAIF=$(realpath "$2"); OUT=$(realpath -m "$3")
mkdir -p "$OUT"
export KSE_NETLIST="$SYN/kse_soc_mapped.v" KSE_SDC="$SYN/kse_soc_mapped.sdc"
: "${SYNOPSYS_LC_ROOT:?Set SYNOPSYS_LC_ROOT to your Library Compiler installation}"
export SYNOPSYS_LC_ROOT
export KSE_MAP="$SYN/kse_soc_saif_map.ptpx.tcl" KSE_SAIF="$SAIF"
sha256sum "$KSE_NETLIST" "$KSE_SDC" "$KSE_MAP" "$KSE_SAIF" > "$OUT/inputs.sha256"
git -C "$REPO" rev-parse HEAD > "$OUT/source_commit.txt"
for rate in 0.1 0.0 0.2; do
  # The complete SoC flow shares a 31G host. Check every fresh PT session,
  # including sessions inside a caller's 16G systemd scope.
  while [ "$(awk '/MemAvailable/{print $2}' /proc/meminfo)" -lt 18874368 ]; do sleep 5; done
  awk '/MemAvailable/{print}' /proc/meminfo
  d="$OUT/tr_$rate"
  mkdir "$d"
  (cd "$d"; KSE_DEFAULT_TR=$rate pt_shell -f "$REPO/tools/kse_soc/power_soc.tcl" < /dev/null > pt.log 2>&1)
  grep -q '^POWER_DONE ' "$d/pt.log"
  if grep -E '^Error:|^POWER_FAIL' "$d/pt.log"; then
    echo "POWER_FAIL: inspect $d/pt.log" >&2; exit 1
  fi
  echo "POWER_RUN_DONE rate=$rate dir=$d"
  python3 - "$d/timing_metrics.tsv" <<'CHECK'
import csv, sys, re
from pathlib import Path
rows = list(csv.DictReader(open(sys.argv[1]), delimiter='\t'))
accel = [r for r in rows if r['group'] in ('accel', 'accel_launch_any')]
assert {r['analysis'] for r in accel} == {'max', 'min'}, 'missing accelerator timing'
assert all(float(r['slack_ns']) >= 0 for r in accel), 'accelerator timing failed: inspect reports before accepting power'
# PT get_attribute slack can round to six decimals. Check the full path
# reports too, so a small negative value is never accepted as rounded zero.
root = Path(sys.argv[1]).parent
for name in ('timing_setup_accel.rpt', 'timing_hold_accel.rpt', 'timing_accel_launch_max.rpt', 'timing_accel_launch_min.rpt'):
    values = re.findall(r'slack \(\w+\)\s+([+-]?\d+\.\d+)', (root / name).read_text())
    assert values and all(float(v) >= 0 for v in values), f'accelerator timing failed or absent: {name}'
CHECK
done
