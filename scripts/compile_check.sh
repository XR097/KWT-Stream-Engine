#!/usr/bin/env bash
# Compile only: never execute generated simulation binaries.
set -uo pipefail
ROOT=$(cd "${1:-$(dirname "$0")/..}" && pwd)
BUILD=${KSE_CHECK_RUN:-$(mktemp -d "${TMPDIR:-/tmp}/kse-compile.XXXXXX")}
mkdir -p "$BUILD"
BUILD=$(cd "$BUILD" && pwd)
failed=0
compile() {
  local top=$1; shift
  local dir="$BUILD/$top"
  mkdir -p "$dir"
  if (cd "$dir" && vcs -full64 -sverilog -timescale=1ns/1ps +v2k -top "$top" -o simv "$@" > compile.log 2>&1) &&
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
   echo "PASS Python ${path#"$ROOT/"}"
  else echo "FAIL Python ${path#"$ROOT/"}"; cat "$BUILD/python.log"; failed=1; fi
 done < <(find "$ROOT/$dir" -type f -name '*.py' -print0 | sort -z)
done
if (( failed )); then echo COMPILE_CHECK_FAIL; exit 1; fi
echo COMPILE_CHECK_PASS
