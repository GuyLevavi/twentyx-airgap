#!/usr/bin/env bash
# Run OUTSIDE. Build the image layers Nix owns, ready for the transfer.
#
#   ./scripts/build-layers.sh [outdir]        default: dist
#
# Produces, with a .sha256 sidecar each so push-artifactory.sh can prove the
# physical transfer did not corrupt them:
#
#   nix-layer.tar.gz        the toolchain closure
#   nix-layer-nvim.tar.gz   the same plus LazyVim
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
NIX_PLAIN="$(nix build --no-link --print-out-paths .#runai-layer)"
NIX_NVIM="$(nix build --no-link --print-out-paths .#runai-layer-nvim)"

# Copied rather than symlinked: these leave the machine, and a store symlink
# does not survive a USB stick.
install -m 0644 "$NIX_PLAIN" "$OUT/nix-layer.tar.gz"
install -m 0644 "$NIX_NVIM"  "$OUT/nix-layer-nvim.tar.gz"

./docker/mklayer.sh "$OUT/repo-layer.tar" >/dev/null

say "checksums"
( cd "$OUT" && for f in nix-layer.tar.gz nix-layer-nvim.tar.gz repo-layer.tar; do
    # Bare filename, not a path: the sidecar travels WITH the file and must
    # verify from whatever directory it lands in on the other side.
    sha256sum "$f" > "$f.sha256"
done )

say "done"
for f in "$OUT"/nix-layer.tar.gz "$OUT"/nix-layer-nvim.tar.gz "$OUT"/repo-layer.tar; do
    printf '  %-8s %s\n' "$(du -h "$f" | cut -f1)" "$f"
done
cat <<EOF

  Carry these in, then inside the gap:
    ./scripts/push-artifactory.sh $OUT/nix-layer.tar.gz $OUT/nix-layer-nvim.tar.gz
  CI tars this checkout as repo-layer.tar and runs docker/assemble.sh from there.
EOF
