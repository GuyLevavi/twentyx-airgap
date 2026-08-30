#!/usr/bin/env bash
# Run INSIDE the airgap, after the physical transfer.
#
#   ./scripts/push-artifactory.sh dist/airgap-vendor-0.1.0.tar.gz
#
# Uploads the transferred blobs to internal Artifactory so CI fetches from there
# instead of from git. Git stays text-only; vendor/ is gitignored.
#
# Uses the `jf` CLI when present, curl otherwise -- on the very first transfer
# `jf` itself may be inside the tarball you are trying to upload.
set -euo pipefail

TARBALL="${1:?usage: push-artifactory.sh <tarball>}"
[ -f "$TARBALL" ] || { echo "no such file: $TARBALL" >&2; exit 1; }

ART_URL="${ARTIFACTORY_URL:?set ARTIFACTORY_URL, e.g. https://artifactory.internal/artifactory}"
GENERIC_REPO="${ARTIFACTORY_GENERIC_REPO:-generic-local}"
NPM_REPO="${ARTIFACTORY_NPM_REPO:-npm-local}"

VERSION="$(basename "$TARBALL" .tar.gz | sed 's/^airgap-vendor-//')"
DEST_PATH="$GENERIC_REPO/airgap/$VERSION/"

# Verify before trusting a blob that crossed a physical boundary.
if [ -f "$TARBALL.sha256" ]; then
    echo "==> verifying transfer"
    sha256sum -c "$TARBALL.sha256" || { echo "CHECKSUM FAILED -- retransfer" >&2; exit 1; }
else
    echo "warn: no $TARBALL.sha256 alongside; cannot verify the transfer" >&2
fi

echo "==> uploading to $ART_URL/$DEST_PATH"
if command -v jf >/dev/null 2>&1; then
    jf rt upload --flat=true "$TARBALL"          "$DEST_PATH"
    jf rt upload --flat=true "$TARBALL.sha256"   "$DEST_PATH" 2>/dev/null || true
else
    echo "    (jf not found, using curl)"
    : "${ARTIFACTORY_TOKEN:?set ARTIFACTORY_TOKEN for the curl path}"
    curl -fSL -H "Authorization: Bearer $ARTIFACTORY_TOKEN" \
        -T "$TARBALL" "$ART_URL/$DEST_PATH$(basename "$TARBALL")"
fi

cat <<EOF

  Uploaded: $ART_URL/$DEST_PATH$(basename "$TARBALL")

  CI now fetches blobs from Artifactory, not from git:

    AIRGAP_VENDOR_URL=$ART_URL/$DEST_PATH$(basename "$TARBALL")

  To also publish the pi package to $NPM_REPO (so pods can
  \`pi install npm:@corp/airgap-pi\` without a rebuild):

    npm publish --registry $ART_URL/api/npm/$NPM_REPO/ ./pi
EOF
