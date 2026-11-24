#!/usr/bin/env bash
# Run OUTSIDE. Print the store paths a release's WSL payload carried, so a
# later release can count them as already on the box:
#
#   ./scripts/release-paths.sh twentyx-store/<RELEASE> [...] > paths
#
# Reads the nix-store --export stream without importing it: each entry ends
# with "NIXE", padding, then the path as a length-prefixed string.
set -euo pipefail
for dir in "$@"; do
    kind="$(sed -n 's/^KIND=//p' "$dir/MANIFEST.txt" 2>/dev/null || true)"
    tar -xzOf "$dir/wsl-${kind:-delta}.nar.tar.gz" "wsl-${kind:-delta}.nar"
done | python3 -I -c '
import re, struct, sys
data = sys.stdin.buffer.read()
for m in re.finditer(rb"NIXE\0\0\0\0(.{8})(/nix/store/[a-z0-9]{32}-[^\0]+)", data, re.S):
    n = struct.unpack("<Q", m.group(1))[0]
    p = m.group(2)[:n]
    if len(p) == n:
        print(p.decode())
' | sort -u
