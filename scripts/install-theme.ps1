[CmdletBinding()]
param(
    [string] $TeleAgentRoot,
    [switch] $Restart,
    [switch] $ForceUnsupportedVersion
)

$ErrorActionPreference = 'Stop'
$SupportedVersions = @('2.5.2', '2.5.2.0')
$ThemeVersion = '1.0.2'
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
        Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue
    }
    $deadline = (Get-Date).AddSeconds(10)
    do {
        $remaining = Get-CimInstance Win32_Process -Filter "Name='TeleAgent.exe'" -ErrorAction SilentlyContinue |
            Where-Object { $_.ExecutablePath -eq $ExecutablePath }
        if (-not $remaining) { return }
        foreach ($target in $remaining) { Stop-Process -Id $target.ProcessId -Force -ErrorAction SilentlyContinue }
        Start-Sleep -Milliseconds 200
    } while ((Get-Date) -lt $deadline)
    if ($remaining) {
        throw 'TeleAgent processes did not exit within 10 seconds.'
    }
}

function Get-AsarHeaderHash {
    param([Parameter(Mandatory = $true)] [string] $Path)
    $stream = [IO.File]::OpenRead($Path)
    try {
        $prefix = New-Object byte[] 16
        if ($stream.Read($prefix, 0, 16) -ne 16) { throw 'The ASAR header is incomplete.' }
        $headerLength = [BitConverter]::ToUInt32($prefix, 12)
        $header = New-Object byte[] $headerLength
        if ($stream.Read($header, 0, $headerLength) -ne $headerLength) { throw 'The ASAR header could not be read.' }
        $sha = [Security.Cryptography.SHA256]::Create()
        try { return ([BitConverter]::ToString($sha.ComputeHash($header))).Replace('-', '').ToLowerInvariant() }
        finally { $sha.Dispose() }
    }
    finally { $stream.Dispose() }
}

function Copy-WithIntegrityHash {
    param(
        [Parameter(Mandatory = $true)] [string] $Source,
        [Parameter(Mandatory = $true)] [string] $Destination,
        [Parameter(Mandatory = $true)] [string] $OldHash,
        [Parameter(Mandatory = $true)] [string] $NewHash
    )
    if (($OldHash -notmatch '^[0-9a-f]{64}$') -or ($NewHash -notmatch '^[0-9a-f]{64}$')) {
        throw 'The ASAR integrity hash format is invalid.'
    }
    $bytes = [IO.File]::ReadAllBytes($Source)
    $oldBytes = [Text.Encoding]::ASCII.GetBytes($OldHash)
    $newBytes = [Text.Encoding]::ASCII.GetBytes($NewHash)
    $matches = New-Object System.Collections.Generic.List[int]
    $searchFrom = 0
    while ($searchFrom -le ($bytes.Length - $oldBytes.Length)) {
        $candidate = [Array]::IndexOf($bytes, [byte]$oldBytes[0], $searchFrom)
        if ($candidate -lt 0) { break }
        $isMatch = $true
        for ($index = 1; $index -lt $oldBytes.Length; $index++) {
            if ($bytes[$candidate + $index] -ne $oldBytes[$index]) { $isMatch = $false; break }
        }
        if ($isMatch) { $matches.Add($candidate) }
        $searchFrom = $candidate + 1
    }
    if ($matches.Count -ne 1) {
        throw "Expected exactly one embedded ASAR integrity hash, found $($matches.Count)."
    }
    [Array]::Copy($newBytes, 0, $bytes, $matches[0], $newBytes.Length)
    [IO.File]::WriteAllBytes($Destination, $bytes)
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
$sourceAsar = $asar
$sourceHash = $currentHash
$backup = $null
$backupHash = $null
$currentState = $null
if (Test-Path -LiteralPath $metadataPath) {
    $currentState = Get-Content -LiteralPath $metadataPath -Raw | ConvertFrom-Json
    if (($currentState.themedAsarSha256 -eq $currentHash) -and ($currentState.themeVersion -eq $ThemeVersion)) {
        Write-Host 'The Shin-chan theme is already installed.'
        if ($Restart) { Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $exe) }
        exit 0
    }
    if ($currentState.themedAsarSha256 -eq $currentHash) {
        $candidateBackup = [string]$currentState.backupPath
        if (-not (Test-Path -LiteralPath $candidateBackup)) {
            throw 'The original archive backup is missing. Theme upgrade stopped.'
        }
        $candidateHash = (Get-FileHash -LiteralPath $candidateBackup -Algorithm SHA256).Hash
        if ($candidateHash -ne [string]$currentState.backupSha256) {
            throw 'The original archive backup failed verification. Theme upgrade stopped.'
        }
        $sourceAsar = $candidateBackup
        $sourceHash = [string]$currentState.sourceAsarSha256
        $backup = $candidateBackup
        $backupHash = $candidateHash
        Write-Host "Upgrading the existing theme from version $($currentState.themeVersion) using its verified original backup."
    }
}

$work = Join-Path ([IO.Path]::GetTempPath()) ('teleagent-shinchan-install-' + [guid]::NewGuid().ToString('N'))
$themedAsar = Join-Path $work 'app.asar'
$themedExe = Join-Path $work 'TeleAgent.exe'
New-Item -ItemType Directory -Force -Path $work | Out-Null

