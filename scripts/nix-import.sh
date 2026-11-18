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

# DEST accumulates across transfers, so remember which narinfos are THIS one's:
# a delta is imported path by path, and only its own paths.
NARINFOS="$(mktemp)"
trap 'rm -f "$NARINFOS"' EXIT

say "extracting ${#chunks[@]} chunk(s)"
for c in "${chunks[@]}"; do
    printf '  %s\n' "$(basename "$c")"
    tar -C "$DEST" -xzf "$c"
    tar -tzf "$c" | grep '\.narinfo$' >> "$NARINFOS" || true
done

[ -f "$DEST/nix-cache-info" ] || {
    echo "error: $DEST has no nix-cache-info -- the transfer is incomplete." >&2
    echo "All chunks must be extracted before importing." >&2
    exit 1
}

TOPLEVEL="$(sed -n 's/^toplevel=//p' "$SRC/TRANSFER" 2>/dev/null || true)"

# A delta ships only the paths the far side lacked when it was cut, and
# relies on this store for every other reference. If this machine is not
# the baseline the delta was computed against, say which paths are missing
# now, rather than let `nix copy` fail halfway through with one of them.
if grep -qx 'delta=yes' "$SRC/TRANSFER" 2>/dev/null; then
    say "checking the delta's references against the local store"
    missing=0
    while read -r ref; do
        [ -f "$DEST/${ref%%-*}.narinfo" ] && continue
        [ -e "/nix/store/$ref" ] && continue
        echo "  missing: /nix/store/$ref" >&2
        missing=$((missing + 1))
    done < <(cd "$DEST" && xargs sed -n 's/^References: //p' < "$NARINFOS" | tr ' ' '\n' | grep . | sort -u)
    if [ "$missing" -gt 0 ]; then
        echo "error: $missing referenced path(s) are neither in the transfer nor in this store." >&2
        echo "This delta was cut against a different baseline; ask for a full export." >&2
        exit 1
    fi
fi

# Transfers are unsigned. Corruption is still caught, per store path rather
# than per tarball: Nix checks every NAR against the hash in its narinfo, so a
# chunk that arrived damaged fails on the path it damaged.
VERIFY=(--no-check-sigs)

say "importing into the local store"
if grep -qx 'delta=yes' "$SRC/TRANSFER" 2>/dev/null; then
    # Not `nix copy $TOPLEVEL`: that walks the closure through the cache, and
    # stops at the first reference the delta deliberately left out ("path ...
    # is not valid") even though this store has it. Copying just this
    # transfer's paths, non-recursively, lets Nix order them itself and find
    # every other reference already valid here.
    # shellcheck disable=SC2046 # one store path per word
    nix copy --no-recursive --from "file://$DEST" "${VERIFY[@]}" \
        $(cd "$DEST" && xargs sed -n 's/^StorePath: //p' < "$NARINFOS")
elif [ -n "$TOPLEVEL" ]; then
    nix copy --from "file://$DEST" "${VERIFY[@]}" "$TOPLEVEL"
else
    nix copy --from "file://$DEST" "${VERIFY[@]}" --all
fi

if [ -n "$TOPLEVEL" ]; then
    [ -e "$TOPLEVEL" ] || { echo "error: $TOPLEVEL is still not in the store after import" >&2; exit 1; }
    echo
    echo "  Imported. Activate with:"
    echo "    sudo nix-env -p /nix/var/nix/profiles/system --set $TOPLEVEL"
    echo "    sudo $TOPLEVEL/bin/switch-to-configuration switch"
    echo
    echo "  After that, config-only edits rebuild offline:"
    echo "    sudo nixos-rebuild switch --flake /etc/nixos#wsl"
fi
