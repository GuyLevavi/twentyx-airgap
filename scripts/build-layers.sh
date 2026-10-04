#!/usr/bin/env bash
# Run OUTSIDE. Build the image layers Nix owns, ready for the transfer.
#
#   ./scripts/build-layers.sh [outdir]        default: dist
#
# Produces:
#
#   nix-layer.tar.gz        the toolchain closure
#   nix-layer-nvim.tar.gz   the same plus nvim
#   repo-layer.tar          libexec + agent helpers (also built by CI)
#
# There is no node layer: opencode comes from the Nix closure, so nothing
# needs npm against a registry any more.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="${1:-dist}"
mkdir -p "$OUT"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

say "building"

# Default store first: after any local build the layer is already there, so a
# transfer run starts in seconds. The persistent chroot store is the fallback
# for a store that lost paths (NOTES.md §9) -- a build there pays for the
# closure, which is exactly the ten-minute silence this avoids.
CHROOT=/tmp/airgap-test-store
build_layer() {
    local attr="$1" out
    if out="$(nix build --no-link --print-out-paths "$attr" 2>/dev/null)"; then
        printf '%s\n' "$out"
    elif [ -d "$CHROOT/nix/store" ]; then
        out="$(nix build --store "$CHROOT" --no-link --print-out-paths "$attr")"
        printf '%s\n' "$CHROOT$out"
    else
        nix build --no-link --print-out-paths "$attr"
    fi
}

NIX_PLAIN="$(build_layer .#runai-layer)"
NIX_NVIM="$(build_layer .#runai-layer-nvim)"

install -m 0644 "$NIX_PLAIN" "$OUT/nix-layer.tar.gz"
install -m 0644 "$NIX_NVIM"  "$OUT/nix-layer-nvim.tar.gz"

./docker/mklayer.sh "$OUT/repo-layer.tar" >/dev/null

say "done"
for f in "$OUT"/nix-layer.tar.gz "$OUT"/nix-layer-nvim.tar.gz "$OUT"/repo-layer.tar; do
    printf '  %-8s %s\n' "$(du -h "$f" | cut -f1)" "$f"
done
cat <<EOF

  Carry these in, then inside the gap:
    ./scripts/push-artifactory.sh $OUT/nix-layer.tar.gz $OUT/nix-layer-nvim.tar.gz
  CI tars this checkout as repo-layer.tar and runs docker/assemble.sh from there.
EOF
