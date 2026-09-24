#!/usr/bin/env bash
# Transfer bundle: one directory, everything that crosses the gap.
#
#   ./scripts/transfer-bundle.sh            # assembles/refreshes dist/
#
# Layout when done:
#
#   dist/
#     nix-layer.tar.gz{,.sha256}        RunAI pod toolchain closure (plain)
#     nix-layer-nvim.tar.gz{,.sha256}   same + nvim flavor
#     repo-layer.tar{,.sha256}          this repo's text layer
#     nixos-wsl.tar.gz{,.sha256}        the NixOS-WSL rootfs for wsl --import
#     windows-kit/windows-kit-*.tar.gz  one archive: Zed + VS Code installers, WSL2 MSI
#     docs/                             long docs (README/ARCHITECTURE/MANUAL/NOTES)
#     START-HERE.txt                    the short page for other users
#
# Nothing needs root anywhere in this script: the NixOS-WSL tarball builder
# self-elevates via a user namespace and the output is owned by whoever runs
# it.
#
# Every tarball gets a .sha256 sidecar. Verify from ANY directory:
#   (cd <dir> && sha256sum -c ./*.sha256)
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT=dist
mkdir -p "$OUT"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# ── 1. the RunAI layers ───────────────────────────────────────────────────
if [ ! -f "$OUT/nix-layer.tar.gz" ]; then
    ./scripts/build-layers.sh "$OUT"
fi

# ── 2. the NixOS-WSL root tarball ─────────────────────────────────────────
# An existing tarball is not enough: if it predates a builder change it
# must be rebuilt. The content probe is the guard — a healthy tarball
# always carries the init shim; a stale one (pre-activation) does not.
if [ ! -f "$OUT/nixos-wsl.tar.gz" ] || ! tar -tzf "$OUT/nixos-wsl.tar.gz" 2>/dev/null | grep -m1 -q '^\./bin/init$'; then
    rm -f "$OUT/nixos-wsl.tar.gz"
    say "building the NixOS-WSL tarball"
    nix build .#wsl-tarball --no-link --print-out-paths >/dev/null
    # The builder self-elevates via a user namespace — no sudo, and the
    # output file is owned by the invoking user. -f in case the target
    # exists (stale or root-owned from older runs).
    ./result/bin/nixos-wsl-tarball-builder "$OUT/nixos-wsl.tar.gz"
    rm -f result
fi

# ── 3. the Windows kit ────────────────────────────────────────────────────
say "collecting the windows kit"
# One tar.gz: no bare .exe/.msi crosses the gap (email filters, USB scanners,
# transfer policies). Windows extracts it with its built-in tar.exe.
KIT="$(nix build .#windows-kit --no-link --print-out-paths)"
mkdir -p "$OUT/windows-kit"
# strip the store-hash prefix: ship it as a clean windows-kit-<ver>.tar.gz
KITNAME="$(basename "$KIT")"
cp -f "$KIT" "$OUT/windows-kit/${KITNAME#*-}"
rm -f result

# ── 4. the long docs + the short one ─────────────────────────────────────
say "carrying the documentation"
mkdir -p "$OUT/docs"
cp README.md ARCHITECTURE.md MANUAL.md NOTES.md TODO.md "$OUT/docs/"
# wsl/README.md is part of the WSL story; the pod tree gets its own.
cp wsl/README.md "$OUT/docs/wsl-README.md"

if [ ! -f "$OUT/START-HERE.txt" ]; then
cat > "$OUT/START-HERE.txt" <<'EOF'
START HERE — the airgap toolchain, in one page
==============================================

What you got: a Linux workstation (NixOS inside WSL2) and the pod image
for the RunAI GPU cluster, built to work with the network unplugged.
Nothing in here downloads anything at runtime — everything needed was
pinned and verified before crossing the gap.

On Windows (PowerShell as Administrator, fresh machine):

  # extract the kit archive first (Windows ships tar.exe):
  tar -xf windows-kit\windows-kit-*.tar.gz        # -> windows-kit\windows-kit\
  dism.exe /online /enable-feature /featurename:Microsoft-Windows-Subsystem-Linux /all /norestart
  dism.exe /online /enable-feature /featurename:VirtualMachinePlatform /all /norestart
  # REBOOT, then:
  msiexec /i windows-kit\windows-kit\wsl.2.9.12.0.x64.msi
  wsl --set-default-version 2
  wsl --import twentyx D:\wsl\nixos nixos-wsl.tar.gz --version 2
  wsl -d twentyx

Install the editors from windows-kit\windows-kit\ (Zed and VS Code), and
turn their auto-updaters OFF (Zed: settings auto_update=false; VS Code:
update.mode none). Both connect into the Linux side out of the box; the
matching server versions are pre-seeded.

Inside the Linux machine (fish shell):
  opencode                 the AI agent
  zed / code (Remote-SSH)  your editors
  nixos-rebuild switch --flake <where the repo lives>
                           config changes rebuild OFFLINE in seconds

Your identity comes from your workspace name (first part before the
dash). Set git identity once:  git config --global user.email you@work

Read more (in docs/): MANUAL.md = step-by-step, README.md = the map,
ARCHITECTURE.md = why it is built this way.
EOF
fi

# ── 5. sidecars for everything that is not covered yet ───────────────────
say "sha256 sidecars"
cd "$OUT"
# Always refreshed — a stale sidecar must never vouch for a new tarball.
[ -f nixos-wsl.tar.gz ] && sha256sum nixos-wsl.tar.gz > nixos-wsl.tar.gz.sha256
# the kit archive gets its own sidecar, bare filename like the others
(
    cd windows-kit 2>/dev/null || exit 0
    for kit in windows-kit-*.tar.gz; do
        [ -f "$kit" ] || continue
        sha256sum "$kit" > "$kit.sha256"
    done
)
echo "verify any time, from any directory:"
echo "  cd $OUT && sha256sum -c ./*.sha256"
echo "  cd $OUT/windows-kit && sha256sum -c ./*.sha256"

say "bundle contents:"
du -h nix-layer.tar.gz nix-layer-nvim.tar.gz repo-layer.tar nixos-wsl.tar.gz windows-kit 2>/dev/null | sort -k2