try {
    $patchSource = $sourceAsar
    $sourceUnpacked = "$sourceAsar.unpacked"
    if (-not (Test-Path -LiteralPath $sourceUnpacked)) {
        $installedUnpacked = "$asar.unpacked"
        if (($sourceAsar -ne $asar) -and (Test-Path -LiteralPath $installedUnpacked)) {
            $stagedSourceRoot = Join-Path $work 'source'
            $patchSource = Join-Path $stagedSourceRoot 'app.asar'
            New-Item -ItemType Directory -Force -Path $stagedSourceRoot | Out-Null
            Copy-Item -LiteralPath $sourceAsar -Destination $patchSource -Force
            Copy-Item -LiteralPath $installedUnpacked -Destination "$patchSource.unpacked" -Recurse -Force
            Write-Host 'Paired the verified original archive with TeleAgent runtime files for the upgrade.'
        }
    }

    Write-Host "Detected TeleAgent $productVersion"
    & $PatchScript -SourceAsar $patchSource -OutputAsar $themedAsar
    if ($LASTEXITCODE -ne 0) { throw 'The theme build failed.' }

    $themedHash = (Get-FileHash -LiteralPath $themedAsar -Algorithm SHA256).Hash
    $sourceHeaderHash = Get-AsarHeaderHash $sourceAsar
    $themedHeaderHash = Get-AsarHeaderHash $themedAsar
    New-Item -ItemType Directory -Force -Path $stateRoot | Out-Null
    if (-not $backup) {
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $backup = Join-Path $stateRoot "app.asar.$stamp.bak"
        Copy-Item -LiteralPath $asar -Destination $backup -Force
        $backupHash = (Get-FileHash -LiteralPath $backup -Algorithm SHA256).Hash
        if ($backupHash -ne $currentHash) { throw 'The original archive backup failed verification. Installation stopped.' }
    }

    $exeBackup = $null
    $exeBackupHash = $null
    if ($backup -and $currentState -and $currentState.exeBackupPath) {
        $exeBackup = [string]$currentState.exeBackupPath
        if (-not (Test-Path -LiteralPath $exeBackup)) { throw 'The original executable backup is missing. Theme upgrade stopped.' }
        $exeBackupHash = (Get-FileHash -LiteralPath $exeBackup -Algorithm SHA256).Hash
        if ($exeBackupHash -ne [string]$currentState.exeBackupSha256) { throw 'The executable backup failed verification. Theme upgrade stopped.' }
    }

    $oldIntegrityHash = $sourceHeaderHash
    if ($backup -and $currentState -and $currentState.themedAsarHeaderSha256) {
        $candidateOldHash = [string]$currentState.themedAsarHeaderSha256
        $exeText = [Text.Encoding]::ASCII.GetString([IO.File]::ReadAllBytes($exe))
        if ($exeText.Contains($candidateOldHash)) { $oldIntegrityHash = $candidateOldHash }
    }
    if (-not $exeBackup) {
        if ($oldIntegrityHash -ne $sourceHeaderHash) { throw 'The executable was previously patched but its original backup is unavailable.' }
        $stamp = Get-Date -Format 'yyyyMMdd-HHmmss'
        $exeBackup = Join-Path $stateRoot "TeleAgent.exe.$stamp.bak"
        Copy-Item -LiteralPath $exe -Destination $exeBackup -Force
        $exeBackupHash = (Get-FileHash -LiteralPath $exeBackup -Algorithm SHA256).Hash
    }
    Copy-WithIntegrityHash -Source $exe -Destination $themedExe -OldHash $oldIntegrityHash -NewHash $themedHeaderHash

    Write-Host 'Closing TeleAgent and applying the theme...'
    Stop-SelectedTeleAgent $exe
    Copy-Item -LiteralPath $themedExe -Destination $exe -Force
    Copy-Item -LiteralPath $themedAsar -Destination $asar -Force
    if (Test-Path -LiteralPath "$themedAsar.unpacked") {
        New-Item -ItemType Directory -Force -Path "$asar.unpacked" | Out-Null
        Copy-Item -Path (Join-Path "$themedAsar.unpacked" '*') -Destination "$asar.unpacked" -Recurse -Force
    }
    $installedHash = (Get-FileHash -LiteralPath $asar -Algorithm SHA256).Hash
    if ($installedHash -ne $themedHash) {
        Copy-Item -LiteralPath $backup -Destination $asar -Force
        Copy-Item -LiteralPath $exeBackup -Destination $exe -Force
        throw 'Post-install verification failed. The original archive was restored.'
    }

    $state = [ordered]@{
        themeId = 'teleagent-shinchan-theme'
        themeVersion = $ThemeVersion
        teleAgentVersion = $productVersion
        installedAt = (Get-Date).ToString('o')
        sourceAsarSha256 = $sourceHash
        themedAsarSha256 = $themedHash
        sourceAsarHeaderSha256 = $sourceHeaderHash
        themedAsarHeaderSha256 = $themedHeaderHash
        backupPath = $backup
        backupSha256 = $backupHash
        exeBackupPath = $exeBackup
        exeBackupSha256 = $exeBackupHash
    }
    $state | ConvertTo-Json | Set-Content -LiteralPath $metadataPath -Encoding UTF8
    Write-Host 'The Shin-chan theme is installed and the original archive is backed up.'

    if ($Restart) {
        Start-Process -FilePath 'explorer.exe' -ArgumentList ('"{0}"' -f $exe)
        Write-Host 'TeleAgent was reopened.'
    }
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
