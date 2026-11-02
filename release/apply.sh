#!/usr/bin/env bash
# WSL updater for twentyx release @RELEASE@ (delta on @BASE_RELEASE@).
# Run inside the gap, from anywhere; it finds wsl-delta.nar.tar.gz beside itself.
#
#   sudo ./apply.sh                 import, then switch to this release's system
#   sudo ./apply.sh --import-only   import only, e.g. to rebuild from the inner flake
#
# Safe to rerun: paths already in the store are skipped.
set -euo pipefail

RELEASE="@RELEASE@"
TOPLEVEL="@TOPLEVEL@"
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PAYLOAD="$HERE/wsl-delta.nar.tar.gz"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

IMPORT_ONLY=""
case "${1:-}" in
    "")            ;;
    --import-only) IMPORT_ONLY=1 ;;
    *) echo "usage: apply.sh [--import-only]" >&2; exit 2 ;;
esac

[ -f "$PAYLOAD" ] || { echo "missing $PAYLOAD" >&2; exit 1; }

# The delta omits everything the base release already holds, and importing a
# path whose references are absent stops partway through. Find out first.
say "checking the store against what this delta builds on"
invalid="$(xargs nix-store --check-validity --print-invalid <<'REFS'
@BASE_REFS@
REFS
)"
if [ -n "$invalid" ]; then
    printf '  missing: %s\n' $invalid >&2
    echo "error: this machine is not at the base release this delta was cut for." >&2
    echo "Nothing was imported. See HANDOVER.md." >&2
    exit 1
fi

say "importing $(du -h "$PAYLOAD" | cut -f1) payload"
tar -xzOf "$PAYLOAD" wsl-delta.nar | nix-store --import > /dev/null
nix-store --check-validity "$TOPLEVEL"

if [ -n "$IMPORT_ONLY" ]; then
    say "imported $RELEASE; system not switched"
    echo "  to activate this exact build: sudo $0"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "activation needs root: sudo $0" >&2; exit 1; }
say "switching to $RELEASE"
nix-env -p /nix/var/nix/profiles/system --set "$TOPLEVEL"
"$TOPLEVEL/bin/switch-to-configuration" switch
say "done: $RELEASE"
