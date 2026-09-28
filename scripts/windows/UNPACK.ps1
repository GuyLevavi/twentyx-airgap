# UNPACK.ps1 -- one-shot unpacking of the Windows side of the transfer.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\UNPACK.ps1 [-Base <dir>] [-Force] [-SkipVSCode]
#
# What it does (idempotent; a personal file is never overwritten unless -Force):
#   1. extracts windows-kit-*.tar.gz (found in -Base only, no recursion) into
#      <Base>\windows-kit\ -- the tar already carries the windows-kit/ top
#      directory, so extracting in -Base lands it there. setup-wsl.sh looks
#      for the .vsix files under <transfer>\windows-kit\vscode\vsix, so this
#      depth is load-bearing.
#   2. copies the Zed themes into %APPDATA%\Zed\themes
#   3. installs zed-client-settings.json / wezterm.lua when absent; when a
#      real file exists it writes a *.example next to it and says so
#   4. VS Code: installs vscode\VSCodeSetup-x64-*.exe silently when no local
#      install exists; installs vscode\vscode-settings.json into
#      %APPDATA%\Code\User\settings.json (or a settings.example.json beside
#      an existing one). -SkipVSCode skips both.
#
# It does NOT touch nixos-wsl.tar.gz (wsl --import consumes it) and never
# opens the layer tarballs (crane/CI consume those). The Linux side --
# including the kit's VS Code extensions -- is handled inside the distro by
# SETUP.ps1 / setup-wsl.sh.
param(
    [string]$Base = $PSScriptRoot,
    [switch]$Force,
    [switch]$SkipVSCode
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

Say "base: $Base"
$kit = Get-ChildItem -Path $Base -Filter "windows-kit-*.tar.gz" -File | Select-Object -First 1
if (-not $kit) { throw "windows-kit-*.tar.gz not found in $Base" }

$kitRoot = Join-Path $Base "windows-kit"
Say "extracting $($kit.Name) -> $kitRoot"
tar -xzf $kit.FullName -C $Base
if ($LASTEXITCODE -ne 0) { throw "tar failed ($LASTEXITCODE)" }

# -- Zed themes ------------------------------------------------------------
$zedDir = Join-Path $env:APPDATA "Zed"
$themesDst = Join-Path $zedDir "themes"
New-Item -ItemType Directory -Force -Path $themesDst | Out-Null
Say "Zed themes -> $themesDst"
Copy-Item -Force (Join-Path $kitRoot "themes\*.json") $themesDst

# -- Zed client settings: a real file wins ---------------------------------
$settings = Join-Path $zedDir "settings.json"
$settingsSrc = Join-Path $kitRoot "zed-client-settings.json"
if ((Test-Path $settings) -and -not $Force) {
    $example = Join-Path $zedDir "zed-client-settings.example.json"
    Copy-Item -Force $settingsSrc $example
    Say "settings.json already exists -- wrote $example"
    Say "  merge from it: auto_update, telemetry, auto_install_extensions, agent.terminal_init_command"
} else {
    Copy-Item -Force $settingsSrc $settings
    Say "Zed settings installed -> $settings"
}

# -- WezTerm ---------------------------------------------------------------
$wez = Join-Path $env:USERPROFILE ".wezterm.lua"
$wezSrc = Join-Path $kitRoot "wezterm.lua"
if ((Test-Path $wez) -and -not $Force) {
    Copy-Item -Force $wezSrc "$wez.example"
    Say ".wezterm.lua already exists -- wrote $wez.example"
    Say "  make sure it has: config.enable_kitty_keyboard = true  (shift+enter in TUIs)"
} else {
    Copy-Item -Force $wezSrc $wez
    Say "WezTerm config installed -> $wez"
}

# -- VS Code ---------------------------------------------------------------
if ($SkipVSCode) {
    Say "VS Code: skipped (-SkipVSCode)"
} else {
    $vscodeDir = Join-Path $kitRoot "vscode"
    $codeUser = Join-Path $env:APPDATA "Code\User"
    $codeSettings = Join-Path $codeUser "settings.json"
    $codeSrc = Join-Path $vscodeDir "vscode-settings.json"

    if (Test-Path $codeSrc) {
        New-Item -ItemType Directory -Force -Path $codeUser | Out-Null
        if ((Test-Path $codeSettings) -and -not $Force) {
            $codeExample = Join-Path $codeUser "settings.example.json"
            Copy-Item -Force $codeSrc $codeExample
            Say "VS Code settings.json already exists -- wrote $codeExample"
        } else {
            Copy-Item -Force $codeSrc $codeSettings
            Say "VS Code settings installed -> $codeSettings"
        }
    } else {
        Say "vscode\vscode-settings.json not found in the kit -- VS Code settings skipped"
    }

    $codeExe1 = "C:\Program Files\Microsoft VS Code\Code.exe"
    $codeExe2 = Join-Path $env:LOCALAPPDATA "Programs\Microsoft VS Code\Code.exe"
    $installed = (Test-Path $codeExe1) -or (Test-Path $codeExe2)
    $installer = $null
    if (Test-Path $vscodeDir) {
        $installer = Get-ChildItem -Path $vscodeDir -Filter "VSCodeSetup-x64-*.exe" -File | Select-Object -First 1
    }
    if ($installed) {
        Say "VS Code already installed -- installer skipped (updates are off inside the gap)"
    } elseif ($installer) {
        Say "installing VS Code (silent): $($installer.Name)"
        Start-Process -FilePath $installer.FullName `
            -ArgumentList '/VERYSILENT','/SUPPRESSMSGBOXES','/NORESTART','/MERGETASKS=!runcode' -Wait
    } else {
        Say "VS Code installer not found in the kit -- install skipped"
    }
}

Say "done."
Say "next: run the one-shot importer (imports the distro + runs the Linux side):"
Say "  powershell -ExecutionPolicy Bypass -File $Base\SETUP.ps1"
Say "VS Code extensions (vscode\vsix\*.vsix) are installed inside the distro by setup-wsl.sh."
