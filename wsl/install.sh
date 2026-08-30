#!/usr/bin/env bash
# Install the same toolchain into WSL, from the same vendor tarball.
#
#   ./wsl/install.sh [path/to/airgap-vendor-<v>.tar.gz]
#
# One artifact serves both targets. That is the point: if it works here it works
# in the pod, because it is the same tree with a different AIRGAP_STATE.
#
# Differences from the container:
#   - $HOME persists, so AIRGAP_STATE is ~/.airgap
#   - installs under ~/.local, never touching system dirs (no sudo)
#   - no LD_PRELOAD preloaders, so airgap-pi's strip is a no-op
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
SRC="$PWD"
TARBALL="${1:-}"
PREFIX="$HOME/.local"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

grep -qi microsoft /proc/version 2>/dev/null || \
    say "note: this does not look like WSL; continuing anyway"

# --- unpack vendored binaries ---------------------------------------------
if [ -n "$TARBALL" ]; then
    [ -f "$TARBALL" ] || { echo "no such tarball: $TARBALL" >&2; exit 1; }
    say "unpacking $TARBALL"
    tmp="$(mktemp -d)"; tar -xzf "$TARBALL" -C "$tmp"
    "$SRC/libexec/airgap-vendor-verify" "$tmp/vendor"
    mkdir -p "$PREFIX/bin"
    install -m 0755 "$tmp"/vendor/bin/* "$PREFIX/bin/"
    if [ -f "$tmp"/vendor/node-*.tar.xz ]; then
        say "installing node"
        mkdir -p "$PREFIX"
        tar -xJf "$tmp"/vendor/node-*.tar.xz -C "$PREFIX" --strip-components=1
    fi
    rm -rf "$tmp"
else
    say "no tarball given -- using whatever is already on PATH"
fi

# --- point AIRGAP_ROOT at this checkout ------------------------------------
# In WSL the git checkout IS the packaged layer; there is no image to bake.
export AIRGAP_ROOT="$SRC"
export AIRGAP_STATE="$HOME/.airgap"

say "bootstrapping (AIRGAP_STATE=$AIRGAP_STATE)"
"$SRC/libexec/airgap-bootstrap"

mkdir -p "$PREFIX/bin"
ln -sf "$SRC/bin/airgap" "$PREFIX/bin/airgap"

# Persist the layer locations for future shells.
mkdir -p "$AIRGAP_STATE/config/bashrc.d"
cat > "$AIRGAP_STATE/config/bashrc.d/00-wsl.sh" <<EOF
export AIRGAP_ROOT="$SRC"
export AIRGAP_STATE="$HOME/.airgap"
export PATH="$PREFIX/bin:\$PATH"
EOF

cat <<EOF

  Installed. Start a new shell, then:

    airgap doctor

  Update later with a plain \`git pull\` in $SRC -- in WSL the checkout is the
  packaged layer, so no rebuild step exists at all.
EOF
