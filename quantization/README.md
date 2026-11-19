# KWT-1 quantization for KSE

The retained flow is FP32 KWT-1 → W8A8 with checked int32 accumulation →
mixed W4/W8 and joint nonlinear search → frozen all-W4 formats → checked
ASIC MAC24 numerics → `golden_composed/all_w4_mac24`.

Run commands from the repository root. Initialize `third-party/kwt` and obtain
its upstream checkpoint before reference evaluation. Set `KWT_DATA_ROOT` or
pass `--data-root`; generated datasets, caches, profiles and reports are external
to this source package. The pinned legacy reference environment is described in
`environment/kwt-quant-environment.yml` and `environment/requirements-kwt-quant.txt`.
TensorFlow is required for preparing and evaluating the floating reference;
NumPy and SciPy suffice for collecting the retained unit tests.

The flow entry points are:

1. `scripts/run_w8a8_int32.ps1` calls `python -m quantization` for preparation,
   calibration/search, evaluation and export, then summarizes the run.
2. `scripts/run_mixed_nonlinear.ps1` runs the mixed-weight and nonlinear stages,
   including layerwise selection, source auditing and report generation.
3. `scripts/run_global_w4_modes.py`, `scripts/verify_softmax_row_stream.py`,
   `scripts/report_attention_dataflow.py` and `scripts/finalize_global_w4_modes.py`
   evaluate, check and freeze the all-W4 formats.
4. `scripts/run_asic_numerics.py` checks MAC24 arithmetic and creates profiles
   and golden packages. Optional native prefix checking is implemented by
   `native_mac.c`; set `KWT_ASIC_MAC_LIBRARY` to the compiled shared library.
5. `scripts/compose_all_w4.py` audits the two selected profiles, restores the
   all-W4 tensor, evaluates the composed profile and exports its golden package.

Use each Python entry point's `--help` for arguments. PowerShell launchers accept
`-Python` to select the interpreter; the default is `python` on PATH. The setup
and environment-check scripts are optional utilities and do not execute full
model evaluation.

`export_sim_golden.py` retains its filename and `sim_manifest.json` output for
existing KSE consumers. It exports model parameters and operator checkpoints;
its format label is `kwt-kse-golden-v1`. Packed weights use transposed output
rows, low nibble first, with independent padding for odd input widths. Golden
numbers and binary layout are unchanged. The exporter validates checksums,
shapes, repeated inference, profile reload and NumPy/binary equality. The ASIC
report states package validation results; it does not claim RTL verification.
The floating classification head remains outside integer bit-exact scope.

Quick validation:

```sh
python3 -m pytest quantization/tests --collect-only -q
python3 -m pytest quantization/tests/test_integer.py quantization/tests/test_export.py quantization/tests/test_packing.py quantization/tests/test_golden_export.py -q
```

The import closure, shell-launched dependencies, retained files and exclusions
are recorded in the packaging review report outside this source directory.
