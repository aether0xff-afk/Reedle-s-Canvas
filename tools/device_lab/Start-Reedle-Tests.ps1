[CmdletBinding()]
param(
    [ValidateSet('Prepare', 'Collect', 'Import', 'Validate', 'Diagnose')][string]$Mode = 'Prepare',
    [ValidateRange(10, 3600)][int]$Seconds = 90,
    [string]$Udid,
    [string]$Report
)
$ErrorActionPreference = 'Stop'
$kitRoot = $PSScriptRoot
$uvVersion = '0.13.9'
$osArch = $env:PROCESSOR_ARCHITECTURE
if ($env:PROCESSOR_ARCHITEW6432) { $osArch = $env:PROCESSOR_ARCHITEW6432 }
if ($osArch -eq 'ARM64') {
    $uvArch = 'aarch64'
    $expectedHash = '72eed595983a4d7d22d79f21065b0f4479cc7e5c7a89104bb410c8f47559a878'
} elseif ($osArch -eq 'AMD64') {
    $uvArch = 'x86_64'
    $expectedHash = 'edd61f7f5728a56cc62455386661860bdfc7bab65872f39b0c25bdcc1d8e1beb'
} else { throw 'This kit needs 64-bit Windows (x64 or ARM64).' }

# All downloads and Python environments stay inside this kit. No global policy or PATH changes.
$runtimeRoot = Join-Path $kitRoot '.uv'
$uvPath = Join-Path $runtimeRoot 'uv.exe'
$uvArchive = Join-Path $runtimeRoot "uv-$uvVersion-$uvArch.zip"
$uvUrl = "https://github.com/astral-sh/uv/releases/download/$uvVersion/uv-$uvArch-pc-windows-msvc.zip"
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12
New-Item -ItemType Directory -Force -Path $runtimeRoot | Out-Null
if (-not (Test-Path -LiteralPath $uvArchive)) {
    Write-Host 'Preparing the local test runtime (first run needs Internet)...'
    Invoke-WebRequest -Uri $uvUrl -OutFile $uvArchive -UseBasicParsing -TimeoutSec 120
}
$hashAlgorithm = [Security.Cryptography.SHA256]::Create()
$hashStream = [IO.File]::OpenRead($uvArchive)
try { $actualHash = [BitConverter]::ToString($hashAlgorithm.ComputeHash($hashStream)).Replace('-', '').ToLowerInvariant() }
finally { $hashStream.Dispose(); $hashAlgorithm.Dispose() }
if ($actualHash -ne $expectedHash) { throw 'Runtime checksum mismatch. Download stopped; no binary was executed.' }
# Re-extract the verified binary so a stale runtime is not silently trusted.
Add-Type -AssemblyName System.IO.Compression.FileSystem
$verifiedZip = [IO.Compression.ZipFile]::OpenRead($uvArchive)
try {
    $binary = @($verifiedZip.Entries | Where-Object { $_.FullName -eq 'uv.exe' })
    if ($binary.Count -ne 1) { throw 'Unexpected verified uv archive layout.' }
    $binaryStream = $binary[0].Open()
    $destinationStream = [IO.File]::Open($uvPath, [IO.FileMode]::Create, [IO.FileAccess]::Write)
    try { $binaryStream.CopyTo($destinationStream) }
    finally { $destinationStream.Dispose(); $binaryStream.Dispose() }
} finally { $verifiedZip.Dispose() }
if (-not (Test-Path -LiteralPath $uvPath)) { throw 'Verified uv archive did not contain uv.exe.' }
$env:UV_PYTHON_INSTALL_DIR = Join-Path $runtimeRoot 'python'
$env:UV_CACHE_DIR = Join-Path $runtimeRoot 'cache'
$env:UV_LINK_MODE = 'copy'
$runnerArgs = @('run', '--project', $kitRoot, '--locked', '--python', '3.12', 'python', (Join-Path $kitRoot 'runner.py'), $Mode.ToLowerInvariant(), '--seconds', "$Seconds")
if ($Udid) { $runnerArgs += @('--udid', $Udid) }
if ($Report) { $runnerArgs += @('--report', $Report) }
& $uvPath @runnerArgs
$resultCode = $LASTEXITCODE
Write-Host "Results are in: $(Join-Path $kitRoot 'results')"
exit $resultCode
