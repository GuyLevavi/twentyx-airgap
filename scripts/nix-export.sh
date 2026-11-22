#!/usr/bin/env bash
# Run OUTSIDE. Produce everything the airgapped side needs, as a Nix binary
# cache split into transferable chunks.
#
#   ./scripts/nix-export.sh [outdir] [--limit BYTES] [--since-paths FILE] [--cache DIR]
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
# A binary cache kept across runs. Compression is nearly all of an export's
# time (xz, about 1.5 h for a delta of a few hundred paths), and nix copy skips
# any path the cache already holds -- so with --cache a rebuild after a small
# change compresses only the paths that changed. Entries this export does not
# ship are pruned first, so a persistent cache never leaks stale paths into
# the chunks.
PERSIST=""
while [ $# -gt 0 ]; do
    case "$1" in
        --limit)       LIMIT="${2:?}"; shift 2 ;;
        --since-paths) SINCE_PATHS="$(realpath "${2:?}")"; shift 2 ;;
        --cache)       PERSIST="$(realpath -m --relative-to=. "${2:?}")"; shift 2 ;;
        *)             OUT="$1"; shift ;;
    esac
done
[ -z "$SINCE_PATHS" ] || [ -s "$SINCE_PATHS" ] || { echo "empty or missing: $SINCE_PATHS" >&2; exit 1; }

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

hashes() { sed 's|^/nix/store/||; s|-.*||' "$@" | sort -u; }

# Drop every narinfo that is not in the list of paths to ship ($1), or that is
# a stub left by an interrupted delta run, then every nar no narinfo names.
prune_cache() {
    local want="$1" n o
    o="$(realpath "$OUT")"   # the subshells below cd into the cache
    hashes "$want" > "$o/.want"
    { ( cd "$CACHE" && find . -maxdepth 1 -name '*.narinfo' -printf '%f\n' ) \
        | sed 's/\.narinfo$//' | sort | comm -23 - "$o/.want"
      ( cd "$CACHE" && find . -maxdepth 1 -name '*.narinfo' -exec grep -l '^URL: nar/stub.nar' {} + || true ) | sed 's|^\./||; s/\.narinfo$//'
    } | sort -u | sed 's/$/.narinfo/' > "$o/.drop"
    n="$(wc -l < "$o/.drop")"
    ( cd "$CACHE" && xargs -r rm -f < "$o/.drop" )
    ( cd "$CACHE" && find . -maxdepth 1 -name '*.narinfo' -exec sed -n 's/^URL: //p' {} + | sort -u ) > "$o/.nars"
    mkdir -p "$CACHE/nar"
    ( cd "$CACHE" && find nar -type f | sort | comm -23 - "$o/.nars" | xargs -r rm -f )
    say "  cache: $(comm -12 <(( cd "$CACHE" && find . -maxdepth 1 -name '*.narinfo' -printf '%f\n' ) | sed 's/\.narinfo$//' | sort) "$o/.want" | wc -l) of $(wc -l < "$o/.want") paths already compressed, $n stale entries dropped"
    rm -f "$o/.drop" "$o/.nars"
}

# Every path to ship must now have a real narinfo and its nar. With a
# persistent cache this is what proves the reuse was sound.
verify_cache() {
    local h missing=0
    while read -r h; do
        if [ ! -f "$CACHE/$h.narinfo" ] || grep -q '^URL: nar/stub.nar' "$CACHE/$h.narinfo" \
            || [ ! -f "$CACHE/$(sed -n 's/^URL: //p' "$CACHE/$h.narinfo")" ]; then
            echo "  missing from the cache: $h" >&2; missing=1
        fi
    done < "$OUT/.want"
    rm -f "$OUT/.want"
    [ "$missing" -eq 0 ] || { echo "export incomplete; rerun" >&2; exit 1; }
}

CACHE="${AIRGAP_REUSE_CACHE:-${PERSIST:-$OUT/cache}}"
if [ -n "$PERSIST" ] && [ -z "${AIRGAP_REUSE_CACHE:-}" ]; then
    rm -rf "$OUT"; mkdir -p "$OUT" "$CACHE"
elif [ -n "${AIRGAP_REUSE_CACHE:-}" ]; then
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

say "exporting closure to a binary cache"

# Everything the far side must hold after this import. Written next to the
# chunks so the NEXT export can be a delta against it: keep a copy outside.
# shellcheck disable=SC2086
nix path-info -r "$TOPLEVEL" "$STDENV" $INPUTS | sort -u > "$OUT/store-paths"

if [ -n "$SINCE_PATHS" ]; then
    comm -13 <(sort -u "$SINCE_PATHS") "$OUT/store-paths" > "$OUT/.delta"
    say "delta: $(wc -l < "$OUT/.delta") of $(wc -l < "$OUT/store-paths") paths are new"
    prune_cache "$OUT/.delta"
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
    xargs -r nix copy --no-recursive --to "file://$PWD/$CACHE?compression=xz" \
        < "$OUT/.delta"
    while read -r f; do rm -f "$CACHE/$f"; done < "$OUT/.stubfiles"
    say "  $(wc -l < "$OUT/.stubs") baseline reference(s) assumed present on the far side"
    verify_cache
    rm -f "$OUT/.delta" "$OUT/.stubs" "$OUT/.stubfiles"
else
    prune_cache "$OUT/store-paths"
    # shellcheck disable=SC2086
    nix copy --to "file://$PWD/$CACHE?compression=xz" \
        "$TOPLEVEL" "$STDENV" $INPUTS
    verify_cache
fi
fi

# ── chunk ─────────────────────────────────────────────────────────────────
# Whole files per chunk, so every chunk is a valid tar. Reassembly is
# "extract them all into one directory", in any order.
say "chunking to $((LIMIT / 1024 / 1024)) MB"
( cd "$CACHE" && find . -type f ! -name '.*' -printf '%s\t%p\n' ) | sort -k2 > "$OUT/.files"
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
    echo "delta=$([ -n "$SINCE_PATHS" ] && echo yes || echo no)"
} > "$OUT/TRANSFER"

say "done"
ls -lh "$OUT"/*.tar.gz | awk '{printf "  %s  %s\n", $5, $9}'
echo
echo "  Transfer the .tar.gz files (any order) plus TRANSFER, then run"
echo "  scripts/nix-import.sh on the airgapped machine."
