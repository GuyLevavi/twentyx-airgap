#!/usr/bin/env bash
# Append the layers onto each internal base, registry-side.
#
#   ./docker/assemble.sh <tag-prefix>
#
# crane fetches only each base's manifest and config; it never pulls or unpacks
# the base layers. The 30GB pytorch bases therefore cost the same as the slim
# ones, which is what keeps the build pod inside its ephemeral storage budget.
#
# Two layers, appended in ascending order of how often they change, so a
# config edit re-uploads ~80KB and cross-mounts the rest:
#
#   1. nix-layer      the whole toolchain closure     monthly    ~414MB / ~634MB
#   2. repo-layer     libexec, agent helpers, sudoers hourly     ~80KB
#
# Two flavors per variant: the nvim layer is ~250MB larger, and not every
# workspace wants an editor in it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG_PREFIX="${1:?usage: assemble.sh <tag-prefix>}"

REGISTRY="${AIRGAP_REGISTRY:?set AIRGAP_REGISTRY, e.g. quay.internal/ai}"
BASE_REGISTRY="${AIRGAP_BASE_REGISTRY:-$REGISTRY}"
VARIANTS="${AIRGAP_VARIANTS:-base-slim base-pytorch vscode-slim vscode-pytorch}"
BASE_TAG="${AIRGAP_BASE_TAG:-latest}"

LAYER_NIX="${AIRGAP_LAYER_NIX:-dist/nix-layer.tar.gz}"
LAYER_NIX_NVIM="${AIRGAP_LAYER_NIX_NVIM:-dist/nix-layer-nvim.tar.gz}"
LAYER_REPO="${AIRGAP_LAYER_REPO:-dist/repo-layer.tar}"

command -v crane >/dev/null || { echo "crane not found (nix shell .# gives you one)" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq not found" >&2; exit 1; }

for f in "$LAYER_NIX" "$LAYER_REPO"; do
    [ -f "$f" ] || { echo "missing layer: $f" >&2; exit 1; }
done

# The nvim flavor is optional: a pipeline that only needs the small image
# should not be forced to build and push the big one.
FLAVORS="plain"
if [ -f "$LAYER_NIX_NVIM" ]; then
    FLAVORS="plain nvim"
else
    echo "note: $LAYER_NIX_NVIM absent -- building the plain flavor only" >&2
fi

# ── PATH must be PREPENDED, never replaced ────────────────────────────────
# The pytorch bases put conda/site-packages directories on PATH, and torch does
# not work without them. `crane mutate --env` overwrites, and there is no shell
# at image-config level to expand $PATH -- so read the base's own value and
# build the new one from it. `crane config` fetches the config blob only, which
# is a few KB.
base_path() {
    crane config "$1" 2>/dev/null \
        | jq -r '.config.Env[]? | select(startswith("PATH=")) | sub("^PATH=";"")' \
        | head -1
}

# ── the Nix session variables become image ENV ────────────────────────────
# A shell rc only reaches processes that source it. TERMINFO_DIRS and
# LOCALE_ARCHIVE are needed by anything that renders text, including
# `runai exec -- cmd` and code-server's task runner, neither of which is a
# login shell. So they belong in the image config, not just in fish.
#
# --occurrence=1 makes tar stop at the first match instead of streaming the
# whole 400MB archive; the file is in the first member because layer.nix tars
# opt/ before appending the store.
session_env_args() {
    local layer="$1" line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf -- '--env\n%s\n' "$line"
    done < <(tar -xzOf "$layer" --occurrence=1 opt/airgap/session-env 2>/dev/null || true)
}

echo "layers:"
for f in "$LAYER_NIX" "$LAYER_NIX_NVIM" "$LAYER_REPO"; do
    [ -f "$f" ] && printf '  %-8s %s\n' "$(du -h "$f" | cut -f1)" "$f"
done

for variant in $VARIANTS; do
    base="${BASE_REGISTRY}/${variant}:${BASE_TAG}"

    BASEPATH="$(base_path "$base")"
    if [ -z "$BASEPATH" ]; then
        # No PATH in the base config means the runtime falls back to the
        # kernel default. Reproduce it rather than shipping a PATH that
        # silently drops /sbin.
        echo "  warn: $base declares no PATH; using a conservative default" >&2
        BASEPATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    fi
    NEWPATH="/opt/airgap/libexec:/opt/airgap/bin:/opt/airgap/profile/bin:${BASEPATH}"

    # Same reasoning for the entrypoint: the vscode-* bases launch code-server
    # from theirs. airgap-entrypoint bootstraps and then hands over, so record
    # what it should hand over TO instead of discarding it.
    BASE_ENTRY="$(crane config "$base" 2>/dev/null \
        | jq -r '((.config.Entrypoint // []) + (.config.Cmd // [])) | join(" ")')"

    for flavor in $FLAVORS; do
        case "$flavor" in
            plain) nixlayer="$LAYER_NIX";      suffix="" ;;
            nvim)  nixlayer="$LAYER_NIX_NVIM"; suffix="-nvim" ;;
        esac
        dest="${REGISTRY}/workspace:${TAG_PREFIX}-${variant}${suffix}"

        echo "==> ${variant}${suffix}"
        echo "    base ${base}"

        crane append -b "$base" -t "$dest" \
            -f "$nixlayer" -f "$LAYER_REPO" >/dev/null

        # Read per flavor: the nvim layer resolves to different store paths.
        mapfile -t ENVARGS < <(session_env_args "$nixlayer")
        [ "${#ENVARGS[@]}" -gt 0 ] || echo "  warn: no session-env in $nixlayer" >&2

        # Image config only; no layer traffic.
        crane mutate "$dest" -t "$dest" \
            "${ENVARGS[@]}" \
            --env AIRGAP_ROOT=/opt/airgap \
            --env "PATH=${NEWPATH}" \
            --env "AIRGAP_BASE_ENTRYPOINT=${BASE_ENTRY}" \
            --entrypoint /opt/airgap/libexec/airgap-entrypoint \
            --label "org.opencontainers.image.revision=${TAG_PREFIX}" \
            --label "airgap.variant=${variant}" \
            --label "airgap.flavor=${flavor}" >/dev/null

        echo "    -> ${dest}"
    done
done

echo "done: $(echo "$VARIANTS" | wc -w) variant(s) x $(echo "$FLAVORS" | wc -w) flavor(s)"
