#!/usr/bin/env bash
# setup-wsl.sh — one-shot setup INSIDE the twentyx distro, as root:
#
#   wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh [username]
#
# TRANSFER defaults to the directory this script lives in (override with
# TRANSFER=/path). The username is the positional argument if given, else
# wsl-username in the transfer, else jensen. Steps (idempotent):
#   1. clone the repo git bundle into the user's home, or fast-forward it
#   2. import the offline rebuild cache
#   3. install the kit's VS Code extensions from .vsix files, best-effort
#      (skipped when the kit or a pre-seeded server is missing)
#   4. stage ca-bundle.crt / wsl-username so the flake's git-tree evaluation
#      sees them
#   5. nixos-rebuild switch --flake <repo>#wsl as the user via sudo — never
#      as root directly; if passwordless sudo is missing (older image), a
#      hint to run the rebuild from the user's own shell
#
# What stays packed: nixos-wsl.tar.gz (wsl --import consumes it), the layer
# tarballs (crane/CI consume them), windows-kit (UNPACK.ps1 on Windows).
set -euo pipefail

TRANSFER="${TRANSFER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
USER_R="${1:-}"
if [ -z "$USER_R" ] && [ -f "$TRANSFER/wsl-username" ]; then
    # Per-machine file; trim whitespace/CR so a hand-written file cannot
    # carry a trailing newline or Windows CR into the username.
    USER_R="$(tr -d '[:space:]' < "$TRANSFER/wsl-username")"
fi
USER_R="${USER_R:-jensen}"
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

# ── 3. VS Code extensions from the kit (best-effort, offline) ────────────
# The kit may carry raw .vsix packages under windows-kit/vscode/vsix (or
# directly under windows-kit). When the distro already has a pre-seeded VS
# Code server in the user's home, install them with that server's own CLI:
# no marketplace, no network. Everything here is optional -- a missing kit,
# vsix or server is a notice, never a failure.
VSCODE_BIN="/home/$USER_R/.vscode-server/bin"
if [ -d "$TRANSFER/windows-kit" ]; then
    VSIX_FILES=()
    for dir in "$TRANSFER/windows-kit/vscode/vsix" "$TRANSFER/windows-kit"; do
        [ -d "$dir" ] || continue
        for vsix in "$dir"/*.vsix; do
            [ -f "$vsix" ] || continue
            VSIX_FILES+=("$vsix")
        done
    done
    SERVER_DIRS=("$VSCODE_BIN"/*/)
    if [ "${#VSIX_FILES[@]}" -eq 0 ]; then
        say "no .vsix files in the kit -- skipping VS Code extensions"
    elif [ "${#SERVER_DIRS[@]}" -ne 1 ] || [ ! -x "${SERVER_DIRS[0]%/}/bin/code-server" ]; then
        say "no pre-seeded VS Code server for $USER_R -- skipping kit extensions"
    else
        SERVER="${SERVER_DIRS[0]%/}"
        say "installing ${#VSIX_FILES[@]} VS Code extension(s) from the kit (best-effort)"
        for vsix in "${VSIX_FILES[@]}"; do
            runuser -u "$USER_R" -- "$SERVER/bin/code-server" --install-extension "$vsix" --force || true
        done
    fi
fi

# ── 4. stage the shipped cluster files for the flake ─────────────────────
# Flakes in a git checkout only see tracked/staged files, and these two are
# gitignored, so force-add them. `git add -A` then makes any other changed
# shipped text visible to the evaluation. No commit: the staged tree is
# exactly the flake source Nix evaluates.
for f in ca-bundle.crt wsl-username; do
    [ -f "$TRANSFER/$f" ] || continue
    say "staging $f into $REPO"
    cp -f "$TRANSFER/$f" "$REPO/$f"
    chown "$USER_R":users "$REPO/$f"
    runuser -u "$USER_R" -- git -C "$REPO" add -f -- "$f"
done
runuser -u "$USER_R" -- git -C "$REPO" add -A

# ── 5. rebuild (as the user via sudo, never as root directly) ────────────
# The imported image has passwordless sudo for wheel; older images do not,
# and sudo would sit on an unanswerable prompt. Detect that up front and
# hand the one command over instead of hanging the Windows one-shot.
if ! runuser -u "$USER_R" -- sudo -n true 2>/dev/null; then
    echo "passwordless sudo is not available for $USER_R (older image?)" >&2
    echo "log in as $USER_R and run the rebuild once from your own shell:" >&2
    echo "    sudo nixos-rebuild switch --flake ~/twentyx-airgap#wsl" >&2
    exit 1
fi
say "nixos-rebuild switch --flake $REPO#wsl (as $USER_R, via sudo)"
runuser -u "$USER_R" -- sudo nixos-rebuild switch --flake "$REPO#wsl"

say "done. Log in as $USER_R and run the smoke test (docs/wsl-SMOKE-TEST.md)."
