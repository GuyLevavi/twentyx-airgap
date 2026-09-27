#!/usr/bin/env bash
# Run INSIDE the airgap, after the physical transfer.
#
#   ./scripts/push-artifactory.sh dist/nix-layer.tar.gz [more files...]
#
# Uploads the layer tarballs so internal CI fetches them from Artifactory
# instead of from git. Git stays text-only, which is now literally true: the
# only binary artifacts left are Nix build outputs, and those are computed, not
# committed.
#
# Not to be confused with scripts/nix-import.sh, which loads the *WSL* transfer
# into a local Nix store. This one feeds the *image* pipeline, which has no Nix.
#
# Uses the `jf` CLI when present, curl otherwise -- on the very first transfer
# `jf` itself may not be installed yet.
set -euo pipefail

[ $# -gt 0 ] || { echo "usage: push-artifactory.sh <file> [file...]" >&2; exit 1; }

ART_URL="${ARTIFACTORY_URL:?set ARTIFACTORY_URL, e.g. https://artifactory.internal/artifactory}"
GENERIC_REPO="${ARTIFACTORY_GENERIC_REPO:-generic-local}"
VERSION="${LAYER_VERSION:-$(cat "$(dirname "${BASH_SOURCE[0]}")/../VERSION" 2>/dev/null || echo dev)}"
DEST_PATH="$GENERIC_REPO/airgap/$VERSION/"

upload() {
    local f="$1" name; name="$(basename "$f")"
    [ -f "$f" ] || { echo "no such file: $f" >&2; return 1; }

    echo "  uploading $name ($(du -h "$f" | cut -f1))"
    if command -v jf >/dev/null 2>&1; then
        jf rt upload --flat=true "$f" "$DEST_PATH"
    else
        : "${ARTIFACTORY_TOKEN:?set ARTIFACTORY_TOKEN for the curl path}"
        curl -fSL -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
            -T "$f" "$ART_URL/$DEST_PATH$name"
    fi
}

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

say "$ART_URL/$DEST_PATH"
for f in "$@"; do upload "$f"; done

cat <<EOF

  Uploaded to $ART_URL/$DEST_PATH

  CI fetches layers from there; see .gitlab-ci.yml:

    LAYER_BASE_URL=$ART_URL/$DEST_PATH
EOF
