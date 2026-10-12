# UNPACK.ps1 -- the Windows side of a twentyx install: installers and client
# configs.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1
#       [-Base <dir>] [-Force] [-SkipVSCode] [-ConfigOnly] [-ConfigDir <dir>]
#       [-Distro twentyx] [-User jensen]
#
# What it does (idempotent; a personal file is never overwritten unless -Force):
#   1. extracts windows-kit-*.tar.gz (found in -Base only, no recursion) into
#      <Base>\windows-kit\ -- the tar already carries the windows-kit/ top
#      directory, so extracting in -Base lands it there
#   2. copies the Zed themes into %APPDATA%\Zed\themes and extracts the
#      vendored Zed extensions into %LOCALAPPDATA%\Zed\extensions\installed
#      (Zed rebuilds index.json from there at startup)
#   3. installs WezTerm and VS Code silently when no local install exists
#      (-SkipVSCode skips VS Code)
#   4. installs the client configs -- .wezterm.lua, Zed settings.json, VS Code
#      settings.json -- when absent; when a real file exists it writes a
#      *.example next to it and says so
#
# The configs are versioned in the inner repo's windows\ folder. Their source,
# first hit wins: -ConfigDir; the clone in the distro
# (\\wsl.localhost\<Distro>\home\<User>\twentyx\windows); the kit's copies,
# which are only first-install defaults. After a `git pull` that touches
# windows\, re-run with -ConfigOnly (and -Force to replace your files).
#
# It does NOT touch nixos-wsl.tar.gz (wsl --import consumes it) and never
# opens the layer tarballs (crane/CI consume those). The Linux side is
# SETUP.ps1's (apply.sh, then the inner repo's wsl/link.sh); the VS Code
# server and its extensions are seeded by the distro itself.
param(
    [string]$Base = $PSScriptRoot,
    [switch]$Force,
    [switch]$SkipVSCode,
    [switch]$ConfigOnly,
    [string]$ConfigDir = "",
    [string]$Distro = "twentyx",
    [string]$User = "jensen"
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

Say "base: $Base"
$kitRoot = Join-Path $Base "windows-kit"
$zedDir = Join-Path $env:APPDATA "Zed"

if (-not $ConfigOnly) {
    $kit = Get-ChildItem -Path $Base -Filter "windows-kit-*.tar.gz" -File | Select-Object -First 1
    if (-not $kit) {
        $hint = if (Get-ChildItem -Path $Base -Filter "windows-kit-*.tar.gz.7z" -File) { " (extract the .7z transport containers with 7-Zip first)" } else { "" }
        throw "windows-kit-*.tar.gz not found in $Base$hint"
    }
    Say "extracting $($kit.Name) -> $kitRoot"
    tar -xzf $kit.FullName -C $Base
    if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }

    # -- Zed themes --------------------------------------------------------
    $themesDst = Join-Path $zedDir "themes"
    New-Item -ItemType Directory -Force -Path $themesDst | Out-Null
    Say "Zed themes -> $themesDst"
    Copy-Item -Force (Join-Path $kitRoot "themes\*.json") $themesDst

    # -- Zed extensions: installed\ is the source of truth -----------------
    # The remote server has no built-in adapters for nixd/tombi; the client
    # uploads installed extensions to it on connect. Zed rebuilds index.json
    # from installed\ at startup, so a stale index would only get in the way.
    $extSrc = Join-Path $kitRoot "zed-extensions"
    if (Test-Path $extSrc) {
        $extDst = Join-Path $zedDir "extensions\installed"
        New-Item -ItemType Directory -Force -Path $extDst | Out-Null
        Get-ChildItem -Path $extSrc -Filter "*.tar.gz" -File | ForEach-Object {
            $id = $_.Name -replace '\.tar\.gz$',''
            $dst = Join-Path $extDst $id
            New-Item -ItemType Directory -Force -Path $dst | Out-Null
            tar -xzf $_.FullName -C $dst
            if ($LASTEXITCODE -ne 0) { throw "tar failed for $($_.Name) ($LASTEXITCODE)" }
        }
        Remove-Item -Force (Join-Path $zedDir "extensions\index.json") -ErrorAction SilentlyContinue
        Say "Zed extensions -> $extDst"
    } else {
        Say "zed-extensions not found in the kit -- extension install skipped"
    }

    # -- installers --------------------------------------------------------
    function Install-Silent([string]$What, [string]$Exe, $Setup, [string[]]$SetupArgs) {
        if (Test-Path $Exe) {
            Say "$What already installed -- installer skipped (updates are off inside the gap)"
        } elseif ($Setup) {
            Say "installing $What (silent): $($Setup.Name)"
            Start-Process -FilePath $Setup.FullName -ArgumentList $SetupArgs -Wait
        } else {
            Say "$What installer not found in the kit -- install skipped"
        }
    }
    $silent = @('/VERYSILENT', '/SUPPRESSMSGBOXES', '/NORESTART')
    Install-Silent "WezTerm" (Join-Path $env:ProgramFiles "WezTerm\wezterm-gui.exe") `
        (Get-ChildItem -Path $kitRoot -Filter "WezTerm-*-setup.exe" -File | Select-Object -First 1) $silent
    if (-not $SkipVSCode) {
        $codeExe = "C:\Program Files\Microsoft VS Code\Code.exe"
        if (-not (Test-Path $codeExe)) { $codeExe = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe" }
        Install-Silent "VS Code" $codeExe `
            (Get-ChildItem -Path (Join-Path $kitRoot "vscode") -Filter "VSCodeSetup-x64-*.exe" -File -ErrorAction SilentlyContinue | Select-Object -First 1) `
            ($silent + '/MERGETASKS=!runcode')
    }
}

# -- client configs: the inner repo's windows\ wins ------------------------
if (-not $ConfigDir) {
    # \\wsl.localhost on current Windows, \\wsl$ on older Windows 10.
    foreach ($share in @("wsl.localhost", "wsl$")) {
        $clone = "\\$share\$Distro\home\$User\twentyx\windows"
        if (Test-Path $clone) { $ConfigDir = $clone; break }
    }
}
# Config source for one file: the config dir (flat), else its place in the kit.
function Get-ConfigSrc([string]$Name, [string]$KitRel) {
    if ($ConfigDir) { return (Join-Path $ConfigDir $Name) }
    return (Join-Path $kitRoot $KitRel)
}
if ($ConfigDir) { Say "configs from $ConfigDir" } else { Say "configs from the kit (first-install defaults)" }

# A real file is yours: write <Example> beside it instead, unless -Force.
function Install-Config([string]$Src, [string]$Dst, [string]$Example) {
    if (-not (Test-Path $Src)) { Say "$Src not found -- skipped"; return }
    New-Item -ItemType Directory -Force -Path (Split-Path $Dst) | Out-Null
    if ((Test-Path $Dst) -and -not $Force) {
        Copy-Item -Force $Src $Example
        Say "$Dst exists -- wrote $Example to merge from (or re-run with -Force)"
    } else {
        Copy-Item -Force $Src $Dst
        Say "installed $Dst"
    }
}
Install-Config (Get-ConfigSrc "wezterm.lua" "wezterm.lua") `
    (Join-Path $env:USERPROFILE ".wezterm.lua") (Join-Path $env:USERPROFILE ".wezterm.lua.example")
Install-Config (Get-ConfigSrc "zed-client-settings.json" "zed-client-settings.json") `
    (Join-Path $zedDir "settings.json") (Join-Path $zedDir "zed-client-settings.example.json")
if (-not $SkipVSCode) {
    $codeUser = Join-Path $env:APPDATA "Code\User"
    Install-Config (Get-ConfigSrc "vscode-settings.json" "vscode\vscode-settings.json") `
        (Join-Path $codeUser "settings.json") (Join-Path $codeUser "settings.example.json")
}

Say "done."
