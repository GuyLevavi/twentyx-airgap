# SETUP.ps1 -- one-shot Windows entry point for a twentyx install.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\SETUP.ps1
#       [-Distro twentyx] [-InstallDir C:\wsl\nixos] [-User jensen]
#       [-Base <dir>] [-SkipUnpack]
#       [-Release <id>] [-GitlabUrl <url> -GitlabProject <g/p>] [-GitlabToken <t>]
#
# MUST run from an elevated PowerShell (Administrator): wsl --import
# registers a machine-wide distro.
#
# What it does (idempotent):
#   1. imports nixos-wsl.tar.gz from -Base as a WSL2 distro named -Distro;
#      when that distro is already registered the import is skipped
#   2. runs UNPACK.ps1 from -Base (Windows side: kit, Zed themes/settings,
#      WezTerm, VS Code) unless -SkipUnpack
#   3. runs apply.sh as root in the distro: the store release in -Base
#      (MANIFEST.txt + wsl-delta.nar or wsl-full.nar) becomes the system
#   4. with -GitlabUrl/-GitlabProject: clones (or pulls) the inner repo to
#      ~/twentyx and runs its wsl/link.sh, which links the dotfiles into
#      $HOME and stages the internal CA
#
# Missing files are fetched from the inner project's GitLab generic package
# registry when -GitlabUrl/-GitlabProject are set (the project is public; a
# token only for a private mirror). The layout is CONTRACT.md's:
#   twentyx-store/<RELEASE>/       MANIFEST.txt, apply.sh, wsl-<KIND>.nar
#   twentyx-store/<BASE_RELEASE>/  nixos-wsl.tar.gz, windows-kit-*.tar.gz
# -Release defaults to the RELEASE= line of MANIFEST.txt in -Base; the inner
# repo pins the current one in STORE_RELEASE. Registry fetches trust the
# internal GitLab with a carried ca-bundle.crt (beside the script or in
# env\); without one, Windows must already trust the CA.
param(
    [string]$Distro = "twentyx",
    [string]$InstallDir = "C:\wsl\nixos",
    [string]$User = "jensen",
    [string]$Base = $PSScriptRoot,
    [string]$Release = "",
    [string]$GitlabUrl = $env:GITLAB_URL,
    [string]$GitlabProject = $env:GITLAB_PROJECT,
    [string]$GitlabToken = $env:GITLAB_TOKEN,
    [switch]$SkipUnpack
)
$ErrorActionPreference = "Stop"

function Say($m) { Write-Host "==> $m" -ForegroundColor Cyan }

