[CmdletBinding()]
param([string] $TeleAgentRoot)

$ErrorActionPreference = 'Stop'

if (-not $TeleAgentRoot) {
    $runningPath = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch '\\.local\\share\\TeleAgent\\runtimes\\' } |
        Select-Object -ExpandProperty ExecutablePath -First 1
    if ($runningPath) { $TeleAgentRoot = Split-Path -Parent $runningPath }
}
if (-not $TeleAgentRoot) { $TeleAgentRoot = 'D:\Software\teleclaw\TeleAgent' }

$root = (Resolve-Path -LiteralPath $TeleAgentRoot).Path
$source = Join-Path $root 'resources\app.asar'
$exe = Join-Path $root 'TeleAgent.exe'
if (-not (Test-Path -LiteralPath $source) -or -not (Test-Path -LiteralPath $exe)) { throw 'The TeleAgent installation layout is incomplete.' }

$work = Join-Path ([IO.Path]::GetTempPath()) ('teleagent-shinchan-test-' + [guid]::NewGuid().ToString('N'))
$output = Join-Path $work 'app.asar'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $beforeHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    & (Join-Path $PSScriptRoot 'patch-theme.ps1') -SourceAsar $source -OutputAsar $output
    if ($LASTEXITCODE -ne 0) { throw 'The theme build test failed.' }
    $afterHash = (Get-FileHash -LiteralPath $source -Algorithm SHA256).Hash
    if ($beforeHash -ne $afterHash) { throw 'The source app.asar changed during the dry run.' }
    if ((Get-Item -LiteralPath $output).Length -le 0) { throw 'The dry-run output is empty.' }
    $version = (Get-Item -LiteralPath $exe).VersionInfo.ProductVersion
    Write-Host "Dry-run build passed for TeleAgent $version. The installed archive was not modified."
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
