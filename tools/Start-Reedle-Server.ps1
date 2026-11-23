[CmdletBinding()]
param(
    [ValidateRange(1024, 65535)][int]$Port = 8000,
    [string]$ListenAddress = '127.0.0.1',
    [string]$Certificate,
    [string]$CertificateKey
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$loader = Join-Path $env:LOCALAPPDATA 'ReedlesCanvas/load-reedle-gateway.ps1'
if ((-not $env:BAZE_API_KEY -or -not $env:REEDLE_CLIENT_TOKEN) -and (Test-Path -LiteralPath $loader)) {
    . $loader
}
if (-not $env:BAZE_API_KEY -or -not $env:REEDLE_CLIENT_TOKEN) {
    throw 'Configure BAZE_API_KEY and the separate REEDLE_CLIENT_TOKEN in this server account first. See server/README.md.'
}
if (-not $env:BAZE_MODEL) { $env:BAZE_MODEL = 'gpt-6.1-terra' }
if (-not $env:BAZE_BASE_URL) { $env:BAZE_BASE_URL = 'https://api.baze.co/v1/gateway' }
if ([bool]$Certificate -ne [bool]$CertificateKey) { throw 'Supply both -Certificate and -CertificateKey.' }
if ($ListenAddress -notin @('127.0.0.1', '::1', 'localhost') -and -not $Certificate) {
    throw 'Use a TLS certificate for a non-loopback listener, or keep loopback behind an HTTPS proxy.'
}
$uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($uv) { $uvPath = $uv.Source }
else { $uvPath = Join-Path $env:USERPROFILE '.local/bin/uv.exe' }
if (-not (Test-Path -LiteralPath $uvPath)) { throw 'Install uv: https://docs.astral.sh/uv/getting-started/installation/' }
$stateRoot = Join-Path $env:LOCALAPPDATA 'ReedlesCanvas/server'
New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
if (-not $env:REEDLE_BUDGET_DB) { $env:REEDLE_BUDGET_DB = Join-Path $stateRoot 'attempts.sqlite3' }
$serverArgs = @('run', '--directory', (Join-Path $projectRoot 'server'), '--locked', '--no-dev',
                'uvicorn', 'reedle_server.app:app', '--host', $ListenAddress, '--port', "$Port")
if ($Certificate) {
    $serverArgs += @('--ssl-certfile', (Resolve-Path -LiteralPath $Certificate).Path,
                     '--ssl-keyfile', (Resolve-Path -LiteralPath $CertificateKey).Path)
}
Write-Host "Starting Reedle Tutor on ${ListenAddress}:$Port. iPad connections use the configured HTTPS endpoint."
& $uvPath @serverArgs
exit $LASTEXITCODE
