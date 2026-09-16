[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SourceAsar,
    [Parameter(Mandatory = $true)] [string] $OutputAsar
)

$ErrorActionPreference = 'Stop'
$ThemeVersion = '2.1.0'
$AsarPackage = '@electron/asar@4.3.0'
$UnpackDirectories = '{dist-electron/im-service,node_modules/better-sqlite3,node_modules/bindings,node_modules/file-uri-to-path}'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$ThemeCss = Join-Path $SkillRoot 'assets\shinchan-theme.css'
$ThemeAssets = @{
    '__SHINCHAN_AVATAR_DATA__' = 'shinchan-avatar.svg'
    '__SHINCHAN_PEEK_DATA__'   = 'shinchan-peek.svg'
    '__SHINCHAN_WAVE_DATA__'   = 'shinchan-wave.svg'
    '__SHIRO_DATA__'           = 'shiro.svg'
    '__SHINCHAN_SLEEP_DATA__'  = 'shinchan-sleep.svg'
    '__SHINCHAN_SCENE_DATA__'  = 'shinchan-scene.svg'
}
$MarkerBegin = '/* teleagent-shinchan-theme:begin */'
$MarkerEnd = '/* teleagent-shinchan-theme:end */'
$DecorMarker = '<!-- teleagent-shinchan-theme:decor -->'

function Resolve-NpxTool {
    $command = Get-Command npx.cmd, npx.ps1, npx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) { return @{ FilePath = $command.Source; Prefix = @('--yes', $AsarPackage) } }
    $runtimeRoot = Join-Path $env:USERPROFILE '.local\share\TeleAgent\runtimes\node'
    $node = Join-Path $runtimeRoot 'node.exe'
    $npxCli = Join-Path $runtimeRoot 'node_modules\npm\bin\npx-cli.js'
    if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $npxCli)) { return @{ FilePath = $node; Prefix = @($npxCli, '--yes', $AsarPackage) } }
    throw 'Cannot find npx or the TeleAgent Node.js runtime. app.asar cannot be processed safely.'
}

function Invoke-Asar {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $allArguments = @($script:NpxTool.Prefix) + $Arguments
    & $script:NpxTool.FilePath @allArguments
    if ($LASTEXITCODE -ne 0) { throw "The ASAR tool failed with exit code $LASTEXITCODE." }
}

function Get-DataUri([string] $Path) {
    $mime = if ([IO.Path]::GetExtension($Path) -ieq '.svg') { 'image/svg+xml' } else { 'application/octet-stream' }
    return 'data:' + $mime + ';base64,' + [Convert]::ToBase64String([IO.File]::ReadAllBytes($Path))
}

$sourcePath = (Resolve-Path -LiteralPath $SourceAsar).Path
if (-not (Test-Path -LiteralPath $ThemeCss)) { throw 'The theme CSS is missing.' }
foreach ($assetName in $ThemeAssets.Values) {
    $assetPath = Join-Path $SkillRoot ('assets\' + $assetName)
    if (-not (Test-Path -LiteralPath $assetPath)) { throw "Theme image is missing: $assetName" }
}

$outputFullPath = [IO.Path]::GetFullPath($OutputAsar)
$outputParent = Split-Path -Parent $outputFullPath
New-Item -ItemType Directory -Force -Path $outputParent | Out-Null
$work = Join-Path ([IO.Path]::GetTempPath()) ('teleagent-shinchan-theme-' + [guid]::NewGuid().ToString('N'))
$extractRoot = Join-Path $work 'app'
$script:NpxTool = Resolve-NpxTool
New-Item -ItemType Directory -Force -Path $extractRoot | Out-Null

try {
    Write-Host 'Reading TeleAgent interface resources...'
    Invoke-Asar extract $sourcePath $extractRoot
    $indexPath = Join-Path $extractRoot 'dist\index.html'
    if (-not (Test-Path -LiteralPath $indexPath)) { throw 'dist/index.html was not found. This TeleAgent package layout is unsupported.' }
    $indexHtml = [IO.File]::ReadAllText($indexPath)
    $match = [regex]::Match($indexHtml, 'href=["'']\./assets/(?<name>index-[^"'']+\.css)["'']')
    if (-not $match.Success) { throw 'The main stylesheet was not found in dist/index.html.' }
    $cssName = $match.Groups['name'].Value
    $cssPath = Join-Path $extractRoot (Join-Path 'dist\assets' $cssName)
    if (-not (Test-Path -LiteralPath $cssPath)) { throw "The main stylesheet does not exist: $cssName" }

    $css = [IO.File]::ReadAllText($cssPath)
    $escapedBegin = [regex]::Escape($MarkerBegin)
    $escapedEnd = [regex]::Escape($MarkerEnd)
    $css = [regex]::Replace($css, "(?s)$escapedBegin.*?$escapedEnd", '')
    $theme = [IO.File]::ReadAllText($ThemeCss).Replace('__THEME_VERSION__', $ThemeVersion)
    foreach ($placeholder in $ThemeAssets.Keys) {
        $assetPath = Join-Path $SkillRoot ('assets\' + $ThemeAssets[$placeholder])
        $theme = $theme.Replace($placeholder, (Get-DataUri $assetPath))
    }
    $patchedCss = $css.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $theme + [Environment]::NewLine
    [IO.File]::WriteAllText($cssPath, $patchedCss, [Text.UTF8Encoding]::new($false))

    $indexHtml = [regex]::Replace($indexHtml, '(?s)\s*<!-- teleagent-shinchan-theme:decor -->.*?<!-- /teleagent-shinchan-theme:decor -->\s*', '')
    $decor = @'
<!-- teleagent-shinchan-theme:decor -->
<div id="shinchan-theme-decor" aria-hidden="true"><i class="avatar-badge"></i><i class="shinchan-scene"></i><i class="shiro"></i><i class="sleep"></i></div>
<!-- /teleagent-shinchan-theme:decor -->
'@
    $indexHtml = $indexHtml.Replace('</body>', $decor + [Environment]::NewLine + '</body>')
    [IO.File]::WriteAllText($indexPath, $indexHtml, [Text.UTF8Encoding]::new($false))

    Write-Host 'Building the installable themed archive...'
    Invoke-Asar pack $extractRoot $outputFullPath --unpack-dir $UnpackDirectories

    if (-not (Test-Path -LiteralPath $outputFullPath)) {
        throw 'The themed archive output was not created.'
    }

    $archiveListing = Invoke-Asar list $outputFullPath | Out-String
    $archiveCssPath = '\dist\assets\' + $cssName
    if (-not $archiveListing.Contains($archiveCssPath)) {
        throw 'Archive verification failed: the main stylesheet is missing.'
    }

    $unpackedRoot = "$outputFullPath.unpacked"
    $requiredUnpackedFiles = @(
        'dist-electron\im-service\index.cjs',
        'node_modules\better-sqlite3\build\Release\better_sqlite3.node',
        'node_modules\bindings\bindings.js',
        'node_modules\file-uri-to-path\index.js'
    )
    foreach ($relativePath in $requiredUnpackedFiles) {
        if (-not (Test-Path -LiteralPath (Join-Path $unpackedRoot $relativePath))) {
            throw "Archive verification failed: unpacked runtime file is missing: $relativePath"
        }
    }

    $outputHash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash
    Write-Host "Themed archive and unpacked runtime markers verified: $outputHash"
}
finally {
    if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue }
}
