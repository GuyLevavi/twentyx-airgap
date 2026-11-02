#!/usr/bin/env bash
# Run OUTSIDE. Cut one delta release into twentyx-store/<RELEASE>/.
#
#   ./scripts/make-release.sh --base-release <id> \
#       --pod-base <full layer tarball the delta sits on> \
#       --wsl-base <store-paths file of the WSL closure already inside>
#
# RELEASE is <yyyymmdd>-<10 char rev>. The folder holds exactly:
#
#   MANIFEST.txt           RELEASE, KIND, BASE_RELEASE
#   pod-delta.tar.gz       nvim layer delta, rooted at /opt/twentyx
#   wsl-delta.nar.tar.gz   nix-store --export stream of the WSL delta
#   apply.sh               WSL updater, from release/apply.sh
#   HANDOVER.md            inner repo edits, from release/HANDOVER.md
#   inside-seed.tar        this repo's tree at the release commit
#   crane-layer.tar        crane and its closure at nix/store/..., for CI
#
# The repo layer is not here: inner builds its own with docker/mklayer.sh.
# KIND=full (nixos-wsl.tar.gz, pod-full.tar.gz, windows-kit.tar.gz) is not
# implemented; we only cut deltas today.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
USAGE="usage: make-release.sh --base-release ID --pod-base TARBALL --wsl-base FILE"
BASE_RELEASE="" POD_BASE="" WSL_BASE=""
while [ $# -gt 0 ]; do
    case "$1" in
        --base-release) BASE_RELEASE="${2:?}"; shift 2 ;;
        --pod-base)     POD_BASE="$(realpath "${2:?}")"; shift 2 ;;
        --wsl-base)     WSL_BASE="$(realpath "${2:?}")"; shift 2 ;;
        *) echo "$USAGE" >&2; exit 2 ;;
    esac
done
[ -n "$BASE_RELEASE" ] && [ -f "$POD_BASE" ] && [ -s "$WSL_BASE" ] || { echo "$USAGE" >&2; exit 2; }

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

[ -z "$(git status --porcelain)" ] || {
    echo "the working tree is not clean; the release would not match its commit" >&2
    exit 1
}

REV="$(git rev-parse HEAD)"
RELEASE="$(date +%Y%m%d)-${REV:0:10}"
OUT="twentyx-store/$RELEASE"
WORK="dist/release-work"
rm -rf "$OUT" "$WORK"
mkdir -p "$OUT" "$WORK/pod"

say "pod delta"
ln -s "$POD_BASE" "$WORK/pod/nix-layer-nvim.tar.gz"
./scripts/build-layers.sh "$WORK/pod-out" --since "$WORK/pod" > /dev/null
install -m 0644 "$WORK/pod-out/nix-layer-nvim-delta.tar.gz" "$OUT/pod-delta.tar.gz"

say "wsl delta"
./scripts/nix-export.sh "$WORK/wsl" --since-paths "$WSL_BASE" --nar
tar --owner=0 --group=0 --mtime='@1' -C "$WORK/wsl" -cf - wsl-delta.nar \
    | gzip -n -6 > "$OUT/wsl-delta.nar.tar.gz"
TOPLEVEL="$(sed -n 's/^toplevel=//p' "$WORK/wsl/TRANSFER")"
cp "$WORK/wsl/store-paths" "dist/baselines/wsl-${REV:0:7}.store-paths"

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
        -e "s|@TOPLEVEL@|$TOPLEVEL|g" \
        -e "s|@CRANE@|$CRANE|g" "$1"
}
fill release/apply.sh | sed -e "/^@BASE_REFS@$/{r $WORK/wsl/base-refs" -e 'd}' > "$OUT/apply.sh"
chmod 0755 "$OUT/apply.sh"
# The changelog goes in too, one heading level down.
{ fill release/HANDOVER.md; echo; sed 's/^#/##/' CHANGELOG.md; } > "$OUT/HANDOVER.md"

cat > "$OUT/MANIFEST.txt" <<MANIFEST
RELEASE=$RELEASE
KIND=delta
BASE_RELEASE=$BASE_RELEASE
SOURCE_REV=$REV
WSL_TOPLEVEL=$TOPLEVEL
CRANE=$CRANE/bin/crane
ARTIFACTS=pod-delta.tar.gz wsl-delta.nar.tar.gz apply.sh HANDOVER.md inside-seed.tar crane-layer.tar
MANIFEST

rm -rf "$WORK"
say "done: $OUT ($(du -sh "$OUT" | cut -f1))"
ls -lh "$OUT" | awk 'NR > 1 { printf "  %6s  %s\n", $5, $9 }'
