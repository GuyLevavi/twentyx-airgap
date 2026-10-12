#!/usr/bin/env bash
# Build the repo layer: the pod scripts, the dotfiles and a few /etc files.
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

mkdir -p "$(dirname "$OUT")" "$STAGE/opt/twentyx/etc/containers" "$STAGE/usr/local/bin" \
    "$STAGE/etc/profile.d"

# pod/ is the image's libexec (the contract path: ENTRYPOINT, PATH, sudo
# targets); dotfiles/ is what the entrypoint links into $HOME. env/ stays out:
# a pod takes its CA and pip.conf from the base or the injection mounts.
cp -a pod "$STAGE/opt/twentyx/libexec"
cp -a dotfiles "$STAGE/opt/twentyx/dotfiles"

# The entrypoint writes etc/session.env here at start (gid 0 can: g=u below).
# Podman without touching /etc: vfs works everywhere a pod does (no mount(2)),
# on local disk; CONTAINERS_STORAGE_CONF points here (image ENV).
cat > "$STAGE/opt/twentyx/etc/containers/storage.conf" <<'EOF'
[storage]
driver = "vfs"
runroot = "/tmp/twentyx-cache/containers/runroot"
graphroot = "/tmp/twentyx-cache/containers/graph"
EOF

# Login shells started outside $HOME's rc files (`runai exec -- bash -l`, an
# sshd session) still get what the entrypoint resolved.
cat > "$STAGE/etc/profile.d/twentyx.sh" <<'EOF'
# shellcheck shell=sh
[ -r /opt/twentyx/etc/session.env ] && . /opt/twentyx/etc/session.env
EOF
# What doctor prints as the version: the commit this layer was cut from.
git rev-parse --short HEAD > "$STAGE/opt/twentyx/VERSION" 2>/dev/null \
    || echo dev > "$STAGE/opt/twentyx/VERSION"

# ── sudo/root for the runtime user ────────────────────────────────────────
# RunAI pods run as an arbitrary UID (observed: uid 10001) whose only
# guaranteed group is gid 0. Grant the root group passwordless sudo, so
# podman and anything else that needs real root is reachable.
#
# The sudoers files must be owned by root and not writable by others or sudo
# refuses them -- the tar below pins --owner=0. /etc/sudoers is shipped
# wholesale: slim bases may not have one at all, and replacing a stock file we
# do not rely on beats a sudo that cannot start.
mkdir -p "$STAGE/etc/sudoers.d"
cat > "$STAGE/etc/sudoers" <<'EOF'
Defaults env_reset
Defaults secure_path=/opt/twentyx/bin:/opt/twentyx/profile/bin:/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin
root ALL=(ALL:ALL) ALL
%#0 ALL=(ALL) NOPASSWD: ALL
@includedir /etc/sudoers.d
EOF
chmod 0440 "$STAGE/etc/sudoers"

# One entry on PATH that exists before anything has been bootstrapped, so
# the doctor is runnable in a pod where everything else went wrong.
ln -s /opt/twentyx/libexec/doctor "$STAGE/usr/local/bin/doctor"

# Deterministic: identical inputs must produce an identical blob, or every
# rebuild uploads a new layer and invalidates the registry cache for no reason.
# --mode='g=u' plus --group=0 is the OpenShift arbitrary-UID requirement.
tar --owner=0 --group=0 --mode='g=u' \
    --sort=name --mtime='@1' \
    -C "$STAGE" -cf "$OUT" opt usr etc

printf '%s  %s\n' "$(du -h "$OUT" | cut -f1)" "$OUT"
