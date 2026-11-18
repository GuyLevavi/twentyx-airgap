#!/bin/sh
# Run INSIDE. Rebuild a release folder from its base64 parts, checking every
# checksum. Written by scripts/shard-release.sh next to the parts.
#
#   sh reassemble.sh [OUT_DIR]        (default: ./release beside this script)
#
# PARTS.txt lists each sharded file:   <name> <part count> <sha256 of file>
# PARTS.sha256 holds the sha256 of every part. part0 is also shipped as
# part00; whichever of the two is present and matches is used.
# Files that were not sharded are listed in PLAIN.sha256 and checked in place.
set -eu
here=$(cd "$(dirname "$0")" && pwd)
out=${1:-$here/release}
mkdir -p "$out"
cd "$here"

fail=0
sum() { sha256sum "$1" | cut -d' ' -f1; }
want() { awk -v f="$1" '$2 == f || $2 == "*"f { print $1; exit }' PARTS.sha256; }

while read -r name count fsum; do
    [ -n "$name" ] || continue
    tmp="$out/.$name.b64"
    : > "$tmp"
    i=0
    while [ "$i" -lt "$count" ]; do
        p="$name.part$i"
        if [ "$i" -eq 0 ] && { [ ! -f "$p" ] || [ "$(sum "$p")" != "$(want "$p")" ]; }; then
            p="$name.part00"
        fi
        if [ ! -f "$p" ]; then
            echo "MISSING  $name part $i" >&2; fail=1; break
        fi
        if [ "$(sum "$p")" != "$(want "$p")" ]; then
            echo "CORRUPT  $p" >&2; fail=1; break
        fi
        cat "$p" >> "$tmp"
        i=$((i + 1))
    done
    if [ "$i" -eq "$count" ]; then
        base64 -d "$tmp" > "$out/$name"
        if [ "$(sum "$out/$name")" = "$fsum" ]; then
            echo "ok       $name"
        else
            echo "BAD SUM  $name" >&2; rm -f "$out/$name"; fail=1
        fi
    fi
    rm -f "$tmp"
done < PARTS.txt

if [ -f PLAIN.sha256 ]; then
    while read -r s f; do
        f=${f#\*}
        if [ -f "$f" ] && [ "$(sum "$f")" = "$s" ]; then
            cp "$f" "$out/$f"; echo "ok       $f"
        else
            echo "BAD/MISSING  $f" >&2; fail=1
        fi
    done < PLAIN.sha256
fi

if [ "$fail" -eq 0 ]; then
    echo "RESULT: ok -> $out"
else
    echo "RESULT: FAILED (see above); ask outside to resend the named parts" >&2
    exit 1
fi
