#!/usr/bin/env bash
# Run OUTSIDE. Turn a release folder into the form that crosses the gap.
#
#   ./scripts/shard-release.sh SRC_DIR OUT_DIR [PART_BYTES]
#
# The transfer may drop a big file whatever its type, .tar.gz and .7z alike.
# So every file over 1 MiB becomes base64 text in parts of PART_BYTES
# (default 20 MiB), named <file>.part0, .part1, ... part0 is shipped twice,
# also as <file>.part00, because a first part is the one most often lost.
# Smaller files are copied as they are.
#
# OUT_DIR also gets:
#   PARTS.txt      <file> <part count> <sha256 of the file>, one per sharded file
#   PARTS.sha256   sha256 of every part
#   PLAIN.sha256   sha256 of every file copied as is
#   SHA256SUMS     sha256 of the four files above and reassemble.sh
#   reassemble.sh  from release/reassemble.sh: checks every part, rebuilds
set -euo pipefail

[ $# -ge 2 ] || { echo "usage: shard-release.sh SRC_DIR OUT_DIR [PART_BYTES]" >&2; exit 2; }
repo="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
src="$(realpath "$1")" out="$2" size="${3:-20971520}"

rm -rf "$out"
mkdir -p "$out"
out="$(realpath "$out")"
: > "$out/PARTS.txt"
: > "$out/PLAIN.sha256"

cd "$src"
for f in *; do
    [ -f "$f" ] || continue
    if [ "$(stat -c %s "$f")" -le 1048576 ]; then
        cp "$f" "$out/"
        sha256sum "$f" >> "$out/PLAIN.sha256"
        continue
    fi
    base64 -w 76 "$f" | (cd "$out" && split -b "$size" -a 4 - "$f.tmp.")
    # split names them in alphabetical order; renumber as .part0, .part1, ...
    n=0
    while read -r p; do
        mv "$out/$p" "$out/$f.part$n"
        n=$((n + 1))
    done < <(cd "$out" && ls -1 -- "$f".tmp.* | sort)
    cp "$out/$f.part0" "$out/$f.part00"
    echo "$f $n $(sha256sum "$f" | cut -d' ' -f1)" >> "$out/PARTS.txt"
done

cd "$out"
sha256sum ./*.part[0-9]* | sed 's|  \./|  |' > PARTS.sha256
install -m 0755 "$repo/release/reassemble.sh" reassemble.sh
sha256sum reassemble.sh PARTS.txt PARTS.sha256 PLAIN.sha256 > SHA256SUMS
