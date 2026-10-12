#!/usr/bin/env bash
# Pack a pod store layer: the /opt/twentyx tree first, then store paths.
#
#   scripts/pod-tar.sh <pod-opt> <paths-file> <out.tar.gz>
#
# <pod-opt> is a built .#pod-opt; <paths-file> lists absolute store paths,
# one per line -- the whole closure for a full layer, the closure minus the
# base's for a delta. The opt/ tree is always included, so the topmost store
# layer's profile link, session-env, store-paths and sudo win.
#
# Deterministic: identical inputs give a byte-identical blob, or every rebuild
# uploads a new layer. opt/ goes first so `tar --occurrence=1` reads
# session-env without streaming the store. The sudo member is written 4555:
# Nix strips setuid bits from outputs, but a tar header mode is data. 4555,
# not 4755: --mode='g=u' on the rest would otherwise make a setuid binary
# group-writable for every gid-0 process.
set -euo pipefail

OPT="${1:?usage: pod-tar.sh <pod-opt> <paths-file> <out.tar.gz>}"
PATHS="${2:?usage: pod-tar.sh <pod-opt> <paths-file> <out.tar.gz>}"
OUT="${3:?usage: pod-tar.sh <pod-opt> <paths-file> <out.tar.gz>}"

TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
TAR=(tar --owner=0 --group=0 --sort=name --mtime=@1)

"${TAR[@]}" --mode='g=u' --exclude=opt/twentyx/bin/sudo \
    -C "$OPT" -cf "$TMP/layer.tar" opt
if [ -e "$OPT/opt/twentyx/bin/sudo" ]; then
    "${TAR[@]}" --mode=4555 -C "$OPT" -rf "$TMP/layer.tar" opt/twentyx/bin/sudo
fi
# -T, never argv: a full closure is thousands of paths.
sed 's|^/||' "$PATHS" > "$TMP/paths"
if [ -s "$TMP/paths" ]; then
    "${TAR[@]}" -C / -rf "$TMP/layer.tar" -T "$TMP/paths"
fi
gzip -n -6 < "$TMP/layer.tar" > "$OUT"
