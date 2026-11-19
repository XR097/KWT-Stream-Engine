<# Run the frozen W8A8/int32 MAC experiment in the isolated Conda environment. #>
[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [string]$Python = 'python',
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $repository 'kwt-data' }
if (-not (Test-Path -LiteralPath $Python -PathType Leaf)) {
    throw "kwt-quant Python executable not found: $Python"
}
Push-Location -LiteralPath $repository
$previousBytecodeSetting = $env:PYTHONDONTWRITEBYTECODE
try {
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $trainingCache = Join-Path $DataRoot 'cache\training.npz'
    if (-not (Test-Path -LiteralPath $trainingCache -PathType Leaf)) {
        & $Python -u -m quantization prepare --data-root $DataRoot --repo-root $repository
        if ($LASTEXITCODE -ne 0) { throw 'Dataset/cache preparation failed.' }
    }
    $profileFile = Join-Path $DataRoot 'profiles\W8A8_integer\profile.json'
    if (-not ($Resume -and (Test-Path -LiteralPath $profileFile))) {
        & $Python -u -m quantization sweep --data-root $DataRoot --repo-root $repository
        if ($LASTEXITCODE -ne 0) { throw 'W8A8 validation failed.' }
    }
    $evaluationArguments = @('-u', '-m', 'quantization', 'evaluate', '--data-root', $DataRoot, '--repo-root', $repository)
    if ($Resume) { $evaluationArguments += '--resume' }
    & $Python @evaluationArguments
    if ($LASTEXITCODE -ne 0) { throw 'Complete W8A8 evaluation failed; inspect acceptance/progress JSON.' }
    & $Python -m quantization export --data-root $DataRoot --repo-root $repository
    if ($LASTEXITCODE -ne 0) { throw 'Golden export or bit-exact verification failed.' }
    & $Python quantization/scripts/summarize_kwt_int32.py --data-root $DataRoot
    if ($LASTEXITCODE -ne 0) { throw 'Report verification failed.' }
}
finally {
    $env:PYTHONDONTWRITEBYTECODE = $previousBytecodeSetting
    Pop-Location
}
