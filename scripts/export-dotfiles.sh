#!/usr/bin/env bash
# Run OUTSIDE. Regenerate dotfiles/ from the pod's home-manager output.
#
#   ./scripts/export-dotfiles.sh
#
# Nix stays the source here; dotfiles/ is the plain-file form of the same
# configs, laid out as they sit under $HOME, for the inner repo's dotfiles dir.
# Files naming /nix/store are pinned to the release they were exported with:
# those paths come from that release's pod-delta.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
FILES="$(nix build --no-link --print-out-paths --impure --expr \
    '(builtins.getFlake (toString ./.)).packages.x86_64-linux.runai-layer-nvim.passthru.files')"

rm -rf dotfiles
for rel in .bashrc \
           .config/fish/config.fish \
           .config/nvim/init.lua \
           .config/nvim/lua/config \
           .config/nvim/lua/plugins \
           .config/tmux/tmux.conf; do
    mkdir -p "dotfiles/$(dirname "$rel")"
    # -L: home-manager's tree is symlinks into the store.
    cp -rL --no-preserve=mode,ownership,timestamps "$FILES/$rel" "dotfiles/$rel"
done
find dotfiles -type f -exec chmod 0644 {} +
