#!/usr/bin/env bash
# Strict-final: smoke -> isolated negative controls -> exactly 12 even samples.
# VCS/simv/URG are admitted by the shared codex VCS slot wrapper.
set -euo pipefail
cd "$(dirname "$0")/../../.."
O=${1:?usage: run_kse_soc_all24.sh run/strict-final/name-date [data-dir]}
D=${2:-${KSE_DATA_DIR:-data/vectors}}
mkdir -p "$O"
python3 tools/verif_tool/vcs/run_kse_network.py --kind soc --data "$D" --out "$O/smoke" --first 0 --count 1 > "$O/smoke.console.log" 2>&1
B=$(cat "$O/smoke/build_path.txt")
python3 tools/verif_tool/vcs/run_kse_integration.py --out "$O/contracts" --negative > "$O/contracts.console.log" 2>&1
python3 tools/verif_tool/vcs/run_kse_network.py --kind soc --data "$D" --out "$O/output-negative" --build "$B" --first 0 --count 1 --negative-output > "$O/output-negative.console.log" 2>&1
python3 tools/verif_tool/vcs/run_kse_network.py --kind soc --data "$D" --out "$O/even12" --build "$B" --first 0 --count 12 --step 2 --seconds 10800 > "$O/even12.console.log" 2>&1
echo KSE_SOC_STRICT_DRIVER_DONE
