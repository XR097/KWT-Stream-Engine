[CmdletBinding()]
param(
    [string]$DataRoot = '',
    [string]$Python = 'python',
    [ValidateRange(1,8)][int]$Workers = 4,
    [ValidateSet('all','prepare','residual','weights','nonlinear','joint','final','report')]
    [string]$Stage = 'all',
    [switch]$Resume
)
$ErrorActionPreference = 'Stop'
$repository = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $repository 'kwt-data' }
$settings = @{}
foreach ($name in @('PYTHONDONTWRITEBYTECODE','OMP_NUM_THREADS','OPENBLAS_NUM_THREADS','MKL_NUM_THREADS','CUDA_VISIBLE_DEVICES')) {
    $settings[$name] = [Environment]::GetEnvironmentVariable($name, 'Process')
}
Push-Location -LiteralPath $repository
try {
    $env:PYTHONDONTWRITEBYTECODE = '1'
    $env:OMP_NUM_THREADS = '1'
    $env:OPENBLAS_NUM_THREADS = '1'
    $env:MKL_NUM_THREADS = '1'
    $env:CUDA_VISIBLE_DEVICES = '-1'
    $stages = if ($Stage -eq 'all') { @('residual','weights','nonlinear','joint','final') } else { @($Stage) }
    foreach ($currentStage in $stages) {
        if ($currentStage -eq 'final') {
            & $Python -B (Join-Path $PSScriptRoot 'audit_final_mixed.py') --data-root $DataRoot --repo-root $repository --prepare
            if ($LASTEXITCODE -ne 0) { throw 'Final sample provenance preparation failed.' }
        }
        if ($currentStage -eq 'joint') {
            $arguments = @('-B','-u',(Join-Path $PSScriptRoot 'search_mixed_layerwise.py'),
                           '--data-root',$DataRoot,'--repo-root',$repository,'--workers',$Workers)
        }
        else {
            $arguments = @('-B','-u','-m','quantization','experiment','--data-root',$DataRoot,
                           '--repo-root',$repository,'--workers',$Workers,'--stage',$currentStage)
        }
        if ($Resume -or $currentStage -ne $stages[0]) { $arguments += '--resume' }
        & $Python @arguments
        if ($LASTEXITCODE -ne 0) { throw "Experiment stage $currentStage failed; inspect preserved progress and logs." }
        if ($currentStage -eq 'weights') {
            & $Python -B (Join-Path $PSScriptRoot 'select_mixed_weight_branches.py') --data-root $DataRoot
            if ($LASTEXITCODE -ne 0) { throw 'Mixed-weight branch selection failed.' }
        }
        if ($currentStage -eq 'final') {
            & $Python -B (Join-Path $PSScriptRoot 'audit_final_mixed.py') --data-root $DataRoot --repo-root $repository --audit
            if ($LASTEXITCODE -ne 0) { throw 'Final acceptance or portable golden audit failed.' }
        }
    }
    if ($Stage -eq 'all' -or $Stage -eq 'final' -or $Stage -eq 'report') {
        & $Python -B (Join-Path $PSScriptRoot 'summarize_mixed_nonlinear.py') --data-root $DataRoot
        if ($LASTEXITCODE -ne 0) { throw 'Experiment summary failed.' }
        & $Python -B (Join-Path $PSScriptRoot 'report_hardware_candidates.py') --data-root $DataRoot
        if ($LASTEXITCODE -ne 0) { throw 'Hardware candidate report failed.' }
    }
}
finally {
    Pop-Location
    foreach ($name in $settings.Keys) {
        [Environment]::SetEnvironmentVariable($name, $settings[$name], 'Process')
    }
}
