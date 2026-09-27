# UNPACK.ps1 — one-shot unpacking of the Windows side of the transfer.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1
#
# What it does (idempotent; a personal file is never overwritten):
#   1. extracts windows-kit-*.tar.gz next to this script
#   2. copies the Zed themes into %APPDATA%\Zed\themes
#   3. installs zed-client-settings.json / wezterm.lua when absent; when a
#      real file exists it writes a *.example next to it and says so
#
# It does NOT touch nixos-wsl.tar.gz (wsl --import consumes it as-is) and
# never opens the layer tarballs (crane/CI consume those). The Linux side is
# handled by setup-wsl.sh, run inside the distro.
param(
    [string]$Base = $PSScriptRoot,
    [switch]$Force
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

Say "base: $Base"
$kit = Get-ChildItem -Path $Base -Filter "windows-kit-*.tar.gz" | Select-Object -First 1
if (-not $kit) { throw "windows-kit-*.tar.gz not found in $Base" }

$kitDir = Join-Path $Base "windows-kit"
Say "extracting $($kit.Name) -> $kitDir"
New-Item -ItemType Directory -Force -Path $kitDir | Out-Null
tar -xzf $kit.FullName -C $kitDir
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }
$kitRoot = Join-Path $kitDir "windows-kit"

# ── Zed themes ────────────────────────────────────────────────────────────
$zedDir = Join-Path $env:APPDATA "Zed"
$themesDst = Join-Path $zedDir "themes"
New-Item -ItemType Directory -Force -Path $themesDst | Out-Null
Say "Zed themes -> $themesDst"
Copy-Item -Force (Join-Path $kitRoot "themes\*.json") $themesDst

# ── Zed client settings: a real file wins ────────────────────────────────
$settings = Join-Path $zedDir "settings.json"
$settingsSrc = Join-Path $kitRoot "zed-client-settings.json"
if ((Test-Path $settings) -and -not $Force) {
    $example = Join-Path $zedDir "zed-client-settings.example.json"
    Copy-Item -Force $settingsSrc $example
    Say "settings.json already exists — wrote $example"
    Say "  merge from it: auto_update, telemetry, auto_install_extensions, agent.terminal_init_command"
} else {
    Copy-Item -Force $settingsSrc $settings
    Say "Zed settings installed -> $settings"
}

# ── WezTerm ──────────────────────────────────────────────────────────────
$wez = Join-Path $env:USERPROFILE ".wezterm.lua"
$wezSrc = Join-Path $kitRoot "wezterm.lua"
if ((Test-Path $wez) -and -not $Force) {
    Copy-Item -Force $wezSrc "$wez.example"
    Say ".wezterm.lua already exists — wrote $wez.example"
    Say "  make sure it has: config.enable_kitty_keyboard = true  (shift+enter in TUIs)"
} else {
    Copy-Item -Force $wezSrc $wez
    Say "WezTerm config installed -> $wez"
}

Say "done."
Say "next: fresh import (skip if you keep the current distro):"
Say "  wsl --import twentyx C:\wsl\nixos $Base\nixos-wsl.tar.gz --version 2"
Say "then, inside the distro:"
Say "  wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh"
