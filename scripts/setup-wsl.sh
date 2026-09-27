#!/usr/bin/env bash
# setup-wsl.sh — one-shot setup INSIDE the twentyx distro, as root:
#
#   wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh [username]
#
# Steps (idempotent; C: is the transfer medium):
#   1. clone the repo git bundle into the user's home, or fast-forward it
#   2. import the offline rebuild cache
#   3. nixos-rebuild switch --flake <repo>#wsl  (must not touch the network)
#
# What stays packed: nixos-wsl.tar.gz (wsl --import consumes it), the layer
# tarballs (crane/CI consume them), windows-kit (UNPACK.ps1 on Windows).
set -euo pipefail

TRANSFER="${TRANSFER:-/mnt/c/twentyx}"
USER_R="${1:-jensen}"
REPO="/home/$USER_R/twentyx-airgap"
BUNDLE="$TRANSFER/twentyx-airgap.bundle"
CACHE_TAR="$TRANSFER/wsl-rebuild.tar.gz"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || {
    echo "run me as root: wsl -d twentyx -u root -- bash $TRANSFER/setup-wsl.sh" >&2
    exit 1
}
[ -d "$TRANSFER" ] || { echo "transfer dir not found: $TRANSFER" >&2; exit 1; }

# ── 1. the repo (git bundle -> real history) ─────────────────────────────
if [ ! -d "$REPO/.git" ]; then
    [ -f "$BUNDLE" ] || { echo "missing $BUNDLE" >&2; exit 1; }
    say "cloning $BUNDLE -> $REPO"
    runuser -u "$USER_R" -- git clone "$BUNDLE" "$REPO"
else
    say "repo present: $REPO"
    # The bundle is the origin; a fast-forward picks up a newer bundle when
    # one is carried. Local commits make this fail -- that is fine, keep them.
    if runuser -u "$USER_R" -- git -C "$REPO" pull --ff-only --quiet; then
        say "fast-forwarded to the bundle tip"
    else
        say "not fast-forwardable (local commits?) -- keeping the working tree"
    fi
fi

# ── 2. offline rebuild cache ─────────────────────────────────────────────
if [ -f "$CACHE_TAR" ]; then
    say "importing $CACHE_TAR"
    mkdir -p /var/cache/nix-transfer
    tar -xzf "$CACHE_TAR" -C /var/cache/nix-transfer --strip-components=1
    nix copy --from file:///var/cache/nix-transfer --all
else
    say "wsl-rebuild.tar.gz not found -- rebuilds that need new paths will fail"
fi

# ── 3. rebuild ───────────────────────────────────────────────────────────
say "nixos-rebuild switch --flake $REPO#wsl"
nixos-rebuild switch --flake "$REPO#wsl"

say "done. Log in as $USER_R and run the smoke test (docs/wsl-SMOKE-TEST.md)."
