#!/usr/bin/env bash
# Build the repo layer: the libexec runtime scripts and the agent helpers.
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
NIX_LAYER="${LAYER_NIX:-dist/nix-layer.tar.gz}"
STAGE="$(mktemp -d)"
trap 'rm -rf "$STAGE"' EXIT

mkdir -p "$(dirname "$OUT")" "$STAGE/opt/twentyx" "$STAGE/usr/local/bin"

for d in libexec agent; do
    cp -a "$d" "$STAGE/opt/twentyx/$d"
done
cp -a VERSION "$STAGE/opt/twentyx/VERSION"

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
cat > "$STAGE/etc/sudoers.d/twentyx" <<'EOF'
# Managed by the airgap repo layer. RunAI runtime user has gid 0.
%#0 ALL=(ALL) NOPASSWD: ALL
EOF
chmod 0440 "$STAGE/etc/sudoers" "$STAGE/etc/sudoers.d/twentyx"

# ── git: neutral settings, system scope ───────────────────────────────────
# There is deliberately no packaged ~/.config/git/config in the Nix layer: it
# would be a store symlink and `git config --global user.email` on the PVC
# could then never write through it. Identity is per-user on the durable home;
# these shared, identity-free defaults ship here and in nix/hosts/wsl.nix
# (environment.etc) — keep the two in sync.
cat > "$STAGE/etc/gitconfig" <<'EOF'
# Managed by the airgap repo layer. Per-user identity belongs in the user's
# own ~/.config/git/config (durable PVC), set once: git config --global.
[init]
	defaultBranch = main
[pull]
	rebase = true
[pager]
	diff = delta
	log = delta
	reflog = delta
	show = delta
[interactive]
	diffFilter = delta --color-only
[delta]
	navigate = true
	side-by-side = true
	line-numbers = true
[merge]
	conflictstyle = diff3
EOF

# The setuid sudo binary. Nix strips setuid bits from build outputs, so the
# copy is done here, outside Nix: pull it out of the Nix layer (its RPATH and
# plugin paths are absolute store paths that exist at runtime) and set the bit
# on the copy. The repo layer is appended after the Nix layer, so this wins.
# Skipped when the Nix layer is not beside us; doctor catches a missing
# or unusable sudo.
mkdir -p "$STAGE/opt/twentyx/bin"
if [ -f "$NIX_LAYER" ]; then
    tar -xzOf "$NIX_LAYER" --occurrence=1 opt/twentyx/bin/sudo \
        > "$STAGE/opt/twentyx/bin/sudo" 2>/dev/null || true
    if [ -s "$STAGE/opt/twentyx/bin/sudo" ]; then
        # 4555, not 4755: the tar's --mode='g=u' copies user bits to group, and
        # a group-writable setuid binary would let any gid-0 process replace
        # it. With u=r-x there is nothing for g=u to escalate.
        chmod 4555 "$STAGE/opt/twentyx/bin/sudo"
    else
        echo "warn: no sudo in $NIX_LAYER -- is sudo in the closure?" >&2
        rm -f "$STAGE/opt/twentyx/bin/sudo"
    fi
else
    echo "warn: $NIX_LAYER absent -- building repo layer without the sudo copy" >&2
fi

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
