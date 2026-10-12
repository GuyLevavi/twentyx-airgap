#!/usr/bin/env bash
# Transfer: build the send set in dist/.
#
#   ./scripts/transfer.sh [--rebase]
#
# Everything is computed against base.rev, the outside rev whose closures the
# far side already has. Store paths only add, so a delta applies to anything
# that has the base, in any order:
#
#   default    pod-delta.tar.gz + wsl-delta.nar: what HEAD adds to the base
#   --rebase   pod-full.tar.gz + wsl-full.nar from HEAD, plus the install set
#              (nixos-wsl.tar.gz of the new base, the Windows kit,
#              SETUP.ps1/UNPACK.ps1); then base.rev = HEAD (commit it). On a
#              nixpkgs bump, when the deltas pass ~300 MB, or when the Windows
#              kit changed; the script warns. The first transfer is a rebase.
#
# Publishing: every file goes to twentyx-store/<RELEASE>/ of the transfer
# that made it, so the fulls and the install set live under BASE_RELEASE.
#
# build/ keeps the plain artifacts (gitignored); the base's build results are
# links there, a cache only -- losing them means a rebuild, never a wrong
# delta. dist/ is wiped and rebuilt each run; every big file crosses inside a
# .7z container (the pipeline drops big gzip), small text files cross plain.
# A dirty worktree is refused (ALLOW_DIRTY=1): RELEASE names a commit.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }
warn() { printf '\033[33mwarn:\033[0m %s\n' "$*" >&2; }
die() { printf 'error: %s\n' "$*" >&2; exit 1; }

REBASE=""
case "${1:-}" in
    "") ;;
    --rebase) REBASE=1 ;;
    *) die "usage: transfer.sh [--rebase]" ;;
esac
command -v 7z >/dev/null 2>&1 || die "7z not found -- run inside 'nix develop'"
command -v jq >/dev/null 2>&1 || die "jq not found -- run inside 'nix develop'"

DIRTY=""
if [ -n "$(git status --porcelain)" ]; then
    [ -n "${ALLOW_DIRTY:-}" ] || die "uncommitted changes -- commit first, or ALLOW_DIRTY=1"
    DIRTY="-dirty"
fi

# <commit date>-<short rev>: sortable, and names exactly one tree.
release_id() {
    printf '%s-%s' "$(git show -s --format=%cd --date=format:%Y%m%d "$1")" \
        "$(git rev-parse --short=10 "$1")"
}
nixpkgs_rev() { git show "$1:flake.lock" | jq -r '.nodes.nixpkgs.locked.rev'; }

REV="$(git rev-parse HEAD)"
if [ -n "$REBASE" ]; then
    BASE_REV="$REV"
    KIND="full"
else
    BASE_REV="$(cat base.rev 2>/dev/null)" || die "no base.rev -- the first transfer is --rebase"
    git cat-file -e "$BASE_REV^{commit}" 2>/dev/null || die "base.rev $BASE_REV is not a commit here"
    KIND="delta"
fi
RELEASE="$(release_id "$REV")$DIRTY"
BASE_RELEASE="$(release_id "$BASE_REV")"
BASE_FLAKE="git+file://$PWD?rev=$BASE_REV"

BUILD=build OUT=dist
mkdir -p "$BUILD"
rm -rf "$OUT"
mkdir -p "$OUT"
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT

# ── 1. closures: HEAD, and the base unless this is a rebase ───────────────
say "building $RELEASE"
POD="$(nix build --no-link --print-out-paths .#pod-opt)"
WSL="$(nix build --no-link --print-out-paths .#wsl-system)"
sort "$POD/opt/twentyx/store-paths" > "$TMP/pod"
nix-store -qR "$WSL" | sort > "$TMP/wsl"

if [ "$KIND" = full ]; then
    BASE_WSL="$WSL"
    cp "$TMP/pod" "$TMP/pod.ship"
    cp "$TMP/wsl" "$TMP/wsl.ship"
else
    say "building the base $BASE_RELEASE (normally a cache hit)"
    nix build "$BASE_FLAKE#pod-opt" -o "$BUILD/base-pod-opt"
    nix build "$BASE_FLAKE#wsl-system" -o "$BUILD/base-wsl-system"
    BASE_WSL="$(readlink -f "$BUILD/base-wsl-system")"
    sort "$BUILD/base-pod-opt/opt/twentyx/store-paths" > "$TMP/pod.base"
    nix-store -qR "$BASE_WSL" | sort > "$TMP/wsl.base"
    comm -13 "$TMP/pod.base" "$TMP/pod" > "$TMP/pod.ship"
    comm -13 "$TMP/wsl.base" "$TMP/wsl" > "$TMP/wsl.ship"
fi

# ── 2. the artifacts ──────────────────────────────────────────────────────
say "pod-$KIND.tar.gz: opt tree + $(wc -l < "$TMP/pod.ship") store paths"
./scripts/pod-tar.sh "$POD" "$TMP/pod.ship" "$BUILD/pod-$KIND.tar.gz"
ARTIFACTS=("$BUILD/pod-$KIND.tar.gz")

