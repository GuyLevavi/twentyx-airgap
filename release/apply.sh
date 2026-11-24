#!/usr/bin/env bash
# WSL updater for twentyx release @RELEASE@. Run inside the gap, from the
# release folder or anywhere; it reads the files beside itself.
#
#   sudo ./apply.sh [dir]
#
# [dir] holds the release files and defaults to this script's directory;
# inner's wsl/update.sh passes its download directory.
#
# Imports this release's store paths and switches the system to its
# WSL_SYSTEM (MANIFEST.txt). Safe to rerun. To undo:
#   sudo nix-env -p /nix/var/nix/profiles/system --rollback
#   sudo /nix/var/nix/profiles/system/bin/switch-to-configuration switch
set -euo pipefail

[ $# -le 1 ] || { echo "usage: sudo apply.sh [dir]" >&2; exit 2; }
HERE="$(cd "${1:-$(dirname "${BASH_SOURCE[0]}")}" && pwd)"
PAYLOAD="$HERE/wsl-delta.nar.tar.gz"
NEEDS="$HERE/wsl-needs.txt"
PROFILE=/nix/var/nix/profiles/system

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" -eq 0 ] || die "needs root: sudo $0"
for f in "$PAYLOAD" "$HERE/MANIFEST.txt"; do [ -f "$f" ] || die "missing $f"; done
SYSTEM="$(sed -n 's/^WSL_SYSTEM=//p' "$HERE/MANIFEST.txt")"
RELEASE="$(sed -n 's/^RELEASE=//p' "$HERE/MANIFEST.txt")"
[ -n "$SYSTEM" ] || die "MANIFEST.txt has no WSL_SYSTEM"

# The payload leaves out what outside knows this box holds. Check before
# importing: a path missing here would stop the import partway.
# update.sh does not fetch wsl-needs.txt; without it a missing path stops
# the import instead, before the switch.
missing=""
if [ -f "$NEEDS" ]; then
    missing="$(xargs -r nix-store --check-validity --print-invalid < "$NEEDS")"
else
    say "no wsl-needs.txt beside the payload; skipping the pre-check"
fi
if [ -n "$missing" ]; then
    printf '  missing: %s\n' $missing >&2
    die "this box lacks $(wc -w <<< "$missing") paths the release assumes. Nothing was changed; tell outside."
fi

say "importing $(du -h "$PAYLOAD" | cut -f1) payload"
tar -xzOf "$PAYLOAD" wsl-delta.nar | nix-store --import > /dev/null
nix-store --check-validity "$SYSTEM"

if [ "$(readlink -f /run/current-system)" = "$SYSTEM" ]; then
    say "already on $RELEASE"
else
    say "switching to $RELEASE"
    nix-env -p "$PROFILE" --set "$SYSTEM"
    "$SYSTEM/bin/switch-to-configuration" switch
fi

# Roots left by the import-only releases of November; the system profile
# holds everything now.
rm -rf /nix/var/nix/gcroots/twentyx-release
say "done: $RELEASE. New tools are on PATH in new shells."
