#!/usr/bin/env bash
# Append the layers onto each internal base, registry-side.
#
#   ./docker/assemble.sh <tag-prefix>
#
# crane fetches only each base's manifest and config; it never pulls or unpacks
# the base layers, so the 30GB pytorch bases cost the same as the slim ones.
# Two images per variant, in ascending order of how often they change:
#
#   workspace-store:<RELEASE>-<variant>-<base digest>     once per release
#       base + pod-full(BASE_RELEASE) + pod-delta(RELEASE); session-env as
#       image ENV, PATH prepended. Built only when the tag is missing, so the
#       ~1 GB layers are fetched once per release (or base change), not per
#       commit. FORCE_STORE=1 rebuilds it.
#   workspace:<tag-prefix>-<variant>                       every commit
#       the store image + repo-layer.tar (~400 KB); entrypoint and labels.
#
# The store release is STORE_RELEASE (default: the STORE_RELEASE file). Its
# files are read from STORE_DIR (default dist/, one release per directory);
# a missing one is fetched from the project's GitLab generic package registry,
# twentyx-store/<release>/<file>, with the CI job token. MANIFEST.txt names
# the base release that holds pod-full.tar.gz and whether a delta exists.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
TAG_PREFIX="${1:?usage: assemble.sh <tag-prefix>}"

REGISTRY="${IMAGE_REGISTRY:?set IMAGE_REGISTRY, e.g. quay.internal/ai}"
BASE_REGISTRY="${BASE_REGISTRY:-$REGISTRY}"
VARIANTS="${IMAGE_VARIANTS:-base-slim base-pytorch vscode-slim vscode-pytorch}"
BASE_TAG="${BASE_TAG:-latest}"
STORE_DIR="${STORE_DIR:-dist}"
STORE_RELEASE="${STORE_RELEASE:-$(cat STORE_RELEASE 2>/dev/null || true)}"
LAYER_REPO="${LAYER_REPO:-dist/repo-layer.tar}"

die() { printf 'error: %s\n' "$*" >&2; exit 1; }
command -v crane >/dev/null || die "crane not found"
command -v jq >/dev/null || die "jq not found"
[ -n "$STORE_RELEASE" ] || die "set STORE_RELEASE (or commit a STORE_RELEASE file)"
[ -f "$LAYER_REPO" ] || die "missing repo layer: $LAYER_REPO (docker/mklayer.sh)"
mkdir -p "$STORE_DIR"

# store_file <release> <name>: the local path, fetched first when missing.
store_file() {
    local f="$STORE_DIR/$2"
    if [ ! -f "$f" ]; then
        [ -n "${CI_API_V4_URL:-}" ] || die "missing $f, and no CI registry to fetch it from"
        curl -fSL --connect-timeout 10 --header "JOB-TOKEN: $CI_JOB_TOKEN" -o "$f.part" \
            "$CI_API_V4_URL/projects/$CI_PROJECT_ID/packages/generic/twentyx-store/$1/$2" \
            || die "cannot fetch twentyx-store/$1/$2"
        mv "$f.part" "$f"
    fi
    printf '%s' "$f"
}
manifest() { sed -n "s/^$1=//p" "$MANIFEST"; }

MANIFEST="$(store_file "$STORE_RELEASE" MANIFEST.txt)"
[ "$(manifest RELEASE)" = "$STORE_RELEASE" ] \
    || die "$MANIFEST is release $(manifest RELEASE), not $STORE_RELEASE -- one release per STORE_DIR"
BASE_RELEASE="$(manifest BASE_RELEASE)"
KIND="$(manifest KIND)"

# ── PATH must be PREPENDED, never replaced ────────────────────────────────
# The pytorch bases put conda/site-packages directories on PATH, and torch does
# not work without them. `crane mutate --env` overwrites, and there is no shell
# at image-config level to expand $PATH -- so read the base's own value and
# build the new one from it. `crane config` fetches the config blob only.
base_path() {
    crane config "$1" 2>/dev/null \
        | jq -r '.config.Env[]? | select(startswith("PATH=")) | sub("^PATH=";"")' \
        | head -1
}