rm -f "$BUILD/wsl-$KIND.nar"
if [ -s "$TMP/wsl.ship" ]; then
    say "wsl-$KIND.nar: $(wc -l < "$TMP/wsl.ship") store paths"
    # argv, not xargs: xargs may split the list into several exports, and
    # concatenated exports import only up to the first end marker. A closure
    # is ~1000 paths, far below ARG_MAX.
    mapfile -t SHIP < "$TMP/wsl.ship"
    nix-store --export "${SHIP[@]}" > "$BUILD/wsl-$KIND.nar"
    ARTIFACTS+=("$BUILD/wsl-$KIND.nar")
else
    say "the WSL closure equals the base -- no NAR"
fi

# windows-kit-<zed version>.tar.gz; the Zed client must match the server in
# the closure, so a kit change is a rebase.
kit_file() { local n; n="$(nix eval --raw "$1#windows-kit.name")"; printf '%s' "${n#*-}"; }
KIT_FILE="$(kit_file .)"

if [ "$KIND" = delta ]; then
    mb=0
    for f in "${ARTIFACTS[@]}"; do mb=$((mb + $(stat -c %s "$f") / 1000000)); done
    say "deltas: $mb MB"
    [ "$mb" -le 300 ] || warn "the deltas are $mb MB (> 300) -- consider --rebase"
    [ "$(nixpkgs_rev "$BASE_REV")" = "$(nixpkgs_rev HEAD)" ] \
        || warn "nixpkgs moved since the base -- a --rebase ships less than this delta grows to"
    [ "$(kit_file "$BASE_FLAKE")" = "$KIT_FILE" ] \
        || warn "the Windows kit changed since the base ($KIT_FILE) -- only --rebase ships it"
fi

# ── 3. rebase: the install set (rootfs of the new base + the Windows kit) ─
if [ "$KIND" = full ]; then
    # Named by the base release, so it is built once per base. Real root is
    # required: nixos-install chroots and bind-mounts. No --chown: it runs
    # before the install, and the activation creates /home/jensen itself.
    ROOTFS="$BUILD/nixos-wsl-$BASE_RELEASE.tar.gz"
    if [ ! -f "$ROOTFS" ]; then
        say "building nixos-wsl.tar.gz (upstream builder, under sudo)"
        nix build "$BASE_FLAKE#wsl-tarball" -o "$BUILD/base-tarball-builder"
        sudo "$BUILD/base-tarball-builder/bin/nixos-wsl-tarball-builder" "$ROOTFS.part"
        sudo chown "$(id -u):$(id -g)" "$ROOTFS.part"
        mv "$ROOTFS.part" "$ROOTFS"
    fi
    ARTIFACTS+=("$ROOTFS")
    say "collecting $KIT_FILE"
    cp -f "$(nix build --no-link --print-out-paths .#windows-kit)" "$BUILD/$KIT_FILE"
    chmod u+w "$BUILD/$KIT_FILE"
    ARTIFACTS+=("$BUILD/$KIT_FILE")
    cp install/SETUP.ps1 install/UNPACK.ps1 "$OUT/"
fi

# ── 4. transport containers ───────────────────────────────────────────────
say "wrapping the big artifacts"
ABS_OUT="$(pwd)/$OUT"
for f in "${ARTIFACTS[@]}"; do
    b="$(basename "$f")"
    # Stored under its contract name (the rootfs carries the base release in
    # build/ only).
    name="$b"
    case "$b" in nixos-wsl-*.tar.gz) name=nixos-wsl.tar.gz ;; esac
    # gzip members are already compressed (-mx1 just stores); a NAR is raw.
    case "$b" in *.nar) mx=5 ;; *) mx=1 ;; esac
    # cd first: 7z stores the path as given.
    (cd "$(dirname "$f")" && 7z a -bso0 -bsp0 "-mx=$mx" -mmt=on "$ABS_OUT/$name.7z" "$b")
    [ "$name" = "$b" ] || 7z rn -bso0 "$ABS_OUT/$name.7z" "$b" "$name"
    say "  $name.7z ($(($(stat -c %s "$OUT/$name.7z") / 1000000)) MB)"
done

# ── 5. manifest + the updater ─────────────────────────────────────────────
cp install/apply.sh "$OUT/"
{
    echo "# twentyx store release -- generated by scripts/transfer.sh; see CONTRACT.md"
    echo "RELEASE=$RELEASE"
    echo "BASE_RELEASE=$BASE_RELEASE"
    echo "KIND=$KIND"
    echo "WSL_SYSTEM=$WSL"
    echo "BASE_WSL_SYSTEM=$BASE_WSL"
    echo "NIXPKGS_REV=$(nixpkgs_rev HEAD)"
    echo "WINDOWS_KIT=$KIT_FILE"
} > "$OUT/MANIFEST.txt"

# ── 6. cap check + listing ────────────────────────────────────────────────
LIMIT_MB=3072
for f in "$OUT"/*; do
    size=$(($(stat -c %s "$f") / 1000000))
    [ "$size" -lt "$LIMIT_MB" ] \
        || die "$(basename "$f") is $size MB, over the $LIMIT_MB MB/file transfer cap"
done
say "dist/ ($RELEASE, $KIND against $BASE_RELEASE):"
(cd "$OUT" && du -h ./* | sort -k2)

if [ -n "$REBASE" ]; then
    printf '%s\n' "$REV" > base.rev
    say "base.rev = $REV -- commit it: git commit -m 'base: $RELEASE' base.rev"
fi
