#!/usr/bin/env bash
# Run OUTSIDE. Produce everything the airgapped side needs, as a Nix binary
# cache split into transferable chunks.
#
#   ./scripts/nix-export.sh [outdir] [--limit BYTES]
#
# This replaces vendor/manifest.toml. There is no list of blobs to maintain,
# because Nix computes the closure: whatever the config references is what gets
# exported, and nothing else.
#
# Why a binary cache rather than a tarball of /nix/store: it is content
# addressed. Chunks can be transferred in any order, reassembled on the far
# side, and Nix reconciles purely by store hash -- so a chunked transfer has no
# ordering requirement and no partial-state corruption mode.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="${1:-dist/nix-transfer}"
LIMIT=$((2400 * 1024 * 1024))   # stay under a 2.5GB single-file upload cap
[ "${2:-}" = "--limit" ] && LIMIT="$3"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

CACHE="${AIRGAP_REUSE_CACHE:-$OUT/cache}"
if [ -n "${AIRGAP_REUSE_CACHE:-}" ]; then
    # Re-chunk an existing cache without redoing the xz pass. The real use
    # case: the chunks did not fit the upload cap and need splitting smaller,
    # which should not cost another twenty minutes of compression.
    mkdir -p "$OUT"
else
    rm -rf "$OUT"; mkdir -p "$CACHE"
fi

# ── roots ─────────────────────────────────────────────────────────────────
if [ -n "${AIRGAP_REUSE_CACHE:-}" ]; then
  say "reusing cache at $CACHE (skipping build and export)"
else
say "building"
TOPLEVEL="$(nix build --no-link --print-out-paths \
    .#nixosConfigurations.wsl.config.system.build.toplevel)"

# The flake's own inputs. Without these in the store, `nixos-rebuild` inside
# the airgap cannot even EVALUATE -- it is not enough to ship the built system.
INPUTS="$(nix flake archive --json | jq -r '.. | .path? // empty' | sort -u)"

# stdenvNoCC is a BUILD-time dependency, so it is absent from the runtime
# closure of the system above. It is also exactly what a config-only rebuild
# needs: writeText / writeShellScript / buildEnv / symlinkJoin all build on it,
# from string literals, with no fetches. Ship it and config edits rebuild
# offline in seconds; omit it and the first edit inside the gap fails with
# "cannot build, no substituter".
STDENV="$(nix build --no-link --print-out-paths \
    --expr 'with import <nixpkgs> {}; stdenvNoCC' --impure 2>/dev/null || true)"
[ -z "$STDENV" ] && STDENV="$(nix build --no-link --print-out-paths --impure --expr \
    "(import (builtins.getFlake (toString ./.)).inputs.nixpkgs {}).stdenvNoCC")"

say "exporting closure to a signed binary cache"
KEY="${AIRGAP_SIGN_KEY:-$HOME/.config/airgap/cache-priv.key}"
SIGN=()
if [ -f "$KEY" ]; then
    SIGN=(--secret-key "$KEY")
else
    echo "  note: no signing key at $KEY -- the far side must set require-sigs = false." >&2
    echo "  generate one with: nix key generate-secret --key-name airgap-transfer > $KEY" >&2
fi

# shellcheck disable=SC2086
nix copy --to "file://$PWD/$CACHE?compression=xz" "${SIGN[@]}" \
    "$TOPLEVEL" "$STDENV" $INPUTS
fi

# ── chunk ─────────────────────────────────────────────────────────────────
# Whole files per chunk, so every chunk is a valid tar. Reassembly is
# "extract them all into one directory", in any order.
say "chunking to $((LIMIT / 1024 / 1024)) MB"
( cd "$CACHE" && find . -type f -printf '%s\t%p\n' ) | sort -k2 > "$OUT/.files"
n=1; acc=0; : > "$OUT/.chunk"
while IFS=$'\t' read -r size path; do
    if [ $((acc + size)) -gt "$LIMIT" ] && [ "$acc" -gt 0 ]; then
        tar -C "$CACHE" -czf "$OUT/nix-transfer-$(printf '%02d' $n).tar.gz" -T "$OUT/.chunk"
        n=$((n + 1)); acc=0; : > "$OUT/.chunk"
    fi
    printf '%s\n' "$path" >> "$OUT/.chunk"; acc=$((acc + size))
done < "$OUT/.files"
[ -s "$OUT/.chunk" ] && \
    tar -C "$CACHE" -czf "$OUT/nix-transfer-$(printf '%02d' $n).tar.gz" -T "$OUT/.chunk"
rm -f "$OUT/.files" "$OUT/.chunk"

# In reuse mode nothing was built, so recover the system path from the cache
# itself rather than writing an empty TRANSFER -- which would silently degrade
# the import side to `nix copy --all` with no activation instructions.
if [ -z "${TOPLEVEL:-}" ]; then
    TOPLEVEL="$(grep -lh . "$CACHE"/*.narinfo 2>/dev/null | xargs -r grep -h '^StorePath:' \
        | awk '{print $2}' | grep -m1 -- '-nixos-system-' || true)"
    [ -n "$TOPLEVEL" ] && say "recovered toplevel from cache: $TOPLEVEL"
fi

{
    echo "toplevel=${TOPLEVEL:-}"
    echo "stdenv=${STDENV:-}"
    echo "generated=$(date -u +%FT%TZ)"
} > "$OUT/TRANSFER"

say "done"
ls -lh "$OUT"/*.tar.gz | awk '{printf "  %s  %s\n", $5, $9}'
echo
echo "  Transfer the .tar.gz files (any order) plus TRANSFER, then run"
echo "  scripts/nix-import.sh on the airgapped machine."
