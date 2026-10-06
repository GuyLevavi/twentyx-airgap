#!/usr/bin/env bash
# setup-wsl.sh -- one-shot setup/update INSIDE the twentyx distro, as root:
#
#   wsl -d twentyx -u root -- bash /mnt/c/twentyx/setup-wsl.sh
#
# TRANSFER defaults to the directory this script lives in (override with
# TRANSFER=/path). Steps:
#   1. the text layer (libexec, agent, dotfiles) -- overlay /opt/twentyx
#   2. the runtime CA + pip.conf into /var/lib/airgap-env
#   3. the closure delta (wsl-update.nar), when one is carried: import, set
#      the system profile, switch
#   4. re-seed $HOME (defaults + dotfiles)
#
# Rollback: nix-env -p /nix/var/nix/profiles/system --rollback &&
#           /nix/var/nix/profiles/system/bin/switch-to-configuration switch
set -euo pipefail

T="${TRANSFER:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ "$(id -u)" = 0 ] || {
    echo "run me as root: wsl -d twentyx -u root -- bash $T/setup-wsl.sh" >&2
    exit 1
}
[ -d "$T" ] || { echo "transfer dir not found: $T" >&2; exit 1; }
[ -f "$T/repo-layer.tar" ] || { echo "missing $T/repo-layer.tar" >&2; exit 1; }

# 1. text layer (dotfiles, libexec, agent) -- overlay the opt/ subtree
say "overlaying the text layer"
tar -xf "$T/repo-layer.tar" -C / opt
. /opt/twentyx/libexec/common.sh

# 2. runtime CA bundle + pip.conf; the oneshot concatenates the CA onto the
# system bundle and the /etc symlinks point at the result.
install -Dm644 "$T/ca-bundle.crt" /var/lib/airgap-env/ca-bundle.crt 2>/dev/null || true
install -Dm644 "$T/pip.conf" /var/lib/airgap-env/pip.conf 2>/dev/null || true
systemctl restart airgap-ca 2>/dev/null || true

# 3. closure delta
if [ -f "$T/wsl-update.nar" ]; then
    NEW=$(sed -n 's/^WSL_SYSTEM=//p' "$T/MANIFEST.txt")
    BASE=$(sed -n 's/^WSL_BASE=//p' "$T/MANIFEST.txt")
    [ -n "$NEW" ] || die "MANIFEST.txt has no WSL_SYSTEM= line"
    if [ -n "$BASE" ] && [ ! -e "$BASE" ]; then
        die "this update is a delta against $BASE which is not in the store; carry the full wsl-update.nar instead"
    fi
    say "importing the closure delta"
    nix-store --import < "$T/wsl-update.nar"
    nix-store --check-validity "$NEW"
    nix-env -p /nix/var/nix/profiles/system --set "$NEW"
    /nix/var/nix/profiles/system/bin/switch-to-configuration switch
else
    say "no wsl-update.nar carried -- text layer only"
fi

# 4. seed $HOME from the updated tree (defaults symlinks, dotfiles once)
systemctl restart seed-home 2>/dev/null || true

say "done."
