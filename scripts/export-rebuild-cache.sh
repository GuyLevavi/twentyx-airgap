#!/usr/bin/env bash
# The offline rebuild cache for an ALREADY-IMPORTED WSL distro.
#
#   ./scripts/export-rebuild-cache.sh          # -> dist/wsl-rebuild.tar.gz
#
# What it carries, and why each root is needed for a rebuild that never
# touches the network:
#
#   flake inputs      eval: the flake cannot even resolve without them
#   stdenvNoCC        config-only builds: writeText, runCommand shells
#   makeWrapper       the opencode PATH wrap runs wrapProgram at build time
#   vscode-langservers-extracted, tombi
#                     runtime deps newer than the imported image; without
#                     them the rebuilt system names paths the store lacks
#
# The cache is a file:// binary cache (content-addressed), not an archive:
# inside the distro it is extracted to /var/cache/nix-transfer and imported
# with `nix copy --from file:///var/cache/nix-transfer --all`.
#
# Add a root here when a rebuild reports a missing store path -- that report
# names the exact path; this file is the place it gets added.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

CACHE=dist/wsl-rebuild
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

rm -rf "$CACHE" dist/wsl-rebuild.tar.gz
mkdir -p "$CACHE"

say "collecting roots"
INPUTS=$(nix flake archive --json | jq -r '.. | .path? // empty' | sort -u)
NP="(import (builtins.getFlake (toString ./.)).inputs.nixpkgs {})"
STDENV=$(nix build --no-link --print-out-paths --impure --expr "$NP.stdenvNoCC")
MAKEWRAPPER=$(nix build --no-link --print-out-paths --impure --expr "$NP.makeWrapper")
JSONLSP=$(nix build --no-link --print-out-paths --impure --expr "$NP.vscode-langservers-extracted")
TOMBI=$(nix build --no-link --print-out-paths --impure --expr "$NP.tombi")
printf '%s\n' "$INPUTS" "$STDENV" "$MAKEWRAPPER" "$JSONLSP" "$TOMBI"

say "nix copy -> $CACHE"
# shellcheck disable=SC2086
nix copy --to "file://$PWD/$CACHE?compression=xz" $INPUTS "$STDENV" "$MAKEWRAPPER" "$JSONLSP" "$TOMBI"

say "packing"
tar -C dist -czf dist/wsl-rebuild.tar.gz wsl-rebuild
ls -lh dist/wsl-rebuild.tar.gz
du -sh "$CACHE"
