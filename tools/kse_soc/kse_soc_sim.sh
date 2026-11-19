#!/bin/bash
# KSE SoC flow: firmware, task data, VCS build and the task regression.
# Outputs go to $KSE_SOC_RUN (default $REPO/run/soc),
# never into the repository.
#
#   kse_soc_sim.sh synfiles                RTL file list for synthesis (stdout)
#   kse_soc_sim.sh fw                      build firmware/kse (riscv-none-elf-gcc)
#   kse_soc_sim.sh data                    pack params + per-task loader images
#   kse_soc_sim.sh build <name>            compile tb_kse_soc into $RUN/<name>
#   kse_soc_sim.sh run <name> [plusargs]   run simv in $RUN/<name> (log: sim.log)
#   kse_soc_sim.sh regress <name> [jobs]   build + configured tasks split over <jobs> simv (default 4)
#
# A run passes only if its log has TEST PASSED and no TEST FAILED / TIMEOUT /
# Error / Fatal / MISMATCH line (checked by check_log below).
set -e
REPO=$(cd "$(dirname "$0")/../.." && pwd)
RUN=${KSE_SOC_RUN:-$REPO/run/soc}
GOLDEN=${KSE_GOLDEN:-$REPO/data/vectors}
DATA=${KSE_DATA:-$REPO/data/vectors}
PY=${KSE_PY:-python3}
E=$REPO/third-party/e203/rtl/e203
K=$REPO/rtl/kse
S=$REPO/rtl/kse_soc
RAM_DEFINES=""
if [ -n "${KSE_PDK_MODELS:-}" ]; then RAM_DEFINES=+define+ARM_UD_MODEL; fi

filelist() {
  echo "+incdir+$E/core"
  echo "+incdir+$E/perips"
  echo "+incdir+$E/perips/apb_i2c"
  # upstream E203, minus the files replaced by the generated kse_ copies
  find "$E" -name '*.v' | sort | grep -v -E '/soc/e203_soc_top\.v$|/subsys/e203_subsys_(top|main|mems|plic)\.v$|/perips/sirv_plic_top\.v$|/perips/apb_uart/apb_uart\.v$|/general/sirv_gnrl_ram\.v$'
  for f in kse_sirv_plic_top kse_e203_subsys_plic kse_e203_subsys_mems kse_e203_subsys_main \
           kse_e203_subsys_top kse_e203_soc_top apb_uart kse_tcm_gnrl_ram; do echo "$S/$f.v"; done
  for f in kse_pkg kse_arith kse_exp_rom kse_gelu_rom kse_post kse_softmax kse_ln kse_mac_array \
           kse_rowstore kse_pfifo kse_loader kse_mm kse_pass kse_top; do echo "$K/$f.sv"; done
  for f in kse_soc_fifo kse_sram_ctrl kse_shared_sram kse_sys_bus kse_eng_icb kse_accel_sys; do echo "$S/$f.sv"; done
  if [ -n "${KSE_PDK_MODELS:-}" ]; then
    for f in $KSE_PDK_MODELS; do echo "$f"; done
  else
    for n in 128 1024 4096; do echo "$REPO/tb/models/RAMSP${n}X16_beh.sv"; done
  fi
  echo "$REPO/tb/kse_soc/kse_param_loader.sv"
  echo "$REPO/tb/kse_soc/tb_kse_soc.sv"
}

check_log() {
  local log=$1
  if grep -qE 'TEST FAILED|TIMEOUT|^Error|Error-\[|^Fatal|Fatal:|MISMATCH|^ERROR' "$log"; then
    echo "FAIL: $log"; grep -nE 'TEST FAILED|TIMEOUT|^Error|Error-\[|^Fatal|Fatal:|MISMATCH|^ERROR' "$log" | head -20; return 1
  fi
  grep -q 'TEST PASSED' "$log" || { echo "FAIL: no TEST PASSED in $log"; return 1; }
  echo "PASS: $log"
}

build() {
  local d=$RUN/$1; mkdir -p "$d"; cd "$d"
  filelist > files.f
  vcs -full64 -sverilog -timescale=1ns/1ps +v2k ${RAM_DEFINES:-} +nospecify +notimingcheck \
      -top tb_kse_soc -f files.f -o simv -l compile.log ${KSE_VCS_OPTS:-} > /dev/null || { tail -30 compile.log; exit 1; }
  if grep -qE 'Error-\[' compile.log; then grep -nE 'Error-\[' compile.log | head; exit 1; fi
  echo "BUILD_OK $d/simv"
}

case "$1" in
  synfiles)
    # synthesis source list: RTL only (no PDK simulation models, no testbench)
    filelist | grep -E "^$REPO/rtl/|^$E/" | grep -v -E '^\+incdir|/tb/'
    ;;
  fw)
    make -C "$REPO/firmware/kse" BUILD="$RUN/fw"
    ;;
  data)
    if [ "$GOLDEN" = "$REPO/data/vectors" ]; then
      test -s "$DATA/params/params.hex" || { echo "Missing bundled vectors; set KSE_GOLDEN to exported golden data" >&2; exit 1; }
      echo "Bundled vectors ready: $DATA (set KSE_GOLDEN to regenerate)"
      exit 0
    fi
    $PY "$REPO/tools/kse/pack_params.py" --profile "$GOLDEN/profile" --output-dir "$DATA/params" --array-r "${KSE_ARRAY_R:-32}" --array-c "${KSE_ARRAY_C:-32}"
    $PY "$REPO/tools/kse/pack_params.py" --profile "$GOLDEN/profile" --output-dir "$DATA/params" --array-r "${KSE_ARRAY_R:-32}" --array-c "${KSE_ARRAY_C:-32}" --verify
    $PY -I "$REPO/tools/kse_soc/gen_soc_data.py" --golden "$GOLDEN" --params "$DATA/params/params.bin" --out "$DATA/tasks" --samples "${KSE_SOC_SAMPLES:-0,2}"
    ;;
  build)
    build "$2"
    ;;
  run)
    B=$2; shift 2
    cd "$RUN/$B"
    ./simv +DATA="$DATA/tasks" +FW="$RUN/fw/kse_fw.itcm.hex" +LOADER_IMAGE="$DATA/tasks/task_00_img.hex" +NTASK="${KSE_TASKS:-2}" "$@" > sim.log 2>&1 || true
    check_log sim.log
    ;;
  regress)
    B=$2; J=${3:-4}
    build "$B"
    cd "$RUN/$B"
    N=$(( (${KSE_TASKS:-2} + J - 1) / J )); logs=""
    for ((k = 0; k < J; k++)); do
      t0=$((k * N)); n=$(( ${KSE_TASKS:-2} - t0 < N ? ${KSE_TASKS:-2} - t0 : N ))
      [ $n -le 0 ] && continue
      ./simv +DATA="$DATA/tasks" +FW="$RUN/fw/kse_fw.itcm.hex" +LOADER_IMAGE="$DATA/tasks/task_00_img.hex" \
             +TASK0=$t0 +NTASK=$n > part$k.log 2>&1 &
      logs="$logs part$k.log"
    done
    wait
    ok=1
    for l in $logs; do check_log "$l" || ok=0; done
    python3 "$REPO/tools/kse_soc/sum_soc_logs.py" "${KSE_TASKS:-2}" $logs | tee summary.log
    [ $ok = 1 ] && grep -q '^REGRESSION PASSED' summary.log
    ;;
  *)
    echo "usage: $0 fw|data|build|run|regress" >&2; exit 2;;
esac
