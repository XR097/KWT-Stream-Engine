#!/bin/bash
# KSE VCS regression helper.  All outputs go to $KSE_RUN (default
# $REPO/run/kse), never into the repository.
#
#   kse_sim.sh data [samples]        # pack params, generate unit vectors and sample hex (default 0,1)
#   kse_sim.sh units                 # compile + run the 4 unit testbenches
#   kse_sim.sh top <build> [simv plusargs...]   # compile tb_kse_top into $KSE_RUN/<build> and run
#   kse_sim.sh network <build> [jobs]           # configured samples x 12 layers, all taps, <jobs> parallel simv (default 4)
set -e
REPO=$(cd "$(dirname "$0")/../.." && pwd)
RUN=${KSE_RUN:-$REPO/run/kse}
GOLDEN=${KSE_GOLDEN:-$REPO/data/vectors}
DATA=${KSE_DATA:-$REPO/data/vectors}
PY=${KSE_PY:-python3}
R=$REPO/rtl/kse
RAM_V="$REPO/tb/models/RAMSP1024X16_beh.sv $REPO/tb/models/RAMSP128X16_beh.sv"
if [ -n "${KSE_PDK_MODELS:-}" ]; then RAM_V="$KSE_PDK_MODELS"; RAM_DEFINES=+define+ARM_UD_MODEL; fi
UNIT_RTL="$R/kse_arith.sv $R/kse_exp_rom.sv $R/kse_gelu_rom.sv $R/kse_post.sv $R/kse_softmax.sv $R/kse_ln.sv $R/kse_mac_array.sv"
TOP_RTL="$R/kse_pkg.sv $UNIT_RTL $R/kse_rowstore.sv $R/kse_pfifo.sv $R/kse_loader.sv $R/kse_mm.sv $R/kse_pass.sv $R/kse_top.sv $RAM_V"
VCS="vcs -full64 -sverilog -timescale=1ns/1ps"

case "$1" in
  data)
    if [ "$GOLDEN" = "$REPO/data/vectors" ]; then
      test -s "$DATA/params/params.hex" || { echo "Missing bundled vectors; set KSE_GOLDEN to exported golden data" >&2; exit 1; }
      echo "Bundled vectors ready: $DATA (set KSE_GOLDEN to regenerate)"
      exit 0
    fi
    S=${2:-0,1}
    $PY "$REPO/tools/kse/pack_params.py" --profile "$GOLDEN/profile" --output-dir "$DATA/params" --array-r "${KSE_ARRAY_R:-32}" --array-c "${KSE_ARRAY_C:-32}"
    $PY "$REPO/tools/kse/gen_tb_data.py" --golden "$GOLDEN" --out "$DATA/units" units
    $PY "$REPO/tools/kse/gen_tb_data.py" --golden "$GOLDEN" --out "$DATA/samples" samples --samples "$S"
    ;;
  units)
    for u in post:tb_post softmax:tb_softmax ln:tb_ln mac_array:tb_mac_array; do
      n=${u%%:*}; top=${u##*:}
      d=$RUN/units/$n; mkdir -p "$d"; cd "$d"
      # softmax / LN cores are tested with the lane count used in kse_top
      PV=""; case $top in tb_softmax|tb_ln) PV="-pvalue+$top.LANES=${KSE_LANES:-8}";; esac
      $VCS -top $top -o simv $PV $UNIT_RTL "$REPO/tb/kse/units/$top.sv" -l compile.log > /dev/null
      ./simv +VEC="$DATA/units/$n.txt" > sim.log 2>&1
      echo "== $n: $(grep -E '^(POST|SOFTMAX rows|LN tokens|MAC_ARRAY)' sim.log | head -1) $(grep -E 'TEST (PASSED|FAILED)' sim.log)"
    done
    ;;
  top)
    B=$2; shift 2
    d=$RUN/$B; mkdir -p "$d"; cd "$d"
    $VCS ${RAM_DEFINES:-} +nospecify +notimingcheck -top tb_kse_top -o simv $TOP_RTL ${KSE_VCS_OPTS:-} \
      "$REPO/tb/kse/tb_kse_top.sv" -l compile.log > /dev/null
    ./simv +DATA="$DATA" "$@"
    ;;
  network)
    B=$2; J=${3:-4}
    d=$RUN/$B; mkdir -p "$d"; cd "$d"
    $VCS ${RAM_DEFINES:-} +nospecify +notimingcheck -top tb_kse_top -o simv $TOP_RTL ${KSE_VCS_OPTS:-} \
      "$REPO/tb/kse/tb_kse_top.sv" -l compile.log > /dev/null
    N=$(( (${KSE_SAMPLES:-2} + J - 1) / J )); logs=""
    for ((k = 0; k < J; k++)); do
      s0=$((k * N)); n=$(( ${KSE_SAMPLES:-2} - s0 < N ? ${KSE_SAMPLES:-2} - s0 : N ))
      [ $n -le 0 ] && continue
      ./simv +DATA="$DATA" +SAMPLE0=$s0 +SAMPLES=$n +LAYERS=12 +OUTALL=1 +TAPS=1 +TIMEOUT=40000000000 > part$k.log 2>&1 &
      logs="$logs part$k.log"
    done
    wait
    python3 "$REPO/tools/kse/sum_logs.py" "${KSE_SAMPLES:-2}" $logs | tee summary.log
    ;;
  *)
    echo "usage: $0 data|units|top|network" >&2; exit 2;;
esac
