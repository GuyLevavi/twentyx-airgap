#!/usr/bin/env bash
# WSL updater for twentyx release @RELEASE@ (delta on @BASE_RELEASE@).
# Run inside the gap, from anywhere; it finds wsl-delta.nar.tar.gz beside itself.
#
#   sudo ./apply.sh
#
# Puts this release's packages, and the tools to rebuild with, into the store.
# It does not switch: the running system is inner's own build, so that is
# `nixos-rebuild` from the inner flake, after the edits in HANDOVER.md.
#
# The payload is closed under references, so it imports whatever the store
# already holds. Safe to rerun: paths already in the store are skipped.
set -euo pipefail

RELEASE="@RELEASE@"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$HERE/wsl-delta.nar.tar.gz"
ROOTS="/nix/var/nix/gcroots/twentyx-release"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ $# -eq 0 ] || { echo "usage: sudo apply.sh" >&2; exit 2; }
[ "$(id -u)" -eq 0 ] || { echo "needs root: sudo $0" >&2; exit 1; }
[ -f "$PAYLOAD" ] || { echo "missing $PAYLOAD" >&2; exit 1; }

IMPORTED="$(mktemp)"
trap 'rm -f "$IMPORTED"' EXIT

say "importing $(du -h "$PAYLOAD" | cut -f1) payload"
tar -xzOf "$PAYLOAD" wsl-delta.nar | nix-store --import > "$IMPORTED"

# Nothing refers to these until the rebuild, and the build tools never get a
# referrer at all: without roots, the next GC undoes this import.
rm -rf "$ROOTS"
mkdir -p "$ROOTS"
while read -r path; do
    ln -s "$path" "$ROOTS/${path##*/}"
done < "$IMPORTED"

say "imported $RELEASE: $(wc -l < "$IMPORTED") paths, rooted at $ROOTS"
echo "  next: port the edits in HANDOVER.md, then nixos-rebuild from the inner flake"
