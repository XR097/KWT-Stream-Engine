#!/usr/bin/env bash
# Compile only: never execute generated simulation binaries.
set -uo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/..}" && pwd)
BUILD=${KSE_CHECK_RUN:-$(mktemp -d "${TMPDIR:-/tmp}/kse-compile.XXXXXX")}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
failed=0
declare -A FSDB_TOP=(
  [tb_kse_soc_uvm]=1 [tb_kse_subsystem_uvm]=1 [tb_kse_shared_uvm]=1
  [tb_kse_fault_uvm]=1 [tb_kse_stream]=1 [tb_kse_bootstrap]=1 [tb_wp8_ln]=1
)
compile() {
  local top=$1; shift
  local dir="$BUILD/$top"
  mkdir -p "$dir"
  local fsdb_args=()
  if [[ "$top" == tb_kse_soc_uvm && "${KSE_PDK_MODELS:-0}" != 1 ]]; then
    echo "SKIP(needs vendor SRAM models) VCS $top"
    return 0
  fi
  if [[ "${FSDB_TOP[$top]:-0}" == 1 ]]; then
    if [[ -z "${VERDI_HOME:-}" ]]; then
      echo "SKIP(no Verdi) VCS $top"
      return 0
    fi
    local pli="$VERDI_HOME/share/PLI/VCS/LINUX64"
    if [[ ! -f "$pli/novas.tab" || ! -f "$pli/pli.a" ]]; then
      echo "FAIL VCS $top (VERDI_HOME PLI files missing)"
      failed=1
      return 0
    fi
    fsdb_args=(-kdb -debug_access+all -P "$pli/novas.tab" "$pli/pli.a")
  fi
  if (cd "$dir" && vcs -full64 -sverilog -ntb_opts uvm-1.2 -timescale=1ns/1ps +v2k -top "$top" -o simv "${fsdb_args[@]}" "$@" > compile.log 2>&1) &&
     ! grep -Eq 'Error-\[|^Error|^Fatal|Fatal-' "$dir/compile.log" && test -x "$dir/simv"; then
    echo "PASS VCS $top"
  else
    echo "FAIL VCS $top (log: $dir/compile.log)"
    tail -40 "$dir/compile.log"
    failed=1
  fi
}
K=$ROOT/rtl/kse
unit=()
for n in arith exp_rom gelu_rom post softmax ln mac_array; do unit+=("$K/kse_$n.sv"); done
models=("$ROOT"/tb/models/*.sv)
for top in tb_post tb_softmax tb_ln tb_mac_array; do
  compile "$top" "${unit[@]}" "${models[@]}" "$ROOT/tb/kse/units/$top.sv"
done
engine=("$K/kse_pkg.sv" "${unit[@]}")
for n in rowstore pfifo loader mm pass top; do engine+=("$K/kse_$n.sv"); done
compile tb_kse_top "${engine[@]}" "${models[@]}" "$ROOT/tb/kse/tb_kse_top.sv"
# synfiles prints the complete SoC RTL closure; models and TB are supplied here.
if env -u KSE_PDK_MODELS bash "$ROOT/tools/kse_soc/kse_soc_sim.sh" synfiles > "$BUILD/soc.f"; then
 E=$ROOT/third-party/e203/rtl/e203
 compile tb_kse_soc "+incdir+$E/core" "+incdir+$E/perips" "+incdir+$E/perips/apb_i2c" -f "$BUILD/soc.f" "${models[@]}" "$ROOT/tb/kse_soc/kse_param_loader.sv" "$ROOT/tb/kse_soc/tb_kse_soc.sv"
else echo 'FAIL SoC source list'; failed=1; fi
shared=()
for n in dffs bufs icbs xchecker; do shared+=("$ROOT/third-party/e203/rtl/e203/general/sirv_gnrl_$n.v"); done
for n in sram_ctrl shared_sram sys_bus; do shared+=("$ROOT/rtl/kse_soc/kse_$n.sv"); done
shared+=("$ROOT/tb/kse_soc/kse_sram_sys_wrap.sv" "$ROOT/tb/kse_soc/kse_param_loader.sv" "${models[@]}")
for top in tb_shared_sram tb_sram_priority tb_sram_prio_contract tb_sram_restart; do
 compile "$top" "${shared[@]}" "$ROOT/tb/kse_soc/$top.sv"
done
if make -B -C "$ROOT/firmware/kse" BUILD="$BUILD/fw" RISCV_PREFIX="${RISCV_PREFIX:-riscv-none-elf-}" > "$BUILD/firmware.log" 2>&1; then
 echo 'PASS firmware/kse'
else echo "FAIL firmware/kse (log: $BUILD/firmware.log)"; cat "$BUILD/firmware.log"; failed=1; fi
# Redirect bytecode outside the source directories, including quantization.
export PYTHONPYCACHEPREFIX="$BUILD/pycache"
for dir in tools quantization; do
 if [ ! -d "$ROOT/$dir" ]; then echo "SKIP Python $dir (directory absent)"; continue; fi
 while IFS= read -r -d '' path; do
  if python3 -m py_compile "$path" > "$BUILD/python.log" 2>&1; then
   echo "PASS Python ${path#${ROOT}/}"
  else echo "FAIL Python ${path#${ROOT}/}"; cat "$BUILD/python.log"; failed=1; fi
 done < <(find "$ROOT/$dir" -type f -name '*.py' -print0 | sort -z)
done

# UVM top-level compile-only checks (no simulation invocation).
uvm_rtl=("$ROOT/rtl/kse/kse_pkg.sv" "$ROOT/rtl/kse/kse_arith.sv" "$ROOT/rtl/kse/kse_exp_rom.sv" "$ROOT/rtl/kse/kse_gelu_rom.sv" "$ROOT/rtl/kse/kse_post.sv" "$ROOT/rtl/kse/kse_softmax.sv" "$ROOT/rtl/kse/kse_ln.sv" "$ROOT/rtl/kse/kse_mac_array.sv" "$ROOT/rtl/kse/kse_rowstore.sv" "$ROOT/rtl/kse/kse_pfifo.sv" "$ROOT/rtl/kse/kse_loader.sv" "$ROOT/rtl/kse/kse_mm.sv" "$ROOT/rtl/kse/kse_pass.sv" "$ROOT/rtl/kse/kse_top.sv")
uvm_soc=("$ROOT/rtl/kse_soc/kse_soc_fifo.sv" "$ROOT/rtl/kse_soc/kse_sram_ctrl.sv" "$ROOT/rtl/kse_soc/kse_shared_sram.sv" "$ROOT/rtl/kse_soc/kse_sys_bus.sv" "$ROOT/rtl/kse_soc/kse_eng_icb.sv" "$ROOT/rtl/kse_soc/kse_accel_sys.sv")
uvm_pkg=("$ROOT/verification/uvm/kse/kse_icb_if.sv" "$ROOT/verification/uvm/kse/kse_integration_if.sv" "$ROOT/verification/uvm/kse/kse_stream_if.sv" "$ROOT/verification/uvm/kse/kse_fault_if.sv" "$ROOT/verification/uvm/kse/kse_numeric_if.sv" "$ROOT/verification/uvm/kse/strict_bus/strict_bus_if.sv" "$ROOT/verification/uvm/kse/kse_bootstrap_pkg.sv" "$ROOT/verification/uvm/kse/kse_integration_pkg.sv" "$ROOT/verification/uvm/kse/kse_contract_pkg.sv" "$ROOT/verification/uvm/kse/kse_network_pkg.sv" "$ROOT/verification/uvm/kse/kse_stream_pkg.sv" "$ROOT/verification/uvm/kse/kse_fault_pkg.sv" "$ROOT/verification/uvm/kse/kse_numeric_pkg.sv" "$ROOT/verification/uvm/kse/strict_bus/strict_bus_pkg.sv" "$ROOT/verification/uvm/wp8_kse/wp8_ln_if.sv" "$ROOT/verification/uvm/wp8_kse/wp8_ln_pkg.sv" "$ROOT/verification/uvm/wp8_kse/wp8_soc_periph_if.sv" "$ROOT/verification/uvm/wp8_kse/wp8_soc_periph_pkg.sv")
uvm_inc=("+incdir+$ROOT/third-party/e203/rtl/e203/core" "+incdir+$ROOT/third-party/e203/rtl/e203/perips" "+incdir+$ROOT/third-party/e203/rtl/e203/subsys" "+incdir+$ROOT/third-party/e203/rtl/e203/general" "+incdir+$ROOT/third-party/e203/rtl/e203/perips/apb_i2c")
uvm_models=("$ROOT"/tb/models/*.sv)
mapfile -t e203_sources < <(find "$ROOT/third-party/e203/rtl/e203" -type f \( -name "*.v" -o -name "*.sv" \) | sort)
uvm_soc+=("$ROOT/rtl/kse_soc"/*.v "${e203_sources[@]}")
for spec in \
  "tb_kse_soc_uvm|$ROOT/verification/uvm/kse/tb_kse_soc_uvm.sv" \
  "tb_kse_subsystem_uvm|$ROOT/verification/uvm/kse/tb_kse_subsystem_uvm.sv" \
  "tb_kse_shared_uvm|$ROOT/verification/uvm/kse/tb_kse_shared_uvm.sv" \
  "tb_kse_fault_uvm|$ROOT/verification/uvm/kse/tb_kse_fault_uvm.sv" \
  "tb_kse_stream|$ROOT/verification/uvm/kse/tb_kse_stream.sv" \
  "tb_kse_bootstrap|$ROOT/verification/uvm/kse/tb_kse_bootstrap.sv" \
  "tb_wp8_ln|$ROOT/verification/uvm/wp8_kse/tb_wp8_ln.sv"; do
  top=${spec%%|*}; tb=${spec#*|}
  compile "$top" "${uvm_inc[@]}" "${uvm_rtl[@]}" "${uvm_soc[@]}" "${uvm_pkg[@]}" "${uvm_models[@]}" "$tb"
done

if (( failed )); then echo COMPILE_CHECK_FAIL; exit 1; fi
echo COMPILE_CHECK_PASS
