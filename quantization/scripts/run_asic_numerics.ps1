param(
  [Parameter(Mandatory=$true)][string]$DataRoot,
  [string]$ReferenceRoot = '.',
  [int]$Workers = 12,
  [string]$Python = 'python',
  [switch]$Resume,
  [ValidateSet('all','prepare','baseline','single','greedy','structure','nonlinear','final','stats','golden','report')][string]$Stage = 'all'
)
$ErrorActionPreference = 'Stop'
$env:CUDA_VISIBLE_DEVICES = '-1'
$env:OMP_NUM_THREADS = '1'
$env:OPENBLAS_NUM_THREADS = '1'
$env:MKL_NUM_THREADS = '1'
$args = @('-B', '-u', 'quantization/scripts/run_asic_numerics.py', '--data-root', $DataRoot, '--reference-root', $ReferenceRoot, '--workers', $Workers, '--stage', $Stage)
if ($Resume) { $args += '--resume' }
& $python @args
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
