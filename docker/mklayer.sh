#!/usr/bin/env bash
# Build the repo layer: the dispatcher, the libexec scripts, the pi package.
#
#   ./docker/mklayer.sh [out.tar]        default: dist/repo-layer.tar
#
# No container involved. This layer is text, and text does not need a build --
# it needs a tar with the right ownership. That is the whole reason the old
# Stage 1 existed, and Nix having taken over the binaries is what lets it go.
#
# This is the layer that changes hourly, so it is appended last: crane uploads
# one small blob and cross-mounts everything below it.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
OUT="${1:-dist/repo-layer.tar}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$(dirname "$OUT")" "$STAGE/opt/airgap" "$STAGE/usr/local/bin"

# config/ is down to the pi settings now that Nix generates the shell, prompt,
# tmux and git configs; it is copied rather than linked because bootstrap seeds
# it into $HOME as an editable starting point, not as a packaged default.
for d in bin libexec config pi; do
    cp -a "$d" "$STAGE/opt/airgap/$d"
done
cp -a VERSION "$STAGE/opt/airgap/VERSION"

# One entry on PATH that exists before anything has been bootstrapped, so
# `airgap doctor` is runnable in a pod where everything else went wrong.
ln -s /opt/airgap/bin/airgap "$STAGE/usr/local/bin/airgap"

# Deterministic: identical inputs must produce an identical blob, or every
# rebuild uploads a new layer and invalidates the registry cache for no reason.
# --mode='g=u' plus --group=0 is the OpenShift arbitrary-UID requirement.
tar --owner=0 --group=0 --mode='g=u' \
    --sort=name --mtime='@1' \
    -C "$STAGE" -cf "$OUT" opt usr

printf '%s  %s\n' "$(du -h "$OUT" | cut -f1)" "$OUT"