# ── the Nix session variables become image ENV ────────────────────────────
# A shell rc only reaches processes that source it; `runai exec -- cmd` and
# code-server's task runner never do. --occurrence=1 stops at the first match:
# pod-tar.sh writes opt/ before the store paths.
session_env_args() {
    local line
    while IFS= read -r line; do
        [ -n "$line" ] || continue
        printf -- '--env\n%s\n' "$line"
    done < <(tar -xzOf "$1" --occurrence=1 opt/twentyx/session-env 2>/dev/null || true)
}

# The store image for one base: built once, then cross-mounted by every commit.
build_store() {
    local base="$1" store="$2" full delta envlayer basepath
    full="$(store_file "$BASE_RELEASE" pod-full.tar.gz)"
    APPEND=(-f "$full")
    envlayer="$full"
    if [ "$KIND" = delta ]; then
        delta="$(store_file "$STORE_RELEASE" pod-delta.tar.gz)"
        # The delta overlays the full layer: new store paths, and an opt/
        # tree (profile link, session-env, store-paths, sudo) that wins.
        APPEND+=(-f "$delta")
        envlayer="$delta"
    fi
    crane append -b "$base" -t "$store" "${APPEND[@]}" >/dev/null

    basepath="$(base_path "$base")"
    if [ -z "$basepath" ]; then
        # No PATH in the base config means the runtime falls back to the
        # kernel default. Reproduce it rather than silently dropping /sbin.
        echo "  warn: $base declares no PATH; using a conservative default" >&2
        basepath="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin"
    fi
    mapfile -t ENVARGS < <(session_env_args "$envlayer")
    [ "${#ENVARGS[@]}" -gt 0 ] || die "no session-env in $envlayer"
    crane mutate "$store" -t "$store" \
        "${ENVARGS[@]}" \
        --env TOOLCHAIN_ROOT=/opt/twentyx \
        --env "PATH=/opt/twentyx/libexec:/opt/twentyx/bin:/opt/twentyx/profile/bin:${basepath}" \
        --label "twentyx.store-release=${STORE_RELEASE}" >/dev/null
}

echo "store release $STORE_RELEASE ($KIND against $BASE_RELEASE)"
for variant in $VARIANTS; do
    base="${BASE_REGISTRY}/${variant}:${BASE_TAG}"
    digest="$(crane digest "$base")"
    store="${REGISTRY}/workspace-store:${STORE_RELEASE}-${variant}-${digest:7:12}"
    dest="${REGISTRY}/workspace:${TAG_PREFIX}-${variant}"
    echo "==> ${variant}"
    echo "    base  ${base}"

    if [ -z "${FORCE_STORE:-}" ] && crane manifest "$store" >/dev/null 2>&1; then
        echo "    store ${store} (exists)"
    else
        echo "    store ${store} (building)"
        build_store "$base" "$store"
    fi

    # The vscode-* bases launch code-server from their ENTRYPOINT. Replacing
    # it is how ours runs at all, so record what it should hand over TO.
    BASE_ENTRY="$(crane config "$base" 2>/dev/null \
        | jq -r '((.config.Entrypoint // []) + (.config.Cmd // [])) | join(" ")')"

    crane append -b "$store" -t "$dest" -f "$LAYER_REPO" >/dev/null
    crane mutate "$dest" -t "$dest" \
        --env "BASE_ENTRYPOINT=${BASE_ENTRY}" \
        --entrypoint /opt/twentyx/libexec/entrypoint \
        --label "org.opencontainers.image.revision=${TAG_PREFIX}" \
        --label "twentyx.variant=${variant}" >/dev/null
    echo "    ->    ${dest}"
done
