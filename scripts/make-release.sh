#!/usr/bin/env bash
# Run OUTSIDE. Cut one delta release into twentyx-store/<RELEASE>/.
#
#   ./scripts/make-release.sh --base-release <id> \
#       --wsl-base <store-paths file> [--wsl-base <another> ...]
#
# --wsl-base lists what the box's store already holds: normally the
# dist/baselines/wsl-<rev>.store-paths the previous release wrote.
#
# RELEASE is <yyyymmdd>-<10 char rev>. The folder holds exactly:
#
#   MANIFEST.txt           RELEASE, KIND, BASE_RELEASE
#   pod-delta.tar.gz       nvim layer with its whole closure, rooted at /opt/twentyx
#   wsl-delta.nar.tar.gz   nix-store --export stream: the WSL system, minus --wsl-base
#   wsl-needs.txt          paths the stream refers to but leaves out; apply.sh checks them
#   apply.sh               WSL updater, from release/apply.sh: import, then switch
#   WSL.md                 the inner agent's instructions for apply.sh
#   HANDOVER.md            inner repo edits, from release/HANDOVER.md
#   inside-seed.tar        this repo's tree at the release commit
#   crane-layer.tar        crane and its closure at nix/store/..., for CI
#
# What crosses is twentyx-store/<RELEASE>-b64/: the same files, with every one
# over 1 MiB as base64 parts (default 20 MiB, --part-bytes), part0 also as
# part00, and reassemble.sh. See scripts/shard-release.sh.
#
# Every check runs here, before the folder exists (README "Releases"): the
# release refuses to be cut unless dotfiles/ is the export of this commit,
# every store path it names ships in the pod layer, LazyVim works with no
# network, and every shipped path still matches its NAR hash.
#
# The repo layer is not here: inner builds its own with docker/mklayer.sh.
# KIND=full (nixos-wsl.tar.gz, pod-full.tar.gz, windows-kit.tar.gz) is not
# implemented; we only cut deltas today.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
USAGE="usage: make-release.sh --base-release ID --wsl-base FILE [--wsl-base FILE ...] [--part-bytes N]"
BASE_RELEASE="" WSL_BASE=() PART_BYTES=20971520
while [ $# -gt 0 ]; do
    case "$1" in
        --base-release) BASE_RELEASE="${2:?}"; shift 2 ;;
        --wsl-base)     WSL_BASE+=("$(realpath "${2:?}")"); shift 2 ;;
        --part-bytes)   PART_BYTES="${2:?}"; shift 2 ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
[ -n "$BASE_RELEASE" ] && [ "${#WSL_BASE[@]}" -gt 0 ] || { echo "$USAGE" >&2; exit 2; }
for f in "${WSL_BASE[@]}"; do [ -s "$f" ] || { echo "empty or missing: $f" >&2; exit 2; }; done

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ -z "$(git status --porcelain)" ] || {
    echo "the working tree is not clean; the release would not match its commit" >&2
    exit 1
}

die() { printf 'error: %s\n' "$*" >&2; exit 1; }

# ── pre-transfer gates ────────────────────────────────────────────────────
# dotfiles/ names /nix/store paths and crosses as text, so a stale export
# points pods at paths no layer carries.
say "gate: dotfiles/ is this commit's export"
./scripts/export-dotfiles.sh >/dev/null
[ -z "$(git status --porcelain -- dotfiles)" ] || {
    git status --short -- dotfiles >&2
    die "dotfiles/ differs from a fresh export -- commit it, then cut the release"
}

say "gate: LazyVim offline"
nvim_out="$(./scripts/check-nvim-offline.sh 2>&1)" \
    || { printf '%s\n' "$nvim_out" >&2; die "LazyVim does not work offline"; }

REV="$(git rev-parse HEAD)"
RELEASE="$(date +%Y%m%d)-${REV:0:10}"
OUT="twentyx-store/$RELEASE"
WORK="dist/release-work"
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT"

# The whole layer, not the difference from a base: what the pods run on inside
# is not visible from here, and a missing path only shows up at runtime.
say "pod layer"
./scripts/build-layers.sh "$WORK/pod-out" > /dev/null
install -m 0644 "$WORK/pod-out/nix-layer-nvim.tar.gz" "$OUT/pod-delta.tar.gz"

say "gate: every store path dotfiles/ names is in the pod layer"
tar -xzOf "$OUT/pod-delta.tar.gz" --occurrence=1 opt/twentyx/store-paths 2>/dev/null \
    | sort -u > "$WORK/pod-paths" || true
[ -s "$WORK/pod-paths" ] || die "the pod layer has no opt/twentyx/store-paths"
grep -rhoE '/nix/store/[a-z0-9]{32}-[^/"'"'"' :;]*' dotfiles | sort -u \
    | comm -23 - "$WORK/pod-paths" > "$WORK/unshipped"
