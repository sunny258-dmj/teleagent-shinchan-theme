[CmdletBinding()]
param(
    [string] $TeleAgentRoot,
    [switch] $Restart
)

$ErrorActionPreference = 'Stop'

function Resolve-TeleAgentRoot {
    param([string] $RequestedRoot)
    if ($RequestedRoot) { return (Resolve-Path -LiteralPath $RequestedRoot).Path }
    $running = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch '\\.local\\share\\TeleAgent\\runtimes\\' } |
        Select-Object -ExpandProperty ExecutablePath -Unique
    foreach ($path in $running) {
        $root = Split-Path -Parent $path
        if (Test-Path -LiteralPath (Join-Path $root 'resources\.teleagent-shinchan-theme\install-state.json')) { return $root }
    }
    foreach ($candidate in @('D:\Software\teleclaw\TeleAgent', (Join-Path $env:LOCALAPPDATA 'Programs\TeleAgent'), (Join-Path $env:LOCALAPPDATA 'TeleAgent'))) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'resources\.teleagent-shinchan-theme\install-state.json')) { return $candidate }
    }
    throw 'No installation record for this theme was found.'
}

function Stop-SelectedTeleAgent {
    param([string] $ExecutablePath)
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $targets = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $ExecutablePath }
        if (-not $targets) { return }
        foreach ($target in $targets) { Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    throw 'TeleAgent processes did not exit within 10 seconds.'
}

$root = Resolve-TeleAgentRoot $TeleAgentRoot
$exe = Join-Path $root 'TeleAgent.exe'
$asar = Join-Path $root 'resources\app.asar'
$stateRoot = Join-Path $root 'resources\.teleagent-shinchan-theme'
$metadataPath = Join-Path $stateRoot 'install-state.json'
$state = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
$backup = [string]$state.backupPath
$exeBackup = [string]$state.exeBackupPath

if (-not (Test-Path -LiteralPath $backup)) { throw 'The original archive backup is missing. Uninstall stopped.' }
$backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
if ($backupHash -ne [string]$state.backupSha256) { throw 'The original archive backup failed verification. Uninstall stopped.' }
if ($exeBackup) {
    if (-not (Test-Path -LiteralPath $exeBackup)) { throw 'The original executable backup is missing. Uninstall stopped.' }
    $exeBackupHash = (Get-FileHash -LiteralPath $exeBackup -Algorithm SHA256).Hash
    if ($exeBackupHash -ne [string]$state.exeBackupSha256) { throw 'The executable backup failed verification. Uninstall stopped.' }
}

Stop-SelectedTeleAgent $exe

Copy-Item -LiteralPath $backup -Destination $asar -Force
if ($exeBackup) { Copy-Item -LiteralPath $exeBackup -Destination $exe -Force }
$restoredHash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
if ($restoredHash -ne [string]$state.sourceAsarSha256) { throw 'The restored archive failed verification. Keep the backup and stop.' }

Remove-Item -LiteralPath $metadataPath -Force
Write-Host 'The Shin-chan theme was removed and the original TeleAgent interface was restored.'
if ($Restart) { & $exe; Write-Host 'TeleAgent was reopened.' }
