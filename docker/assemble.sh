#!/usr/bin/env bash
# Append the layers onto each internal base, registry-side.
#
#   ./docker/assemble.sh <tag-prefix>
#
# crane fetches only each base's manifest and config; it never pulls or unpacks
# the base layers. The 30GB pytorch bases therefore cost the same as the slim
# ones, which is what keeps the build pod inside its ephemeral storage budget.
#
# Up to three layers, appended in ascending order of how often they change, so
# a config edit re-uploads ~380KB and cross-mounts the rest:
#
#   1. nix-layer       the whole toolchain closure       squash   ~1070MB / ~1087MB
#   2. nix-layer-delta new store paths + opt/ tree        per change  usually <100MB
#   3. repo-layer      libexec, agent helpers, sudoers    hourly     ~380KB
#
# The delta is optional and cumulative against the base layer beneath it
# (scripts/build-layers.sh --delta); store paths are immutable, so overlaying
# it is exactly an upgrade. Its opt/ tree wins over the base's: the profile
# symlink, store-paths and session-env are re-read from it.
#
# Two flavors per variant: the nvim layer is ~17MB larger, and not every
# workspace wants an editor in it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG_PREFIX="${1:?usage: assemble.sh <tag-prefix>}"

REGISTRY="${IMAGE_REGISTRY:?set IMAGE_REGISTRY, e.g. quay.internal/ai}"
BASE_REGISTRY="${BASE_REGISTRY:-$REGISTRY}"
VARIANTS="${IMAGE_VARIANTS:-base-slim base-pytorch vscode-slim vscode-pytorch}"
BASE_TAG="${BASE_TAG:-latest}"

LAYER_NIX="${LAYER_NIX:-dist/nix-layer.tar.gz}"
LAYER_NIX_NVIM="${LAYER_NIX_NVIM:-dist/nix-layer-nvim.tar.gz}"
LAYER_NIX_DELTA="${LAYER_NIX_DELTA:-dist/nix-layer-delta.tar.gz}"
LAYER_NIX_DELTA_NVIM="${LAYER_NIX_DELTA_NVIM:-dist/nix-layer-delta-nvim.tar.gz}"
LAYER_REPO="${LAYER_REPO:-dist/repo-layer.tar}"

command -v crane >/dev/null || { echo "crane not found (nix shell .# gives you one)" >&2; exit 1; }
command -v jq    >/dev/null || { echo "jq not found" >&2; exit 1; }

for f in "$LAYER_NIX" "$LAYER_REPO"; do
    [ -f "$f" ] || { echo "missing layer: $f" >&2; exit 1; }
done
# The deltas are optional: a base that already matches the closure has none.

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
    done < <(tar -xzOf "$layer" --occurrence=1 opt/twentyx/session-env 2>/dev/null || true)
}

echo "layers:"
for f in "$LAYER_NIX" "$LAYER_NIX_NVIM" "$LAYER_NIX_DELTA" "$LAYER_NIX_DELTA_NVIM" "$LAYER_REPO"; do
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
    NEWPATH="/opt/twentyx/libexec:/opt/twentyx/bin:/opt/twentyx/profile/bin:${BASEPATH}"

    # Same reasoning for the entrypoint: the vscode-* bases launch code-server
    # from theirs. entrypoint bootstraps and then hands over, so record
    # what it should hand over TO instead of discarding it.
    BASE_ENTRY="$(crane config "$base" 2>/dev/null \
        | jq -r '((.config.Entrypoint // []) + (.config.Cmd // [])) | join(" ")')"

    for flavor in $FLAVORS; do
        case "$flavor" in
            plain) nixlayer="$LAYER_NIX";      nixdelta="$LAYER_NIX_DELTA";      suffix="" ;;
            nvim)  nixlayer="$LAYER_NIX_NVIM"; nixdelta="$LAYER_NIX_DELTA_NVIM"; suffix="-nvim" ;;
        esac
        dest="${REGISTRY}/workspace:${TAG_PREFIX}-${variant}${suffix}"

        echo "==> ${variant}${suffix}"
        echo "    base ${base}"

        # Overlay order: base, then the delta that upgrades it, then text.
        APPEND=(-f "$nixlayer")
        [ -f "$nixdelta" ] && APPEND+=(-f "$nixdelta")
        APPEND+=(-f "$LAYER_REPO")
        crane append -b "$base" -t "$dest" "${APPEND[@]}" >/dev/null

        # Read per flavor, from the topmost layer that carries it: the nvim
        # base resolves to different store paths than the plain one, and the
        # delta re-tars opt/ on every closure change.
        envlayer="$nixlayer"
        [ -f "$nixdelta" ] && envlayer="$nixdelta"
        mapfile -t ENVARGS < <(session_env_args "$envlayer")
        [ "${#ENVARGS[@]}" -gt 0 ] || echo "  warn: no session-env in $envlayer" >&2

        # Image config only; no layer traffic.
        crane mutate "$dest" -t "$dest" \
            "${ENVARGS[@]}" \
            --env TOOLCHAIN_ROOT=/opt/twentyx \
            --env "PATH=${NEWPATH}" \
            --env "BASE_ENTRYPOINT=${BASE_ENTRY}" \
            --entrypoint /opt/twentyx/libexec/entrypoint \
            --label "org.opencontainers.image.revision=${TAG_PREFIX}" \
            --label "twentyx.variant=${variant}" \
            --label "twentyx.flavor=${flavor}" >/dev/null

        echo "    -> ${dest}"
    done
done

echo "done: $(echo "$VARIANTS" | wc -w) variant(s) x $(echo "$FLAVORS" | wc -w) flavor(s)"
