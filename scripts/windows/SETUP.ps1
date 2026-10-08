# SETUP.ps1 -- one-shot Windows entry point for the airgap transfer.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\SETUP.ps1
#       [-Distro twentyx] [-InstallDir C:\wsl\nixos] [-User jensen]
#       [-Base <dir>] [-SkipUnpack]
#
# MUST run from an elevated PowerShell (Administrator): wsl --import
# registers a machine-wide distro.
#
# What it does (idempotent):
#   1. imports nixos-wsl.tar.gz from -Base as a WSL2 distro named -Distro;
#      when that distro is already registered the import is skipped
#   2. runs UNPACK.ps1 from -Base (Windows side: kit, Zed themes/settings,
#      WezTerm, VS Code) unless -SkipUnpack
#   3. runs setup-wsl.sh as root inside the distro (overlay the text layer,
#      stage the runtime CA, apply the closure delta when carried); the
#      transfer dir is passed through as TRANSFER so -Base works outside
#      C:\twentyx
#   4. prints the verification commands
#
# The Linux side of the kit -- VS Code extensions included -- is installed
# by setup-wsl.sh, not by this script. See docs/MANUAL.md.
param(
    [string]$Distro = "twentyx",
    [string]$InstallDir = "C:\wsl\nixos",
    [string]$User = "jensen",
    [string]$Base = $PSScriptRoot,
    [switch]$SkipUnpack
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "administrator rights required -- re-run from an elevated PowerShell:`n  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

Say "base: $Base"

# -- 1. the distro ---------------------------------------------------------
$rootfs = Join-Path $Base "nixos-wsl.tar.gz"
$registered = @(wsl -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($registered -contains $Distro) {
    Say "distro '$Distro' already registered -- skipping import"
} else {
    if (-not (Test-Path $rootfs)) {
        $hint = if (Test-Path "$rootfs.7z") { " (extract the .7z transport containers with 7-Zip first)" } else { "" }
        throw "missing $rootfs$hint"
    }
    Say "importing $rootfs -> $InstallDir (WSL2)"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    wsl --import $Distro $InstallDir $rootfs --version 2
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE)" }
}

# -- 2. the Windows side ---------------------------------------------------
if ($SkipUnpack) {
    Say "UNPACK.ps1 skipped (-SkipUnpack)"
} else {
    $unpack = Join-Path $Base "UNPACK.ps1"
    if (-not (Test-Path $unpack)) { throw "missing $unpack" }
    Say "running UNPACK.ps1 -Base $Base"
    & $unpack -Base $Base
}

# -- 3. the Linux side -----------------------------------------------------
$setupWin = Join-Path $Base "setup-wsl.sh"
if (-not (Test-Path $setupWin)) { throw "missing $setupWin" }

# NixOS-WSL automounts the Windows drives at /mnt/<drive>, so the mapping is
# deterministic. wslpath needs a booted distro and its first boot prints to
# stdout, which made the captured line unreliable.
$baseWsl = ("/mnt/" + $Base.Substring(0, 1).ToLowerInvariant() + $Base.Substring(2).Replace('\', '/')).TrimEnd('/')
$setupWsl = "$baseWsl/setup-wsl.sh"
Say "transfer dir inside WSL: $baseWsl"

Say "running setup-wsl.sh as root in '$Distro' (user: $User)"
wsl -d $Distro -u root -- env "TRANSFER=$baseWsl" bash "$setupWsl" "$User"
if ($LASTEXITCODE -ne 0) { throw "setup-wsl.sh failed ($LASTEXITCODE)" }

# -- 4. what next ----------------------------------------------------------
Say "done. Verify inside the distro:"
Say "  wsl -d $Distro"
Say "  systemctl --failed"
Say "  doctor"
Say "  nvim, opencode and zed remote are seeded from the text layer"
