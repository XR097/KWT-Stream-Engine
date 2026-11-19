<#
.SYNOPSIS
    Read-only audit of the KWT quantization environment.

.DESCRIPTION
    Checks Conda/Python, the requested TensorFlow version, the repository
    checkpoint, the Speech Commands data directory, and free disk space.
    This script never installs packages, creates directories, or changes files.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$DataRoot = '',

    [ValidateNotNullOrEmpty()]
    [string]$EnvironmentName = 'kwt-quant',

    [string]$RepoRoot = ''
)

$ErrorActionPreference = 'Continue'
$failures = 0

if ([string]::IsNullOrWhiteSpace($RepoRoot)) {
    $RepoRoot = Split-Path -Parent (Split-Path -Parent $PSScriptRoot)
}
if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path $RepoRoot 'kwt-data' }

function Write-Check {
    param(
        [ValidateSet('OK', 'WARN', 'FAIL')]
        [string]$Status,
        [string]$Message
    )

    $color = switch ($Status) {
        'OK'   { 'Green' }
        'WARN' { 'Yellow' }
        default { 'Red' }
    }
    Write-Host ("[{0}] {1}" -f $Status, $Message) -ForegroundColor $color
}

function Invoke-PythonCode {
    param(
        [string]$Code,
        [string]$CondaPath,
        [string]$EnvName
    )

    if ($CondaPath) {
        # TensorFlow 2.4 emits an expected CUDA stub warning on stderr on
        # CPU-only hosts; keep diagnostics out of the version value.
        $result = & $CondaPath run --no-capture-output -n $EnvName python -c $Code 2>$null
        if ($LASTEXITCODE -eq 0) {
            return (($result | Out-String).Trim())
        }
        return $null
    }

    $python = Get-Command python -ErrorAction SilentlyContinue
    if ($python) {
        $result = & $python.Source -c $Code 2>$null
        if ($LASTEXITCODE -eq 0) {
            return (($result | Out-String).Trim())
        }
    }
    return $null
}

Write-Host "KWT-1 quantization environment audit (read-only)" -ForegroundColor Cyan
Write-Host ("Repository: {0}" -f $RepoRoot)
Write-Host ("Data root : {0}" -f $DataRoot)
Write-Host ("Conda env : {0}" -f $EnvironmentName)
Write-Host ""

$conda = Get-Command conda -ErrorAction SilentlyContinue
$condaPath = $null
if ($conda) {
    $condaPath = $conda.Source
    Write-Check 'OK' ("Conda found: {0}" -f $condaPath)
    $envListing = & $condaPath env list 2>$null | Out-String
    if ($envListing -match ("(?m)^\s*" + [regex]::Escape($EnvironmentName) + "\s")) {
        Write-Check 'OK' ("Conda environment '{0}' is present." -f $EnvironmentName)
    }
    else {
        Write-Check 'FAIL' ("Conda environment '{0}' was not found." -f $EnvironmentName)
        $failures++
    }
}
else {
    Write-Check 'WARN' 'Conda command was not found on PATH.'
}

$pythonVersion = Invoke-PythonCode -CondaPath $condaPath -EnvName $EnvironmentName -Code "import sys; print(str(sys.version_info[0])+'.'+str(sys.version_info[1])+'.'+str(sys.version_info[2]))"
if ($pythonVersion) {
    if ($pythonVersion -match '^3\.8\.') {
        Write-Check 'OK' ("Python {0} (expected 3.8.x)." -f $pythonVersion)
    }
    else {
        Write-Check 'WARN' ("Python {0} found; TensorFlow 2.4 requires Python 3.8.x for the planned setup." -f $pythonVersion)
    }
}
else {
    Write-Check 'FAIL' ("Python could not be executed through '{0}'." -f $EnvironmentName)
    $failures++
}

$tensorflowVersion = Invoke-PythonCode -CondaPath $condaPath -EnvName $EnvironmentName -Code 'import tensorflow as tf; print(tf.__version__)'
if ($tensorflowVersion) {
    if ($tensorflowVersion -match '^2\.4\.') {
        Write-Check 'OK' ("TensorFlow {0} detected." -f $tensorflowVersion)
    }
    else {
        Write-Check 'WARN' ("TensorFlow {0} detected; planned baseline is 2.4.x." -f $tensorflowVersion)
    }
}
else {
    Write-Check 'FAIL' 'TensorFlow import failed in the selected Python environment.'
    $failures++
}

$checkpointDir = Join-Path $RepoRoot 'third-party\kwt\models_data_v2_12_labels\kwt1'
$checkpointIndex = Join-Path $checkpointDir 'best_weights.index'
$checkpointData = Join-Path $checkpointDir 'best_weights.data-00000-of-00001'
if ((Test-Path -LiteralPath $checkpointIndex) -and (Test-Path -LiteralPath $checkpointData)) {
    Write-Check 'OK' ("KWT-1 checkpoint found: {0}" -f $checkpointDir)
}
else {
    Write-Check 'FAIL' ("KWT-1 checkpoint is incomplete: {0}" -f $checkpointDir)
    $failures++
}

$dataPath = [System.IO.Path]::GetFullPath($DataRoot)
if (Test-Path -LiteralPath $dataPath -PathType Container) {
    Write-Check 'OK' ("Data root exists: {0}" -f $dataPath)
}
else {
    Write-Check 'WARN' ("Data root does not exist yet: {0}. Run setup_kwt_quant.ps1 first." -f $dataPath)
}

$datasetPath = Join-Path $dataPath 'data2'
$wavCount = 0
if (Test-Path -LiteralPath $datasetPath -PathType Container) {
    $wavCount = @(Get-ChildItem -LiteralPath $datasetPath -Filter '*.wav' -File -Recurse -ErrorAction SilentlyContinue).Count
}
if ($wavCount -gt 0) {
    Write-Check 'OK' ("Speech Commands data2 contains {0} WAV files." -f $wavCount)
}
else {
    $archive = @(
        (Join-Path $dataPath 'speech_commands_v0.02.tar.gz'),
        (Join-Path $dataPath 'speech_commands_v0.02.zip')
    ) | Where-Object { Test-Path -LiteralPath $_ -PathType Leaf }
    if ($archive.Count -gt 0) {
        Write-Check 'WARN' ("Speech Commands archive found but data2 is not extracted: {0}" -f $archive[0])
    }
    else {
        Write-Check 'WARN' ("No Speech Commands WAV files found under {0}." -f $datasetPath)
    }
}

try {
    $rootPath = [System.IO.Path]::GetPathRoot($dataPath)
    $drive = New-Object System.IO.DriveInfo($rootPath)
    $freeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
    if ($freeGiB -ge 20) {
        Write-Check 'OK' ("{0} has {1} GiB free (recommended minimum: 20 GiB)." -f $rootPath, $freeGiB)
    }
    else {
        Write-Check 'WARN' ("{0} has only {1} GiB free; reserve 20-30 GiB for dataset and artifacts." -f $rootPath, $freeGiB)
    }
}
catch {
    Write-Check 'WARN' ("Could not query free space for {0}: {1}" -f $dataPath, $_.Exception.Message)
}

Write-Host ""
if ($failures -eq 0) {
    Write-Host 'Audit complete: required software/checkpoint checks passed.' -ForegroundColor Green
    exit 0
}
Write-Host ("Audit complete: {0} required check(s) failed. No files were changed." -f $failures) -ForegroundColor Red
exit 1
