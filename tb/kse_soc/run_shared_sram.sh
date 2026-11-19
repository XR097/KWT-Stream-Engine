#!/bin/sh
# Build and run the shared-SRAM tests.
#
#   ./run_shared_sram.sh          behavioral macro model (RAMSP4096X16_beh)
#   ./run_shared_sram.sh --pdk    PDK macro model (ARM_UD_MODEL)
#
# The script fails on a missing TEST PASSED as well as on any TEST FAILED,
# TIMEOUT, Error, Fatal or assertion marker in the compile/simulation logs.
set -eu

here=$(cd "$(dirname "$0")" && pwd)
repo=$(cd "$here/../.." && pwd)

pdk=0
if [ "${1:-}" = "--pdk" ]; then
  pdk=1
fi

if [ "$pdk" = 1 ]; then
  sram_v="${PDK_SRAM_V:?Set PDK_SRAM_V to your SRAM model}"
  defines="+define+ARM_UD_MODEL"
  opts="+nospecify +notimingcheck"
  out="${KSE_SRAM_RUN:-$repo/run/kse_ss_pdk_sim}"
else
  sram_v="$repo/tb/models/RAMSP4096X16_beh.sv"
  defines=""
  opts=""
  out="${KSE_SRAM_RUN:-$repo/run/kse_ss_sim}"
fi

mkdir -p "$out"
cd "$out"

srcs="$repo/third-party/e203/rtl/e203/general/sirv_gnrl_dffs.v
$repo/third-party/e203/rtl/e203/general/sirv_gnrl_bufs.v
$repo/third-party/e203/rtl/e203/general/sirv_gnrl_icbs.v
$repo/third-party/e203/rtl/e203/general/sirv_gnrl_xchecker.v
$repo/rtl/kse_soc/kse_sram_ctrl.sv
$repo/rtl/kse_soc/kse_shared_sram.sv
$repo/rtl/kse_soc/kse_sys_bus.sv
$repo/tb/kse_soc/kse_sram_sys_wrap.sv
$sram_v
$repo/tb/kse_soc/kse_param_loader.sv
$repo/tb/kse_soc/tb_shared_sram.sv
$repo/tb/kse_soc/tb_sram_priority.sv
$repo/tb/kse_soc/tb_sram_restart.sv
$repo/tb/kse_soc/tb_sram_prio_contract.sv"

bad_pattern='TEST FAILED|TIMEOUT|^Error|Error-\[|^Fatal|Fatal:|ASSERT|Assertion'

check_compile() {
  log=$1
  if [ ! -f "$log" ]; then
    echo "FAIL: missing compile log $log"
    exit 1
  fi
  if grep -qE 'Error-\[|^Error|^Fatal|Fatal-' "$log"; then
    echo "FAIL: compile error in $log"
    grep -nE 'Error-\[|^Error|^Fatal|Fatal-' "$log" | head -20
    exit 1
  fi
}

check_sim() {
  log=$1
  name=$2
  if [ ! -f "$log" ]; then
    echo "FAIL: missing simulation log $log"
    exit 1
  fi
  if grep -qE "$bad_pattern" "$log"; then
    echo "FAIL: $name log contains an error/failure marker"
    grep -nE "$bad_pattern" "$log" | head -20
    exit 1
  fi
  if ! grep -q "TEST PASSED" "$log"; then
    echo "FAIL: $name did not print TEST PASSED"
    tail -20 "$log"
    exit 1
  fi
}

run_one() {
  top=$1
  bin=$2
  # shellcheck disable=SC2086
  vcs $defines $opts -full64 -sverilog -timescale=1ns/1ps $srcs \
      -top "$top" -o "$bin" -l "${bin}_vcs.log" \
      || { echo "FAIL: compile $top"; tail -20 "${bin}_vcs.log"; exit 1; }
  check_compile "${bin}_vcs.log"
  "./$bin" -l "${bin}_sim.log" \
      || { echo "FAIL: $top simulation returned nonzero"; check_sim "${bin}_sim.log" "$top"; exit 1; }
  check_sim "${bin}_sim.log" "$top"
  echo "PASS: $top"
}

run_one tb_shared_sram main
run_one tb_sram_priority prio
run_one tb_sram_restart restart
run_one tb_sram_prio_contract contract
echo "ALL SHARED-SRAM TESTS PASSED"
