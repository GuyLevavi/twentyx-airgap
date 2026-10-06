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

readarray -t LAYERS < <(nix build --no-link --print-out-paths .#runai-layer .#runai-layer-nvim)
install -m 0644 "${LAYERS[0]}" "$OUT/nix-layer.tar.gz"
install -m 0644 "${LAYERS[1]}" "$OUT/nix-layer-nvim.tar.gz"

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
