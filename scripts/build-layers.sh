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

# The layer is built in the persistent chroot store when it exists: a NEW
# closure's drv files are never in the default store until it is built there
# (the NOTES.md §9 repair class), while the chroot holds every closure this
# repo ever evaluated -- it is the donor, and the fallback too.
CHROOT=/tmp/airgap-test-store
if [ -d "$CHROOT/nix/store" ]; then
    STORE=("--store" "$CHROOT")
    PREFIX="$CHROOT"
else
    STORE=()
    PREFIX=""
fi

NIX_PLAIN="$(nix build "${STORE[@]}" --no-link --print-out-paths .#runai-layer)"
NIX_NVIM="$(nix build "${STORE[@]}" --no-link --print-out-paths .#runai-layer-nvim)"

# Copied rather than symlinked: these leave the machine, and a store symlink
# does not survive a USB stick.
install -m 0644 "$PREFIX$NIX_PLAIN" "$OUT/nix-layer.tar.gz"
install -m 0644 "$PREFIX$NIX_NVIM"  "$OUT/nix-layer-nvim.tar.gz"

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