$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
if (-not $isAdmin) {
    throw "administrator rights required -- re-run from an elevated PowerShell:`n  powershell -ExecutionPolicy Bypass -File `"$PSCommandPath`""
}

Say "base: $Base"
$fetch = [bool]($GitlabUrl -and $GitlabProject)
$manifest = Join-Path $Base "MANIFEST.txt"

function Get-ManifestValue([string]$Key) {
    if (-not (Test-Path $manifest)) { return "" }
    $line = Get-Content $manifest | Where-Object { $_ -like "$Key=*" } | Select-Object -First 1
    if ($line) { return ($line -replace "^$Key=", "").Trim() }
    return ""
}

function Get-GitlabFile([string]$Rel, [string]$Name) {
    $dest = Join-Path $Base $Name
    $proj = $GitlabProject.Replace("/", "%2F")
    $url = "$($GitlabUrl.TrimEnd('/'))/api/v4/projects/$proj/packages/generic/twentyx-store/$Rel/$Name"
    Say "fetching $url"
    # A private CA the Windows store does not trust yet: use the carried
    # bundle with curl.exe (ships with Windows 10 1803+). No bypass -- the
    # bundle is the pin. Without one, Invoke-WebRequest needs the CA trusted.
    $ca = Join-Path $Base "ca-bundle.crt"
    if (-not (Test-Path $ca)) { $ca = Join-Path $Base "env\ca-bundle.crt" }
    if (Test-Path $ca) {
        $cargs = @("-fSL", "--connect-timeout", "10", "--cacert", $ca)
        if ($GitlabToken) { $cargs += @("-H", "PRIVATE-TOKEN: $GitlabToken") }
        $cargs += @("-o", $dest, $url)
        curl.exe @cargs
        if ($LASTEXITCODE -ne 0) { throw "curl.exe failed for $Name (exit $LASTEXITCODE)" }
    } else {
        $headers = @{}
        if ($GitlabToken) { $headers["PRIVATE-TOKEN"] = $GitlabToken }
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $url -Headers $headers -OutFile $dest -TimeoutSec 600
    }
}

# Fetch $Name from release $Rel unless it is already in -Base.
function Need([string]$Rel, [string]$Name) {
    if (Test-Path (Join-Path $Base $Name)) { return }
    if (-not $fetch) {
        $hint = if (Test-Path (Join-Path $Base "$Name.7z")) { " (extract the .7z transport containers with 7-Zip first)" } else { "" }
        throw "missing $(Join-Path $Base $Name)$hint"
    }
    if (-not $Rel) { throw "no release to fetch $Name from -- pass -Release <id> (the inner repo's STORE_RELEASE)" }
    Get-GitlabFile $Rel $Name
}

# -- 0. the release --------------------------------------------------------
if (-not $Release) { $Release = Get-ManifestValue "RELEASE" }
Need $Release "MANIFEST.txt"
if ($Release -and (Get-ManifestValue "RELEASE") -ne $Release) {
    throw "MANIFEST.txt in $Base is release $(Get-ManifestValue 'RELEASE'), not $Release -- use a clean folder"
}
$Release = Get-ManifestValue "RELEASE"
$baseRelease = Get-ManifestValue "BASE_RELEASE"
$kind = Get-ManifestValue "KIND"
Say "store release $Release ($kind against $baseRelease)"

# -- 1. the distro ---------------------------------------------------------
$registered = @(wsl -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($registered -contains $Distro) {
    Say "distro '$Distro' already registered -- skipping import"
} else {
    Need $baseRelease "nixos-wsl.tar.gz"
    $rootfs = Join-Path $Base "nixos-wsl.tar.gz"
    Say "importing $rootfs -> $InstallDir (WSL2)"
    New-Item -ItemType Directory -Force -Path $InstallDir | Out-Null
    wsl --import $Distro $InstallDir $rootfs --version 2
    if ($LASTEXITCODE -ne 0) { throw "wsl --import failed ($LASTEXITCODE)" }
}

# -- 2. the Windows side ---------------------------------------------------
if ($SkipUnpack) {
    Say "UNPACK.ps1 skipped (-SkipUnpack)"
} else {
    Need $baseRelease (Get-ManifestValue "WINDOWS_KIT")
    $unpack = Join-Path $Base "UNPACK.ps1"
    if (-not (Test-Path $unpack)) { throw "missing $unpack" }
    Say "running UNPACK.ps1 -Base $Base"
    & $unpack -Base $Base
}

# -- 3. the store release --------------------------------------------------
# NixOS-WSL automounts the Windows drives at /mnt/<drive>, so the mapping is
# deterministic. wslpath needs a booted distro and its first boot prints to
# stdout, which made the captured line unreliable.
$baseWsl = ("/mnt/" + $Base.Substring(0, 1).ToLowerInvariant() + $Base.Substring(2).Replace('\', '/')).TrimEnd('/')
Need $Release "apply.sh"
# A fresh import from the same base needs no NAR when the release is the base.
if ($kind -eq "delta" -or ($registered -contains $Distro)) { Need $Release "wsl-$kind.nar" }
Say "running apply.sh as root in '$Distro'"
wsl -d $Distro -u root -- bash "$baseWsl/apply.sh" "$baseWsl"
if ($LASTEXITCODE -ne 0) { throw "apply.sh failed ($LASTEXITCODE)" }

# -- 4. the inner repo: config ---------------------------------------------
# The clone at ~/twentyx is the live config tree: wsl/link.sh links its
# dotfiles into $HOME, so edit, commit, push is the whole workflow. The first
# clone cannot trust the internal CA yet (link.sh stages it from the clone's
# env/), hence sslVerify=false. A numeric project id cannot be cloned as a URL
# path. An embedded token goes into the URL verbatim -- GitLab tokens are
# alphanumeric.
$repoDir = "/home/$User/twentyx"
if ($fetch -and $GitlabProject -notmatch '^\d+$') {
    $clean = "$($GitlabUrl.TrimEnd('/'))/$GitlabProject.git"
    $remote = $clean
    if ($GitlabToken) { $remote = $clean -replace '^https://', "https://oauth2:$GitlabToken@" }
    Say "syncing $repoDir from $GitlabUrl/$GitlabProject"
    wsl -d $Distro -u $User -- test -d "$repoDir/.git"
    if ($LASTEXITCODE -eq 0) {
        # --rebase: this laptop's config commits are first-class.
        wsl -d $Distro -u $User -- git -C $repoDir -c http.sslVerify=false pull --rebase
    } else {
        wsl -d $Distro -u $User -- git -c http.sslVerify=false clone $remote $repoDir
        if ($LASTEXITCODE -eq 0) {
            wsl -d $Distro -u $User -- git -C $repoDir remote set-url origin $clean
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "git clone/pull failed ($LASTEXITCODE)" }
}
wsl -d $Distro -u $User -- test -x "$repoDir/wsl/link.sh"
if ($LASTEXITCODE -eq 0) {
    Say "running wsl/link.sh as $User"
    wsl -d $Distro -u $User -- bash "$repoDir/wsl/link.sh"
    if ($LASTEXITCODE -ne 0) { throw "wsl/link.sh failed ($LASTEXITCODE)" }
} else {
    Say "no $repoDir yet -- clone the inner repo there and run wsl/link.sh for the dotfiles"
}

# -- 5. what next ----------------------------------------------------------
Say "done. Verify inside the distro:"
Say "  wsl -d $Distro"
Say "  systemctl --failed"
Say "configs follow $repoDir/dotfiles: edit ~/.config/<file>, then git -C $repoDir commit/push"
