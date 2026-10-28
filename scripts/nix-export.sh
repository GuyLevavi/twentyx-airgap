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
OUT="dist/nix-transfer"
LIMIT=$((2400 * 1024 * 1024))   # stay under a 2.5GB single-file upload cap
# The store paths the far side already holds -- normally the store-paths file
# a previous export wrote next to its chunks. Set, the export ships only what
# is missing from it, and nix-import.sh resolves the rest from the local store.
SINCE_PATHS=""
while [ $# -gt 0 ]; do
    case "$1" in
        --limit)       LIMIT="${2:?}"; shift 2 ;;
        --since-paths) SINCE_PATHS="$(realpath "${2:?}")"; shift 2 ;;
        *)             OUT="$1"; shift ;;
    esac
done
[ -z "$SINCE_PATHS" ] || [ -s "$SINCE_PATHS" ] || { echo "empty or missing: $SINCE_PATHS" >&2; exit 1; }

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
    # nix/hosts/wsl.nix keys BOTH trusted-public-keys and require-sigs off this
    # file's existence, so writing it here is what arms verification on the far
    # side. It is gitignored: it is per-machine, and it must travel with the
    # transfer rather than with the repo.
    nix key convert-secret-to-public < "$KEY" > cache-pubkey
    echo "  signing with $KEY; public key -> cache-pubkey (transfer it too)"
else
    echo "  note: no signing key at $KEY -- the far side falls back to require-sigs = false." >&2
    echo "  generate one with: nix key generate-secret --key-name airgap-transfer > $KEY" >&2
    # Stale key from a previous signed export would make the far side demand
    # signatures that this unsigned transfer does not carry.
    rm -f cache-pubkey
fi

# Everything the far side must hold after this import. Written next to the
# chunks so the NEXT export can be a delta against it: keep a copy outside.
# shellcheck disable=SC2086
nix path-info -r "$TOPLEVEL" "$STDENV" $INPUTS | sort -u > "$OUT/store-paths"

if [ -n "$SINCE_PATHS" ]; then
    comm -13 <(sort -u "$SINCE_PATHS") "$OUT/store-paths" > "$OUT/.delta"
    say "delta: $(wc -l < "$OUT/.delta") of $(wc -l < "$OUT/store-paths") paths are new"
    # --no-recursive is what makes this a delta: nix copy otherwise ships each
    # path's whole closure, i.e. everything again. But a binary cache refuses
    # a path whose references it does not hold ("reference ... is not
    # valid"), and the references a delta omits are exactly the ones the far
    # side already has. So stand them in with narinfo-only stubs for the copy,
    # and take the stubs out before chunking. They are always in the local
    # store: they are part of the closure that was just built.
    xargs -r nix path-info --json < "$OUT/.delta" \
        | jq -r '.[].references[]' | sort -u | comm -23 - "$OUT/.delta" > "$OUT/.stubs"
    : > "$OUT/.stubfiles"
    xargs -r nix path-info --json < "$OUT/.stubs" | jq -r 'to_entries[] |
        "\(.key)\t\(.value.narHash)\t\(.value.narSize)\t\(.value.references | map(ltrimstr("/nix/store/")) | join(" "))"' |
    while IFS=$'\t' read -r p hash size refs; do
        b="$(basename "$p")"
        printf 'StorePath: %s\nURL: nar/stub.nar\nCompression: none\nNarHash: %s\nNarSize: %s\nReferences: %s\n' \
            "$p" "$hash" "$size" "$refs" > "$CACHE/${b%%-*}.narinfo"
        echo "${b%%-*}.narinfo" >> "$OUT/.stubfiles"
    done
    xargs -r nix copy --no-recursive --to "file://$PWD/$CACHE?compression=xz" "${SIGN[@]}" \
        < "$OUT/.delta"
    while read -r f; do rm -f "$CACHE/$f"; done < "$OUT/.stubfiles"
    say "  $(wc -l < "$OUT/.stubs") baseline reference(s) assumed present on the far side"
    rm -f "$OUT/.delta" "$OUT/.stubs" "$OUT/.stubfiles"
else
    # shellcheck disable=SC2086
    nix copy --to "file://$PWD/$CACHE?compression=xz" "${SIGN[@]}" \
        "$TOPLEVEL" "$STDENV" $INPUTS
fi
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
    echo "signed=$([ -f cache-pubkey ] && echo yes || echo no)"
    echo "delta=$([ -n "$SINCE_PATHS" ] && echo yes || echo no)"
} > "$OUT/TRANSFER"

# Travels with the chunks, not with the repo: without it the far side cannot
# verify a signed transfer, and nix-import.sh will say so rather than guess.
[ -f cache-pubkey ] && cp cache-pubkey "$OUT/cache-pubkey"

say "done"
ls -lh "$OUT"/*.tar.gz | awk '{printf "  %s  %s\n", $5, $9}'
echo
echo "  Transfer the .tar.gz files (any order) plus TRANSFER, then run"
echo "  scripts/nix-import.sh on the airgapped machine."
