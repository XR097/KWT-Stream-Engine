# KSE UVM verification environment

This directory contains the open KSE verification environment. The `kse/` area provides unit, shared SRAM, subsystem, SoC, stream, bootstrap, numeric, fault injection, strict bus, and CPU stress tests. The `wp8_kse/` area provides LayerNorm vector checking and the SoC peripheral/UART test. Tests use the KSE RTL under `rtl/kse` and `rtl/kse_soc`, the E203 source in `third-party/e203`, behavioral SRAM models in `tb/models`, and test data under `data/vectors`.

VCS X-2025.06 or newer and UVM 1.2 are required. A RISC-V `riscv-none-elf-` toolchain is required for CPU stress and peripheral firmware tests; set `RISCV_PREFIX` to its prefix. VCS is always invoked with `-full64 -sverilog -ntb_opts uvm-1.2`.

Run scripts are in `tools/verif_tool/vcs`:

- `run_kse_bootstrap.py` checks reset, MMIO, CPU and loader accesses.
- `run_kse_numeric.py` and `run_kse_stream.py` compile and run numeric and network tests.
- `run_kse_integration.py`, `run_kse_faults.py`, and `run_kse_strict_bus.py` exercise arbitration, reset, and fault contracts.
- `run_kse_network.py` runs subsystem or SoC data jobs; `run_kse_cpu_stress.py` and its matrix wrapper test firmware traffic.
- `run_wp8_kse.py ln` runs LayerNorm vectors, while `run_wp8_kse.py soc-periph` runs the peripheral test.

Each script accepts `--help`; outputs are written below the selected `--out` directory. Behavioral SRAM models are the default and require no proprietary library. A technology SRAM model may be selected only by setting the corresponding user supplied model/configuration environment variables.

## FSDB-enabled compile checks

Several UVM tops contain optional `$fsdbDumpfile`/`$fsdbDumpvars` calls. When `VERDI_HOME` is set, `scripts/compile_check.sh` passes the matching VCS/Verdi PLI files (`$VERDI_HOME/share/PLI/VCS/LINUX64/novas.tab` and `pli.a`) together with `-kdb -debug_access+all`, so these tops are compiled with FSDB support. If `VERDI_HOME` is unset, those FSDB-dependent compile items print `SKIP(no Verdi)` and do not count as failures; the remaining compile checks still run.

The `tb_kse_soc_uvm` source testbench loads firmware through a backdoor into the vendor SRAM macro array (`g_macro.g_row.g_col.u_ram.mem`) and therefore depends on the vendor macro model's internal hierarchy and its simulator define. `compile_check.sh` skips this one top with `SKIP(needs vendor SRAM models)` unless `KSE_PDK_MODELS=1`; behavioral SRAM checks remain enabled by default. The source testbench is unchanged.
