#!/usr/bin/env bash
# Run OUTSIDE. Build the image layers Nix owns, ready for the transfer.
#
#   ./scripts/build-layers.sh [outdir]                    default: dist
#   ./scripts/build-layers.sh [outdir] --since <prevdir>  delta layer
#
# Produces, with a .sha256 sidecar each so push-artifactory.sh can prove the
# physical transfer did not corrupt them:
#
#   nix-layer-nvim.tar.gz   the toolchain closure, LazyVim included
#                           (the one flavor; the name predates that)
#   repo-layer.tar          the dispatcher and scripts (also built by CI)
#
# With --since, <prevdir> holds the nix-layer-nvim.tar.gz already inside the
# gap, and the nix layer becomes nix-layer-nvim-delta.tar.gz instead: only the
# store paths that one does not carry, plus a complete /opt/airgap. CI appends
# it on top of the previous layer (see docker/assemble.sh), so the previous
# one must stay in Artifactory.
#
# The node layer is NOT built here: it needs npm against internal Artifactory,
# so it is built inside the gap by docker/Containerfile.node.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="dist"
SINCE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --since) SINCE="${2:?--since needs the directory of the previous layers}"; shift 2 ;;
        *)       OUT="$1"; shift ;;
    esac
done
mkdir -p "$OUT"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

# build <flake package> [base layer tarball] -> store path of the layer
build() {
    local pkg="$1" base="${2:-}"
    if [ -z "$base" ]; then
        nix build --no-link --print-out-paths ".#$pkg"
        return
    fi
    # The base layer recorded its own closure at opt/airgap/store-paths, which
    # is the exact set the far side has: no need to rebuild, or even still
    # have, whatever produced it.
    local paths
    paths="$(mktemp)"
    tar -xzOf "$base" --occurrence=1 opt/airgap/store-paths > "$paths" \
        || { echo "no opt/airgap/store-paths in $base" >&2; rm -f "$paths"; return 1; }
    nix build --no-link --print-out-paths --impure --expr "
        (builtins.getFlake (toString ./.)).packages.\${builtins.currentSystem}.$pkg.override {
          basePaths = builtins.path { path = $paths; name = \"base-store-paths\"; };
        }"
    rm -f "$paths"
}

if [ -n "$SINCE" ]; then
    NAME=nix-layer-nvim-delta.tar.gz
    BASE="$SINCE/nix-layer-nvim.tar.gz"
    [ -f "$BASE" ] || { echo "missing previous layer: $BASE" >&2; exit 1; }
    say "building delta against $BASE"
    NIX="$(build runai-layer-nvim "$(realpath "$BASE")")"
else
    NAME=nix-layer-nvim.tar.gz
    say "building"
    NIX="$(build runai-layer-nvim)"
fi

# Copied rather than symlinked: these leave the machine, and a store symlink
# does not survive a USB stick.
install -m 0644 "$NIX" "$OUT/$NAME"

./docker/mklayer.sh "$OUT/repo-layer.tar" >/dev/null

say "checksums"
( cd "$OUT" && for f in "$NAME" repo-layer.tar; do
    # Bare filename, not a path: the sidecar travels WITH the file and must
    # verify from whatever directory it lands in on the other side.
    sha256sum "$f" > "$f.sha256"
done )

say "done"
for f in "$OUT/$NAME" "$OUT"/repo-layer.tar; do
    printf '  %-8s %s\n' "$(du -h "$f" | cut -f1)" "$f"
done
cat <<EOF

  Carry these in, then inside the gap:
    ./scripts/push-artifactory.sh $OUT/$NAME
  CI builds the node layer and runs docker/assemble.sh from there.
EOF
