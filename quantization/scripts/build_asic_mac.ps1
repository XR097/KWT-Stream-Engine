param([Parameter(Mandatory=$true)][string]$DataRoot)
$ErrorActionPreference='Stop'
$destination=Join-Path $DataRoot 'experiments/asic_numerics_v1/native'
New-Item -ItemType Directory -Force -Path $destination | Out-Null
$vswhere="${env:ProgramFiles(x86)}\Microsoft Visual Studio\Installer\vswhere.exe"
$vs=& $vswhere -latest -property installationPath
$vc=Get-ChildItem "$vs\VC\Tools\MSVC" | Sort-Object Name -Descending | Select-Object -First 1
$sdk="${env:ProgramFiles(x86)}\Windows Kits\10"
$version=(Get-ChildItem "$sdk\Include" | Sort-Object Name -Descending | Select-Object -First 1).Name
$env:INCLUDE="$($vc.FullName)\include;$sdk\Include\$version\ucrt;$sdk\Include\$version\shared;$sdk\Include\$version\um"
$env:LIB="$($vc.FullName)\lib\x64;$sdk\Lib\$version\ucrt\x64;$sdk\Lib\$version\um\x64"
& "$($vc.FullName)\bin\Hostx64\x64\cl.exe" /nologo /LD /O2 /arch:AVX2 /TC /std:c11 "$PSScriptRoot\..\native_mac.c" "/Fo$destination\native_mac.obj" /link "/OUT:$destination\native_mac.dll" "/IMPLIB:$destination\native_mac.lib"
if ($LASTEXITCODE -ne 0) { exit $LASTEXITCODE }
Write-Output "Set KWT_ASIC_MAC_LIBRARY=$destination\native_mac.dll before experiments."
