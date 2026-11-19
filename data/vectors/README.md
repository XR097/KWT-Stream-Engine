# Small hardware vector set

These are converted integer inputs and expected outputs from the quantization
flow's frozen all-W4 / MAC24 golden export. Expected values come from the golden
export; the conversion tools do not run inference to invent expected outputs.
The package contains 79,008 parameter words (12 layers), unit vectors sampled
uniformly to at most 1,024 rows per file, full engine traces for samples 0 and 1,
and SoC tasks built from samples 0 and 2. This is a small reproducibility set,
not the full validation dataset or an accuracy claim.

Use `+DATA=<repo>/data/vectors` for `tb_kse_top`, and
`+DATA=<repo>/data/vectors/tasks +NTASK=2` for `tb_kse_soc`. The helper scripts
select these locations by default; `KSE_DATA` overrides them. The SoC additionally
needs firmware built with `tools/kse_soc/kse_soc_sim.sh fw`.

To regenerate, export golden data using the quantization flow, install NumPy,
and set `KSE_GOLDEN` to the exported directory containing `profile/`, `operators/`,
and `sample_XX_*` arrays/binaries. From the repository root:

```sh
python3 tools/kse/pack_params.py --profile "$KSE_GOLDEN/profile" --output-dir data/vectors/params
python3 tools/kse/gen_tb_data.py --golden "$KSE_GOLDEN" --out data/vectors/units units --unit-limit 1024
python3 tools/kse/gen_tb_data.py --golden "$KSE_GOLDEN" --out data/vectors/samples samples --samples 0,1
python3 tools/kse_soc/gen_soc_data.py --golden "$KSE_GOLDEN" --params data/vectors/params/params.bin --out data/vectors/tasks --samples 0,2
```

`params.bin` is the portable little-endian integer parameter stream, not a tool
database. `params.hex` is its text counterpart. The JSON manifest records layout
and decoded fields; task manifests include input/output hashes. `--unit-limit 0`
keeps all unit rows and can exceed the small package size budget. Use a separate
`KSE_DATA` output directory when generating a full dataset.
