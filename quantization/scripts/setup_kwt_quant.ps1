<#
.SYNOPSIS
    Create the external data directories used by the KWT quantization flow.

.DESCRIPTION
    This script only creates the requested directory structure. It does not
    download data, install packages, or modify the repository/third-party tree.
#>
[CmdletBinding()]
param(
    [Parameter(Position = 0)]
    [ValidateNotNullOrEmpty()]
    [string]$DataRoot = ''
)

$ErrorActionPreference = 'Stop'

try {
    if ([string]::IsNullOrWhiteSpace($DataRoot)) { $DataRoot = Join-Path (Split-Path -Parent (Split-Path -Parent $PSScriptRoot)) 'kwt-data' }
    $resolvedRoot = [System.IO.Path]::GetFullPath($DataRoot)
    $directories = @(
        $resolvedRoot,
        (Join-Path $resolvedRoot 'data2'),
        (Join-Path $resolvedRoot 'cache'),
        (Join-Path $resolvedRoot 'golden'),
        (Join-Path $resolvedRoot 'reports')
    )

    foreach ($directory in $directories) {
        New-Item -ItemType Directory -Path $directory -Force | Out-Null
        Write-Host ("[OK] {0}" -f $directory) -ForegroundColor Green
    }

    $rootPath = [System.IO.Path]::GetPathRoot($resolvedRoot)
    try {
        $drive = New-Object System.IO.DriveInfo($rootPath)
        $freeGiB = [math]::Round($drive.AvailableFreeSpace / 1GB, 1)
        Write-Host ("[INFO] {0} has {1} GiB free." -f $rootPath, $freeGiB) -ForegroundColor Cyan
        if ($freeGiB -lt 20) {
            Write-Warning ("Only {0} GiB is free. Keep at least 20-30 GiB available for Speech Commands and generated artifacts." -f $freeGiB)
        }
    }
    catch {
        Write-Warning ("Could not query free space for {0}: {1}" -f $rootPath, $_.Exception.Message)
    }

    Write-Host "Data directories are ready. Download/extract Speech Commands V2 into data2 separately." -ForegroundColor Cyan
}
catch {
    Write-Error ("Failed to prepare KWT data directories: {0}" -f $_.Exception.Message)
    exit 1
}
