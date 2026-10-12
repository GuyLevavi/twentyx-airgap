#!/usr/bin/env bash
# Run OUTSIDE. Build the image layers Nix owns, ready for the transfer.
#
#   ./scripts/build-layers.sh [--full|--delta] [outdir]     default: --full dist
#
# Produces:
#
#   --full    nix-layer.tar.gz        the whole toolchain closure ("base")
#             nix-layer-nvim.tar.gz   the same plus nvim
#   --delta   nix-layer-delta.tar.gz  base's new store paths + the opt/ tree
#             nix-layer-delta-nvim.tar.gz
#   both      repo-layer.tar          libexec + agent helpers (also built by CI)
#
# A delta is cumulative against the base layer beside it: everything in the
# current closure the base does not have. Store paths are immutable and image
# layers are additive, so appending the delta on top of the base upgrades the
# image; the delta is valid exactly for the base it was built against, so keep
# the base beside it. Rebuild the base (with --full) at a VERSION bump, when
# the delta has outgrown it, or when a nixpkgs bump moves everything.
#
# There is no node layer: opencode comes from the Nix closure, so nothing
# needs npm against a registry any more.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
MODE="--full"
case "${1:-}" in
    --full | --delta)
        MODE="$1"
        shift
        ;;
esac
OUT="${1:-dist}"
mkdir -p "$OUT"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

LAYERS=(nix-layer.tar.gz nix-layer-nvim.tar.gz)
DELTAS=(nix-layer-delta.tar.gz nix-layer-delta-nvim.tar.gz)

if [ "$MODE" = --full ]; then
    say "building the base layers (whole closure)"
    readarray -t PATHS < <(nix build --no-link --print-out-paths .#runai-layer .#runai-layer-nvim)
    install -m 0644 "${PATHS[0]}" "$OUT/${LAYERS[0]}"
    install -m 0644 "${PATHS[1]}" "$OUT/${LAYERS[1]}"
    rm -f "$OUT/${DELTAS[0]}" "$OUT/${DELTAS[1]}"
else
    say "building the delta layers"
    readarray -t OPTS < <(nix build --no-link --print-out-paths .#runai-layer-opt .#runai-layer-opt-nvim)
    TMP="$(mktemp -d)"
    trap 'rm -rf "$TMP"' EXIT

    for i in 0 1; do
        base="$OUT/${LAYERS[$i]}"
        delta="$OUT/${DELTAS[$i]}"
        opt="${OPTS[$i]}"
        [ -f "$base" ] || die "missing base $base -- run --full first (a delta is only valid against its base)"
        tar -xzOf "$base" opt/twentyx/store-paths | sort > "$TMP/old" \
            || die "$base has no opt/twentyx/store-paths -- not a full layer?"
        sort "$opt/opt/twentyx/store-paths" > "$TMP/new"
        comm -13 "$TMP/old" "$TMP/new" > "$TMP/changed"
        # Every path the new closure needs is either in the base or in the
        # delta; a silent miss would break the image's interpreters at exec.
        # (Capture first: grep -q closing the pipe early is SIGPIPE + pipefail.)
        leftover="$(comm -23 "$TMP/new" <(sort -u "$TMP/old" "$TMP/changed") || true)"
        [ -z "$leftover" ] || die "delta does not cover the new closure ($base)"

        # Same flags as layer.nix, same member order (opt first): the delta
        # must overlay the base identically to a freshly built full layer.
        sed 's|^/||' "$TMP/changed" > "$TMP/changed-rel"
        tar --owner=0 --group=0 --mode='g=u' \
            --sort=name --mtime='@1' \
            -C "$opt" -cf "$TMP/layer.tar" opt
        tar --owner=0 --group=0 --sort=name --mtime='@1' \
            -rf "$TMP/layer.tar" -C / -T "$TMP/changed-rel"
        gzip -n -6 < "$TMP/layer.tar" > "$delta"
        printf '  %-8s %s paths new, %s\n' \
            "$(du -h "$delta" | cut -f1)" "$(wc -l < "$TMP/changed")" "$delta"
    done
fi

# The repo layer stays the same in both modes: text, rebuilt on every run.
LAYER_NIX="$OUT/${LAYERS[0]}" LAYER_NIX_DELTA="$OUT/${DELTAS[0]}" \
    ./docker/mklayer.sh "$OUT/repo-layer.tar" >/dev/null

say "done"
for f in "$OUT/${LAYERS[0]}" "$OUT/${LAYERS[1]}" "$OUT/${DELTAS[0]}" "$OUT/${DELTAS[1]}" "$OUT/repo-layer.tar"; do
    [ -f "$f" ] || continue
    printf '  %-8s %s\n' "$(du -h "$f" | cut -f1)" "$f"
done
if [ "$MODE" = --full ]; then
    cat <<EOF

  Carry these in, then inside the gap:
    ./scripts/push-artifactory.sh $OUT/nix-layer.tar.gz $OUT/nix-layer-nvim.tar.gz
  CI tars this checkout as repo-layer.tar and runs docker/assemble.sh from there.
EOF
fi