[ ! -s "$WORK/unshipped" ] || { cat "$WORK/unshipped" >&2; die "dotfiles/ names store paths the pod layer lacks"; }

# The whole system, minus what the box already holds. apply.sh switches to it,
# so after it the box holds exactly this closure: that is the next base.
say "wsl system"
WSL_SYSTEM="$(nix build --no-link --print-out-paths .#wsl-system)"
mkdir -p "$WORK/wsl" dist/baselines
nix-store -qR "$WSL_SYSTEM" > "$WORK/wsl/closure"
sort -u "${WSL_BASE[@]}" > "$WORK/wsl/base"
# -qR prints dependencies first, the order --import needs.
grep -vxFf "$WORK/wsl/base" "$WORK/wsl/closure" > "$WORK/wsl/delta-paths" || true
mapfile -t DELTA < "$WORK/wsl/delta-paths"
if [ "${#DELTA[@]}" -gt 0 ]; then
    nix-store -q --references "${DELTA[@]}" | sort -u \
        | comm -23 - <(sort -u "$WORK/wsl/delta-paths") > "$OUT/wsl-needs.txt"
else
    : > "$OUT/wsl-needs.txt"
fi
# argv, not xargs: xargs may split the list into several exports, and
# --import stops at the first one's end marker.
nix-store --export "${DELTA[@]}" > "$WORK/wsl/wsl-delta.nar"
say "  ${#DELTA[@]} of $(wc -l < "$WORK/wsl/closure") paths, $(du -h "$WORK/wsl/wsl-delta.nar" | cut -f1)"
tar --owner=0 --group=0 --mtime='@1' -C "$WORK/wsl" -cf - wsl-delta.nar \
    | gzip -n -6 > "$OUT/wsl-delta.nar.tar.gz"
sort -u "$WORK/wsl/closure" > "dist/baselines/wsl-${REV:0:7}.store-paths"

say "gate: the shipped paths match their NAR hashes"
# A store damaged since the build must fail here, not in the gap.
sort -u "$WORK/pod-paths" "$WORK/wsl/delta-paths" | xargs -r nix store verify --no-trust 2>&1 \
    | { grep -v "^checking '" >&2 || true; } \
    || die "nix store verify failed -- repair the store, then cut the release"

say "crane layer"
CRANE="$(nix build --no-link --print-out-paths .#nixosConfigurations.wsl.pkgs.crane)"
nix path-info -r "$CRANE" | sed 's|^/||' \
    | tar --owner=0 --group=0 --sort=name --mtime='@1' -C / -cf "$OUT/crane-layer.tar" -T -

say "inside seed"
git archive --format=tar --prefix=inside-seed/ -o "$OUT/inside-seed.tar" HEAD

say "apply.sh and HANDOVER.md"
fill() {
    sed -e "s|@RELEASE@|$RELEASE|g" \
        -e "s|@BASE_RELEASE@|$BASE_RELEASE|g" \
        -e "s|@CRANE@|$CRANE|g" \
        -e "s|@WSL_SYSTEM@|$WSL_SYSTEM|g" "$1"
}
fill release/apply.sh > "$OUT/apply.sh"
fill release/WSL.md > "$OUT/WSL.md"
chmod 0755 "$OUT/apply.sh"
# The changelog goes in too, one heading level down.
{ fill release/HANDOVER.md; echo; sed 's/^#/##/' CHANGELOG.md; } > "$OUT/HANDOVER.md"

cat > "$OUT/MANIFEST.txt" <<MANIFEST
RELEASE=$RELEASE
KIND=delta
BASE_RELEASE=$BASE_RELEASE
SOURCE_REV=$REV
WSL_SYSTEM=$WSL_SYSTEM
CRANE=$CRANE/bin/crane
ARTIFACTS=pod-delta.tar.gz wsl-delta.nar.tar.gz wsl-needs.txt apply.sh WSL.md HANDOVER.md inside-seed.tar crane-layer.tar
MANIFEST

rm -rf "$WORK"
say "release: $OUT ($(du -sh "$OUT" | cut -f1))"
ls -lh "$OUT" | awk 'NR > 1 { printf "  %6s  %s\n", $5, $9 }'

# What crosses: big files as base64 parts, see shard-release.sh.
say "shards"
SHARDS="$OUT-b64"
./scripts/shard-release.sh "$OUT" "$SHARDS" "$PART_BYTES"
say "test: reassemble the shards and compare"
CHECK="$(mktemp -d)"
sh "$SHARDS/reassemble.sh" "$CHECK" > /dev/null \
    && diff -r "$OUT" "$CHECK" > /dev/null \
    || { rm -rf "$CHECK"; die "the shards do not reassemble to $OUT"; }
rm -rf "$CHECK"
say "done: carry $SHARDS ($(ls "$SHARDS" | wc -l) files, $(du -sh "$SHARDS" | cut -f1))"
awk '{ printf "  %-24s %s parts\n", $1, $2 }' "$SHARDS/PARTS.txt"
