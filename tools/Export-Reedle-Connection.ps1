[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)][string]$Server,
    [string]$OutputPath,
    [switch]$Replace
)
$ErrorActionPreference = 'Stop'
$projectRoot = Split-Path -Parent $PSScriptRoot
$loader = Join-Path $env:LOCALAPPDATA 'ReedlesCanvas/load-reedle-gateway.ps1'
if (-not $env:REEDLE_CLIENT_TOKEN -and (Test-Path -LiteralPath $loader)) { . $loader }
if (-not $env:REEDLE_CLIENT_TOKEN) { throw 'Configure the separate REEDLE_CLIENT_TOKEN in this server account first.' }
$uv = Get-Command uv -CommandType Application -ErrorAction SilentlyContinue | Select-Object -First 1
if ($uv) { $uvPath = $uv.Source }
else { $uvPath = Join-Path $env:USERPROFILE '.local/bin/uv.exe' }
if (-not (Test-Path -LiteralPath $uvPath)) { throw 'Install uv: https://docs.astral.sh/uv/getting-started/installation/' }
$exportArgs = @('run', '--project', (Join-Path $projectRoot 'server'), '--locked', '--no-dev',
                'python', (Join-Path $PSScriptRoot 'export_tutor_connection.py'), '--server', $Server)
if ($OutputPath) { $exportArgs += @('--output', $OutputPath) }
if ($Replace) { $exportArgs += '--replace' }
& $uvPath @exportArgs
exit $LASTEXITCODE
