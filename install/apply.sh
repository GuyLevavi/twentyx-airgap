#!/usr/bin/env bash
# apply.sh -- update the twentyx distro from a transfer folder, as root:
#
#   wsl -d twentyx -u root -- bash /mnt/c/twentyx/apply.sh [dir]
#
# [dir] defaults to this script's directory and holds MANIFEST.txt plus
# wsl-delta.nar or wsl-full.nar (extract the .7z first). Local files only:
# the inner repo's wsl/update.sh downloads a pinned release, then runs this.
#
#   1. import the NAR unless WSL_SYSTEM is already in the store (a fresh
#      install from the same release carries it)
#   2. pin the base with a GC root: every later delta is computed against it,
#      and the monthly GC would otherwise collect the base generation
#   3. set the system profile and switch
#
# Nix verifies the import: a delta whose base paths are missing is refused,
# and the error names the path -- carry the full NAR (a --rebase transfer).
# Rollback: nix-env -p /nix/var/nix/profiles/system --rollback &&
#           /nix/var/nix/profiles/system/bin/switch-to-configuration switch
set -euo pipefail

T="${1:-$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)}"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

[ "$(id -u)" = 0 ] || die "run as root: wsl -d twentyx -u root -- bash $0"
[ -f "$T/MANIFEST.txt" ] || die "no MANIFEST.txt in $T"
get() { sed -n "s/^$1=//p" "$T/MANIFEST.txt"; }
NEW="$(get WSL_SYSTEM)" BASE="$(get BASE_WSL_SYSTEM)" KIND="$(get KIND)"
[ -n "$NEW" ] && [ -n "$BASE" ] || die "MANIFEST.txt lacks WSL_SYSTEM/BASE_WSL_SYSTEM"
say "release $(get RELEASE) ($KIND against $(get BASE_RELEASE))"

if nix-store --check-validity "$NEW" 2>/dev/null; then
    say "system already in the store -- nothing to import"
else
    NAR="$T/wsl-$KIND.nar"
    [ -f "$NAR" ] || die "missing $NAR (extract wsl-$KIND.nar.7z first)"
    say "importing $(basename "$NAR")"
    nix-store --import < "$NAR" >/dev/null \
        || die "import failed -- a delta needs its base ($BASE); carry the full NAR"
fi

if nix-store --check-validity "$BASE" 2>/dev/null; then
    ln -sfn "$BASE" /nix/var/nix/gcroots/twentyx-base
fi

nix-env -p /nix/var/nix/profiles/system --set "$NEW"
# Exit 4: some units failed but the switch happened (NOTES.md "WSL switches
# exit 4"). The new system is active; report rather than abort.
rc=0
/nix/var/nix/profiles/system/bin/switch-to-configuration switch || rc=$?
case "$rc" in
    0) ;;
    4) say "switched, but some units failed (exit 4):"; systemctl --failed --no-pager || true ;;
    *) die "switch-to-configuration failed (exit $rc)" ;;
esac
say "done."
