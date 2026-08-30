#!/usr/bin/env bash
# STAGE 2 -- append the toolchain layer onto each internal base, registry-side.
#
# crane fetches only each base's manifest and config; it never pulls or unpacks
# the base layers. The 30GB pytorch bases cost the same as the slim ones, which
# is what keeps the OpenShift build pod inside its ephemeral storage budget.
#
#   ./assemble.sh toolchain.tar 8f3a91c
#
set -euo pipefail

TARBALL="${1:?usage: assemble.sh <toolchain.tar> <tag-prefix>}"
TAG_PREFIX="${2:?usage: assemble.sh <toolchain.tar> <tag-prefix>}"

REGISTRY="${AIRGAP_REGISTRY:?set AIRGAP_REGISTRY, e.g. quay.internal/ai}"
BASE_REGISTRY="${AIRGAP_BASE_REGISTRY:-$REGISTRY}"

# The internal base flavors. Same layer blob for all four: it is uploaded once
# and cross-mounted thereafter.
VARIANTS="${AIRGAP_VARIANTS:-base-slim base-pytorch vscode-slim vscode-pytorch}"
BASE_TAG="${AIRGAP_BASE_TAG:-latest}"

command -v crane >/dev/null || { echo "crane not found (vendor/bin/crane)" >&2; exit 1; }

[ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }
echo "layer: $TARBALL ($(du -h "$TARBALL" | cut -f1))"

for variant in $VARIANTS; do
    base="${BASE_REGISTRY}/${variant}:${BASE_TAG}"
    dest="${REGISTRY}/workspace:${TAG_PREFIX}-${variant}"

    echo "==> ${variant}"
    echo "    base ${base}"

    # append: base manifest+config only, then push the new layer.
    appended="$(crane append -b "$base" -f "$TARBALL" -t "$dest" 2>&1 | tail -1)"

    # mutate: image config only (no layer traffic).
    crane mutate "$dest" -t "$dest" \
        --env AIRGAP_ROOT=/opt/airgap \
        --env PATH='/opt/airgap/bin:/usr/local/bin:/usr/bin:/bin' \
        --entrypoint /opt/airgap/libexec/airgap-entrypoint \
        --label "org.opencontainers.image.revision=${TAG_PREFIX}" \
        --label "airgap.variant=${variant}" >/dev/null

    echo "    -> ${dest}"
done

echo "done: $(echo "$VARIANTS" | wc -w) variants"
