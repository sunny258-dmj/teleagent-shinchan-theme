[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $SourceAsar,
    [Parameter(Mandatory = $true)] [string] $OutputAsar
)

$ErrorActionPreference = 'Stop'
$ThemeVersion = '1.0.0'
$AsarPackage = '@electron/asar@4.3.0'
$SkillRoot = Split-Path -Parent $PSScriptRoot
$ThemeCss = Join-Path $SkillRoot 'assets\shinchan-theme.css'
$Avatar = Join-Path $SkillRoot 'assets\shinchan-avatar.png'
$MarkerBegin = '/* teleagent-shinchan-theme:begin */'
$MarkerEnd = '/* teleagent-shinchan-theme:end */'

function Resolve-NpxTool {
    $command = Get-Command npx.cmd, npx.ps1, npx -ErrorAction SilentlyContinue | Select-Object -First 1
    if ($command) {
        return @{ FilePath = $command.Source; Prefix = @('--yes', $AsarPackage) }
    }

    $runtimeRoot = Join-Path $env:USERPROFILE '.local\share\TeleAgent\runtimes\node'
    $node = Join-Path $runtimeRoot 'node.exe'
    $npxCli = Join-Path $runtimeRoot 'node_modules\npm\bin\npx-cli.js'
    if ((Test-Path -LiteralPath $node) -and (Test-Path -LiteralPath $npxCli)) {
        return @{ FilePath = $node; Prefix = @($npxCli, '--yes', $AsarPackage) }
    }

    throw 'Cannot find npx or the TeleAgent Node.js runtime. app.asar cannot be processed safely.'
}

function Invoke-Asar {
    param([Parameter(ValueFromRemainingArguments = $true)] [string[]] $Arguments)
    $allArguments = @($script:NpxTool.Prefix) + $Arguments
    & $script:NpxTool.FilePath @allArguments
    if ($LASTEXITCODE -ne 0) {
        throw "The ASAR tool failed with exit code $LASTEXITCODE."
    }
}

$sourcePath = (Resolve-Path -LiteralPath $SourceAsar).Path
if (-not (Test-Path -LiteralPath $ThemeCss) -or -not (Test-Path -LiteralPath $Avatar)) {
    throw 'The theme CSS or Shin-chan avatar asset is missing.'
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
    if (-not (Test-Path -LiteralPath $indexPath)) {
        throw 'dist/index.html was not found. This TeleAgent package layout is unsupported.'
    }

    $indexHtml = [IO.File]::ReadAllText($indexPath)
    $match = [regex]::Match($indexHtml, 'href=["'']\./assets/(?<name>index-[^"'']+\.css)["'']')
    if (-not $match.Success) {
        throw 'The main stylesheet was not found in dist/index.html.'
    }

    $cssName = $match.Groups['name'].Value
    $cssPath = Join-Path $extractRoot (Join-Path 'dist\assets' $cssName)
    if (-not (Test-Path -LiteralPath $cssPath)) {
        throw "The main stylesheet does not exist: $cssName"
    }

    $css = [IO.File]::ReadAllText($cssPath)
    $escapedBegin = [regex]::Escape($MarkerBegin)
    $escapedEnd = [regex]::Escape($MarkerEnd)
    $css = [regex]::Replace($css, "(?s)$escapedBegin.*?$escapedEnd", '')

    $avatarBase64 = [Convert]::ToBase64String([IO.File]::ReadAllBytes($Avatar))
    $theme = [IO.File]::ReadAllText($ThemeCss)
    $theme = $theme.Replace('__THEME_VERSION__', $ThemeVersion)
    $theme = $theme.Replace('__SHINCHAN_AVATAR_DATA__', "data:image/png;base64,$avatarBase64")
    $patchedCss = $css.TrimEnd() + [Environment]::NewLine + [Environment]::NewLine + $theme + [Environment]::NewLine
    [IO.File]::WriteAllText($cssPath, $patchedCss, [Text.UTF8Encoding]::new($false))

    Write-Host 'Building the installable themed archive...'
    Invoke-Asar pack $extractRoot $outputFullPath

    if (-not (Test-Path -LiteralPath $outputFullPath)) {
        throw 'The themed archive output was not created.'
    }

    $archiveListing = Invoke-Asar list $outputFullPath | Out-String
    $archiveCssPath = '\dist\assets\' + $cssName
    if (-not $archiveListing.Contains($archiveCssPath)) {
        throw 'Archive verification failed: the main stylesheet is missing.'
    }

    $outputHash = (Get-FileHash -LiteralPath $outputFullPath -Algorithm SHA256).Hash
    Write-Host "Themed archive verified: $outputHash"
}
finally {
    if (Test-Path -LiteralPath $work) {
        Remove-Item -LiteralPath $work -Recurse -Force -ErrorAction SilentlyContinue
    }
}
