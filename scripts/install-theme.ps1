[CmdletBinding()]
param(
    [string] $TeleAgentRoot,
    [switch] $Restart,
    [switch] $ForceUnsupportedVersion
)

$ErrorActionPreference = 'Stop'
$SupportedVersions = @('2.5.2', '2.5.2.0')
$PatchScript = Join-Path $PSScriptRoot 'patch-theme.ps1'

function Resolve-TeleAgentRoot {
    param([string] $RequestedRoot)

    if ($RequestedRoot) {
        return (Resolve-Path -LiteralPath $RequestedRoot).Path
    }

    $running = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -and $_.ExecutablePath -notmatch '\\.local\\share\\TeleAgent\\runtimes\\' } |
        Select-Object -ExpandProperty ExecutablePath -Unique
    foreach ($path in $running) {
        $root = Split-Path -Parent $path
        if (Test-Path -LiteralPath (Join-Path $root 'resources\app.asar')) { return $root }
    }

    $candidates = @(
        'D:\Software\teleclaw\TeleAgent',
        (Join-Path $env:LOCALAPPDATA 'Programs\TeleAgent'),
        (Join-Path $env:LOCALAPPDATA 'TeleAgent')
    )
    foreach ($candidate in $candidates) {
        if (Test-Path -LiteralPath (Join-Path $candidate 'resources\app.asar')) { return $candidate }
    }

    throw 'TeleAgent was not found. Use -TeleAgentRoot to specify its installation directory.'
}

function Stop-SelectedTeleAgent {
    param([string] $ExecutablePath)
    $targets = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
        Where-Object { $_.ExecutablePath -eq $ExecutablePath }
    foreach ($target in $targets) {
        Stop-Process -Id $target.ProcessId -Force -ErrorAction Stop
    }
}

$root = Resolve-TeleAgentRoot $TeleAgentRoot
$exe = Join-Path $root 'TeleAgent.exe'
$asar = Join-Path $root 'resources\app.asar'
if (-not (Test-Path -LiteralPath $exe) -or -not (Test-Path -LiteralPath $asar)) {
    throw 'TeleAgent.exe or resources/app.asar does not exist.'
}

$versionInfo = (Get-Item -LiteralPath $exe).VersionInfo
$productVersion = $versionInfo.ProductVersion
if (($SupportedVersions -notcontains $productVersion) -and -not $ForceUnsupportedVersion) {
    throw "TeleAgent $productVersion is not verified. Run test-theme.ps1 before considering a forced install."
}

$stateRoot = Join-Path $root 'resources\.teleagent-shinchan-theme'
$metadataPath = Join-Path $stateRoot 'install-state.json'
$currentHash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
if (Test-Path -LiteralPath $metadataPath) {
    $currentState = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if ($currentState.themedAsarSha256 -eq $currentHash) {
        Write-Host 'The Shin-chan theme is already installed.'
        if ($Restart) { Start-Process -FilePath $exe }
        exit 0
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('teleagent-shinchan-install-' + [guid]::NewGuid().ToString('N'))
$themedAsar = Join-Path $work 'app.asar'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    Write-Host "Detected TeleAgent $productVersion"
    & $PatchScript -SourceAsar $asar -OutputAsar $themedAsar
    if ($LASTEXITCODE -ne 0) { throw 'The theme build failed.' }

    $themedHash = (Get-FileHash -LiteralPath $themedAsar -Algorithm SHA256).Hash
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
    $backup = Join-Path $stateRoot "app.asar.$stamp.bak"
    Copy-Item -LiteralPath $asar -Destination $backup -Force
    $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
    if ($backupHash -ne $currentHash) { throw 'The original archive backup failed verification. Installation stopped.' }

    Write-Host 'Closing TeleAgent and applying the theme...'
    Stop-SelectedTeleAgent $exe
    Copy-Item -LiteralPath $themedAsar -Destination $asar -Force
    $installedHash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
    if ($installedHash -ne $themedHash) {
        Copy-Item -LiteralPath $backup -Destination $asar -Force
        throw 'Post-install verification failed. The original archive was restored.'
    }

    $state = [ordered]@{
        themeId = 'teleagent-shinchan-theme'
        themeVersion = '1.0.0'
        teleAgentVersion = $productVersion
        installedAt = (Get-Date).ToString('o')
        sourceAsarSha256 = $currentHash
        themedAsarSha256 = $themedHash
        backupPath = $backup
        backupSha256 = $backupHash
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Write-Host 'The Shin-chan theme is installed and the original archive is backed up.'

    if ($Restart) {
        Start-Process -FilePath $exe
        Write-Host 'TeleAgent was reopened.'
    }
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
