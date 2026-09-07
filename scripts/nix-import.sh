#!/usr/bin/env bash
# Run INSIDE the airgap, on the NixOS-WSL machine.
#
#   sudo ./scripts/nix-import.sh /path/to/transfer-dir
#
# Extracts every chunk into one cache directory and imports it. Chunks may
# arrive in any order and may be imported repeatedly: the cache is content
# addressed, so re-importing is a no-op rather than a conflict.
set -euo pipefail

SRC="${1:?usage: nix-import.sh <dir containing nix-transfer-*.tar.gz>}"
DEST="${AIRGAP_CACHE_DIR:-/var/cache/nix-transfer}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

mkdir -p "$DEST"
shopt -s nullglob
chunks=("$SRC"/nix-transfer-*.tar.gz)
[ ${#chunks[@]} -gt 0 ] || { echo "no chunks found in $SRC" >&2; exit 1; }

say "extracting ${#chunks[@]} chunk(s)"
for c in "${chunks[@]}"; do
    printf '  %s\n' "$(basename "$c")"
    tar -C "$DEST" -xzf "$c"
done

[ -f "$DEST/nix-cache-info" ] || {
    echo "error: $DEST has no nix-cache-info -- the transfer is incomplete." >&2
    echo "All chunks must be extracted before importing." >&2
    exit 1
}

TOPLEVEL="$(sed -n 's/^toplevel=//p' "$SRC/TRANSFER" 2>/dev/null || true)"

say "importing into the local store"
# --no-check-sigs is correct only for an UNSIGNED cache. If the export was
# signed, drop it and put the public key in nix.settings.trusted-public-keys
# instead -- that is what makes the transfer tamper-evident.
if [ -n "$TOPLEVEL" ]; then
    nix copy --from "file://$DEST" --no-check-sigs "$TOPLEVEL"
    echo
    echo "  Imported. Activate with:"
    echo "    sudo nix-env -p /nix/var/nix/profiles/system --set $TOPLEVEL"
    echo "    sudo $TOPLEVEL/bin/switch-to-configuration switch"
    echo
    echo "  After that, config-only edits rebuild offline:"
    echo "    sudo nixos-rebuild switch --flake /etc/nixos#wsl"
else
    nix copy --from "file://$DEST" --no-check-sigs --all
fi
