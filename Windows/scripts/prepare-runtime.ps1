[CmdletBinding()]
param([string]$Resources = (Join-Path $PSScriptRoot '../resources'))

# App-local deployment from the official Visual Studio redistributable folders.
# No global runtime installation, registry changes, or downloaded DLL substitutes.
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $IsWindows) { throw 'The runtime must be prepared on Windows with Visual Studio installed.' }
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio/Installer/vswhere.exe'
if (-not (Test-Path -LiteralPath $vswhere -PathType Leaf)) { throw 'Official Visual Studio vswhere.exe was not found.' }
$installation = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1)
if ($LASTEXITCODE -ne 0 -or -not $installation) { throw 'Visual Studio C++ x64 tools are required.' }
$redistRoot = Join-Path $installation 'VC/Redist/MSVC'
$selected = $null
foreach ($version in (Get-ChildItem -LiteralPath $redistRoot -Directory | Where-Object Name -Match '^\d+\.\d+\.\d+$' | Sort-Object { [version]$_.Name } -Descending)) {
    $x64 = Join-Path $version.FullName 'x64'
    if (-not (Test-Path -LiteralPath $x64)) { continue }
    $crt = @(Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.CRT')
    $openmp = @(Get-ChildItem -LiteralPath $x64 -Directory -Filter 'Microsoft.VC*.OpenMP')
    if ($crt.Count -eq 1 -and $openmp.Count -eq 1) {
        $selected = @{ Version = $version.Name; CRT = $crt[0]; OpenMP = $openmp[0] }
        break
    }
}
if (-not $selected) { throw 'An official x64 CRT and OpenMP redistributable pair was not found in Visual Studio.' }

function Assert-MicrosoftX64Dll([System.IO.FileInfo]$File) {
    $bytes = [IO.File]::ReadAllBytes($File.FullName)
    if ($bytes.Length -lt 64 -or $bytes[0] -ne 0x4d -or $bytes[1] -ne 0x5a) { throw "Invalid DLL: $($File.Name)" }
    $pe = [BitConverter]::ToInt32($bytes, 0x3c)
    if ($pe -lt 0 -or $pe + 6 -gt $bytes.Length -or [BitConverter]::ToUInt32($bytes, $pe) -ne 0x4550 -or [BitConverter]::ToUInt16($bytes, $pe + 4) -ne 0x8664) {
        throw "Not an x64 PE DLL: $($File.Name)"
    }
    $signature = Get-AuthenticodeSignature -LiteralPath $File.FullName
    if ($signature.Status -ne 'Valid' -or $signature.SignerCertificate.Subject -notmatch 'O=Microsoft Corporation(?:,|$)') {
        throw "Microsoft signature verification failed: $($File.Name)"
    }
}

$files = @(Get-ChildItem -LiteralPath $selected.CRT.FullName, $selected.OpenMP.FullName -File -Filter '*.dll' | Sort-Object Name)
foreach ($required in @('msvcp140.dll', 'vcruntime140.dll', 'vcruntime140_1.dll', 'vcomp140.dll')) {
    if ($required -notin $files.Name) { throw "Required runtime is missing: $required" }
}
if (@($files.Name | Select-Object -Unique).Count -ne $files.Count) { throw 'Duplicate runtime filenames; refusing an ambiguous copy.' }
foreach ($file in $files) { Assert-MicrosoftX64Dll $file }

New-Item -ItemType Directory -Path $Resources -Force | Out-Null
$Resources = (Resolve-Path -LiteralPath $Resources).Path
$stage = Join-Path $Resources ('.runtime-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $stage | Out-Null
try {
    $manifest = @()
    foreach ($file in $files) {
        Copy-Item -LiteralPath $file.FullName -Destination (Join-Path $stage $file.Name)
        $manifest += [ordered]@{
            name = $file.Name; size = $file.Length
            sha256 = (Get-FileHash -LiteralPath $file.FullName -Algorithm SHA256).Hash.ToLowerInvariant()
            fileVersion = $file.VersionInfo.FileVersion
        }
    }
    foreach ($file in $files) { Move-Item -LiteralPath (Join-Path $stage $file.Name) -Destination (Join-Path $Resources $file.Name) -Force }
    [ordered]@{
        vendor = 'Microsoft Corporation'; architecture = 'x64'; version = $selected.Version
        source = 'Official Visual Studio VC/Redist/MSVC x64 CRT and OpenMP folders'
        deployment = 'app-local'; signatureVerified = $true; files = $manifest
        documentation = 'https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170'
    } | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath (Join-Path $Resources 'runtime-build.json') -Encoding utf8
    $notice = @'
Microsoft Visual C++ Runtime and OpenMP (x64)

These unmodified, Microsoft-signed redistributable DLLs are copied from the
Visual Studio VC/Redist/MSVC directory on the Windows build runner. They are
deployed alongside whisper-cli.exe, not installed into the operating system.
runtime-build.json records their versions and SHA-256 checksums.
Redistribution is governed by the applicable Microsoft Visual Studio license.
https://learn.microsoft.com/en-us/cpp/windows/redistributing-visual-cpp-files?view=msvc-170
https://visualstudio.microsoft.com/license-terms/
'@
    $notice | Set-Content -LiteralPath (Join-Path $Resources 'NOTICE-Microsoft-Runtime.txt') -Encoding utf8
} finally {
    Remove-Item -LiteralPath $stage -Recurse -Force
}
Write-Host "Prepared $($files.Count) Microsoft x64 runtime DLLs, version $($selected.Version), app-local."
