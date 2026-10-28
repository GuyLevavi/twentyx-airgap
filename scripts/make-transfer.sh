#!/usr/bin/env bash
# Run OUTSIDE. Assemble one self-describing transfer directory: the git
# changes since what the airgapped repo last received, plus Nix deltas for
# both targets.
#
#   ./scripts/make-transfer.sh <base-rev> \
#       --layers-since <dir with the nix-layer-nvim.tar.gz already inside> \
#       --wsl-since <store-paths file of the WSL closure already inside> \
#       [--out <dir>]
#
# The repo inside has diverged a little, so the git part ships two ways:
# a bundle (fetch, then rebase or cherry-pick -- needs <base-rev> to exist
# inside) and plain patches (git am -3, which needs nothing but the
# preimage blobs, and degrades to --reject hunks when those are missing).
#
# Omit --layers-since or --wsl-since and that target ships in full.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
BASE="${1:?usage: make-transfer.sh <base-rev> [--layers-since DIR] [--wsl-since FILE] [--out DIR]}"
shift
LAYERS_SINCE=""
WSL_SINCE=""
OUT="dist/transfer-$(date +%Y%m%d)"
while [ $# -gt 0 ]; do
    case "$1" in
        --layers-since) LAYERS_SINCE="$(realpath "${2:?}")"; shift 2 ;;
        --wsl-since)    WSL_SINCE="$(realpath "${2:?}")"; shift 2 ;;
        --out)          OUT="${2:?}"; shift 2 ;;
        *) echo "unknown argument: $1" >&2; exit 1 ;;
    esac
done

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

git rev-parse --verify -q "$BASE^{commit}" >/dev/null || { echo "unknown revision: $BASE" >&2; exit 1; }
[ -z "$(git status --porcelain --untracked-files=no)" ] || {
    echo "the working tree has uncommitted changes; the bundle would not contain them" >&2
    exit 1
}
BRANCH="$(git symbolic-ref --short HEAD)"
BASE_SHORT="$(git rev-parse --short "$BASE")"
HEAD_SHORT="$(git rev-parse --short HEAD)"

mkdir -p "$OUT"/{git,runai,wsl}

# ── git ───────────────────────────────────────────────────────────────────
say "git: $BASE_SHORT..$HEAD_SHORT ($(git rev-list --count "$BASE..HEAD") commits)"
git bundle create "$OUT/git/airgap.bundle" "$BRANCH" "^$BASE" 2>/dev/null
git format-patch -q -o "$OUT/git/patches" "$BASE..HEAD"

# ── runai ─────────────────────────────────────────────────────────────────
say "runai layers"
if [ -n "$LAYERS_SINCE" ]; then
    ./scripts/build-layers.sh "$OUT/runai" --since "$LAYERS_SINCE"
else
    ./scripts/build-layers.sh "$OUT/runai"
fi

# ── wsl ───────────────────────────────────────────────────────────────────
say "wsl closure"
if [ -n "$WSL_SINCE" ]; then
    ./scripts/nix-export.sh "$OUT/wsl" --since-paths "$WSL_SINCE"
else
    ./scripts/nix-export.sh "$OUT/wsl"
fi
# The next transfer's baseline. It must also be kept OUTSIDE: it describes
# what the far side will hold, and nothing comes back across the gap.
mkdir -p dist/baselines
cp "$OUT/wsl/store-paths" "dist/baselines/wsl-$HEAD_SHORT.store-paths"
rm -rf "$OUT/wsl/cache"

# ── README ────────────────────────────────────────────────────────────────
if [ -n "$LAYERS_SINCE" ]; then
    LAYER_FILES="nix-layer-nvim-delta.tar.gz"
    LAYER_NOTE="A delta: keep the previous full layer in Artifactory, and set LAYER_DELTA_URL to this upload's folder in .gitlab-ci.yml."
else
    LAYER_FILES="nix-layer-nvim.tar.gz"
    LAYER_NOTE="A full layer: point LAYER_BASE_URL at this upload and unset LAYER_DELTA_URL."
fi
cat > "$OUT/README.md" <<EOF
# airgap transfer $HEAD_SHORT

Built $(date -u +%FT%TZ) from \`$BRANCH\` at \`$HEAD_SHORT\`, against \`$BASE_SHORT\`.

## 1. Repo

Either fetch the bundle (needs \`$BASE_SHORT\` to exist in the internal repo):

    git fetch <transfer>/git/airgap.bundle $BRANCH:airgap-incoming
    git rebase airgap-incoming        # or cherry-pick the commits you want

or apply the patches (one commit each, cherry-pickable):

    git am -3 <transfer>/git/patches/*.patch
    # on a conflict: fix, git add, git am --continue
    # no preimage at all:  git am --abort; git apply --reject <patch>

## 2. WSL (NixOS)

    sudo ./scripts/nix-import.sh <transfer>/wsl

$( [ -n "$WSL_SINCE" ] && echo "This is a DELTA. Do step 1 first: only a nix-import.sh from 0.2 on can
import one (an older one stops with \"path ... is not valid\"). It checks first
that every path the delta builds on is already in the local store, and stops
with a list if not." )
Then activate as the script prints.

## 3. RunAI layers

    cd <transfer>/runai && sha256sum -c *.sha256
    ./scripts/push-artifactory.sh $(for f in $LAYER_FILES; do printf '<transfer>/runai/%s ' "$f"; done)

$LAYER_NOTE
CI then rebuilds the node layer and runs docker/assemble.sh.

## Contents

$(cd "$OUT" && find . -type f ! -name README.md ! -name SHA256SUMS -printf '%s\t%p\n' | sort -k2 \
    | awk -F'\t' '{ printf "    %8.1f MB  %s\n", $1/1048576, $2 }')
EOF

sums="$(cd "$OUT" && find . -type f ! -name SHA256SUMS -print0 | sort -z | xargs -0 sha256sum)"
printf '%s\n' "$sums" > "$OUT/SHA256SUMS"

say "done: $OUT ($(du -sh "$OUT" | cut -f1))"
