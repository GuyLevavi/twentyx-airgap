# SETUP.ps1 -- one-shot Windows entry point for the airgap transfer.
#
#   powershell -ExecutionPolicy Bypass -File C:\twentyx\SETUP.ps1
#       [-Distro twentyx] [-InstallDir C:\wsl\nixos] [-User jensen]
#       [-Base <dir>] [-SkipUnpack]
#       [-Version 0.1.0] [-GitlabUrl <url> -GitlabProject <g/p|id>] [-GitlabToken <t>]
#
# MUST run from an elevated PowerShell (Administrator): wsl --import
# registers a machine-wide distro.
#
# What it does (idempotent):
#   1. imports nixos-wsl.tar.gz from -Base as a WSL2 distro named -Distro;
#      when that distro is already registered the import is skipped. When the
#      tarball is absent and -GitlabUrl/-GitlabProject are set, it is fetched
#      from the project's generic package registry (the names
#      push-gitlab-packages.sh publishes); -Version defaults to MANIFEST.txt's
#      VERSION= line, then to the repo's VERSION file. The project is public,
#      so no token is needed (-GitlabToken remains for a private mirror)
#   2. runs UNPACK.ps1 from -Base (Windows side: kit, Zed themes/settings,
#      WezTerm, VS Code) unless -SkipUnpack. A missing windows-kit-*.tar.gz
#      is fetched too: MANIFEST.txt names the file in its WINDOWS_KIT= line
#   3. the Linux side: with -GitlabUrl/-GitlabProject it clones (or pulls)
#      ~/twentyx in the distro and runs that checkout's setup-wsl.sh,
#      so home configs link into the clone; without them it runs the carried
#      setup-wsl.sh, passing the transfer dir through as TRANSFER so -Base
#      works outside C:\twentyx
#   4. prints the verification commands
#
# Registry fetches trust the internal GitLab with the carried ca-bundle.crt
# (beside the script, a transfer folder's env\, or the repo's env\) via
# curl.exe; without one, Windows must already trust the CA.
#
# The Linux side of the kit -- VS Code extensions included -- is installed
# by setup-wsl.sh, not by this script. See docs/MANUAL.md.
param(
    [string]$Distro = "twentyx",
    [string]$InstallDir = "C:\wsl\nixos",
    [string]$User = "jensen",
    [string]$Base = $PSScriptRoot,
    [string]$Version = "",
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

# -- version + registry fetch helper ----------------------------------------
# VERSION for registry fetches: MANIFEST.txt beside the script, else the repo's
# VERSION file (running from a repo: <repo>\scripts\windows\SETUP.ps1).
if (-not $Version) {
    $manifest = Join-Path $Base "MANIFEST.txt"
    if (Test-Path $manifest) {
        $line = Get-Content $manifest | Where-Object { $_ -like "VERSION=*" } | Select-Object -First 1
        if ($line) { $Version = ($line -replace "^VERSION=", "").Trim() }
    }
}
if (-not $Version) {
    $versionFile = Join-Path $Base "..\..\VERSION"
    if (Test-Path $versionFile) { $Version = (Get-Content $versionFile -First 1).Trim() }
}

function Get-GitlabFile([string]$Name, [string]$Dest) {
    if (-not $Version) { throw "-Version (or MANIFEST.txt/VERSION) is required to fetch $Name" }
    $proj = $GitlabProject.Replace("/", "%2F")
    $url = "$($GitlabUrl.TrimEnd('/'))/api/v4/projects/$proj/packages/generic/twentyx-airgap/$Version/$Name"
    Say "fetching $url"
    # A private CA the Windows store does not trust yet: use the carried
    # bundle with curl.exe (ships with Windows 10 1803+). No bypass -- the
    # bundle is the pin. Without one, Invoke-WebRequest needs the CA trusted.
    # Search: beside the script, a transfer folder's env\, the repo's env\
    # (running as <repo>\scripts\windows\SETUP.ps1).
    $ca = Join-Path $Base "ca-bundle.crt"
    if (-not (Test-Path $ca)) { $ca = Join-Path $Base "env\ca-bundle.crt" }
    if (-not (Test-Path $ca)) { $ca = Join-Path $Base "..\..\env\ca-bundle.crt" }
    if (Test-Path $ca) {
        $cargs = @("-fSL", "--cacert", $ca)
        if ($GitlabToken) { $cargs += @("-H", "PRIVATE-TOKEN: $GitlabToken") }
        $cargs += @("-o", $Dest, $url)
        curl.exe @cargs
        if ($LASTEXITCODE -ne 0) { throw "curl.exe failed for $Name (exit $LASTEXITCODE)" }
    } else {
        $headers = @{}
        if ($GitlabToken) { $headers["PRIVATE-TOKEN"] = $GitlabToken }
        $ProgressPreference = "SilentlyContinue"
        Invoke-WebRequest -Uri $url -Headers $headers -OutFile $Dest
    }
}

# -- 1. the distro ---------------------------------------------------------
$rootfs = Join-Path $Base "nixos-wsl.tar.gz"
$registered = @(wsl -l -q) -replace "`0", "" | ForEach-Object { $_.Trim() } | Where-Object { $_ -ne "" }
if ($registered -contains $Distro) {
    Say "distro '$Distro' already registered -- skipping import"
} else {
    if (-not (Test-Path $rootfs)) {
        if (-not ($GitlabUrl -and $GitlabProject)) {
            $hint = if (Test-Path "$rootfs.7z") { " (extract the .7z transport containers with 7-Zip first)" } else { "" }
            throw "missing $rootfs$hint"
        }
        Get-GitlabFile "nixos-wsl.tar.gz" $rootfs
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
    # The kit (~600 MB) may be absent on a GitLab-only machine; its filename
    # carries the Zed version, so MANIFEST.txt names it (WINDOWS_KIT=).
    $kit = Get-ChildItem -Path $Base -Filter "windows-kit-*.tar.gz" -File | Select-Object -First 1
    if (-not $kit -and $GitlabUrl -and $GitlabProject) {
        $manifest = Join-Path $Base "MANIFEST.txt"
        if (-not (Test-Path $manifest)) {
            try { Get-GitlabFile "MANIFEST.txt" $manifest }
            catch { Say "MANIFEST.txt not fetched -- $($_.Exception.Message)" }
        }
        $kitName = ""
        if (Test-Path $manifest) {
            $line = Get-Content $manifest | Where-Object { $_ -like "WINDOWS_KIT=*" } | Select-Object -First 1
            if ($line) { $kitName = ($line -replace "^WINDOWS_KIT=", "").Trim() }
        }
        if ($kitName) {
            Get-GitlabFile $kitName (Join-Path $Base $kitName)
        } else {
            Say "WINDOWS_KIT not in MANIFEST.txt -- carry windows-kit-*.tar.gz or use -SkipUnpack"
        }
    }
    $unpack = Join-Path $Base "UNPACK.ps1"
    if (-not (Test-Path $unpack)) { throw "missing $unpack" }
    Say "running UNPACK.ps1 -Base $Base"
    & $unpack -Base $Base
}

# -- 3. the Linux side -----------------------------------------------------
# With GitlabUrl+GitlabProject the distro gets the repo itself: clone (or refresh)
# ~/twentyx and run that checkout's setup-wsl.sh, so $HOME configs
# link into the clone -- edit, commit, push is the whole workflow. The
# first clone cannot trust the internal CA yet (it arrives with the repo's
# env/ and is staged by this same run), hence sslVerify=false. A numeric
# project id cannot be cloned as a URL path; fall back to the transfer.
# The project is public, so the clone needs no token; -GitlabToken still
# works for a private mirror. shortcut: an embedded token goes into the URL
# verbatim -- GitLab tokens are alphanumeric, URL-encode otherwise.
$cloned = $false
if ($GitlabUrl -and $GitlabProject -and $GitlabProject -notmatch '^\d+$') {
    $clean = "$($GitlabUrl.TrimEnd('/'))/$GitlabProject.git"
    $remote = $clean
    if ($GitlabToken) { $remote = $clean -replace '^https://', "https://oauth2:$GitlabToken@" }
    $repoDir = "/home/$User/twentyx"
    Say "syncing $repoDir from $GitlabUrl/$GitlabProject"
    wsl -d $Distro -u $User -- test -d "$repoDir/.git"
    if ($LASTEXITCODE -eq 0) {
        # --rebase: this laptop's config commits are first-class; --ff-only
        # would fail whenever main moved and the local commit is not pushed yet.
        wsl -d $Distro -u $User -- git -C $repoDir -c http.sslVerify=false pull --rebase
    } else {
        wsl -d $Distro -u $User -- git -c http.sslVerify=false clone $remote $repoDir
        if ($LASTEXITCODE -eq 0) {
            wsl -d $Distro -u $User -- git -C $repoDir remote set-url origin $clean
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "git clone/pull failed ($LASTEXITCODE)" }
    $cloned = $true
}

if ($cloned) {
    $setupWsl = "/home/$User/twentyx/scripts/setup-wsl.sh"
    Say "running setup-wsl.sh as root in '$Distro' (repo checkout)"
    # Pass the GitLab coordinates through: on an existing distro this lets
    # setup-wsl.sh fetch MANIFEST.txt + the closure delta, not just text.
    $glEnv = @("GITLAB_URL=$GitlabUrl", "GITLAB_PROJECT=$GitlabProject")
    if ($GitlabToken) { $glEnv += "GITLAB_TOKEN=$GitlabToken" }
    wsl -d $Distro -u root -- env @glEnv bash "$setupWsl"
} else {
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
}
if ($LASTEXITCODE -ne 0) { throw "setup-wsl.sh failed ($LASTEXITCODE)" }

# -- 4. what next ----------------------------------------------------------
Say "done. Verify inside the distro:"
Say "  wsl -d $Distro"
Say "  systemctl --failed"
Say "  doctor"
if ($cloned) {
    Say "configs follow $repoDir/dotfiles: edit ~/.config/<file>, then git -C $repoDir commit/push"
}
Say "  nvim, opencode and zed remote are seeded from the toolchain tree"
