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
#   .#wslDeltaRoots   tree-sitter, the VS Code server tarball + .vsix set and
#                     the auto-fix-vscode-server script (whose closure is the
#                     VS Code node patch). Kept in flake.nix so it can
#                     interpolate paths; see its comment for the policy.
#
# This is a DELTA, not an image: it supplements the imported system and the
# rest of the transfer. When a rebuild reports a missing store path, that
# path belongs in .#wslDeltaRoots (or the list here) and the cache is
# re-exported -- a rebase (`rm -rf dist && ./scripts/transfer-bundle.sh` +
# fresh `wsl --import`) is the other valid answer and carries no delta.
#
# The cache is a file:// binary cache (content-addressed), not an archive:
# inside the distro it is extracted to /var/cache/nix-transfer and imported
# with `nix copy --from file:///var/cache/nix-transfer --all`.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."

OUT=dist
CACHE_TAR="$OUT/wsl-rebuild.tar.gz"
say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

mkdir -p "$OUT"
# mktemp, not dist/wsl-rebuild: a leftover staging directory in dist would be
# packed into the carry tar as dead weight -- the previous shape did exactly
# that. Everything ships inside the tar.
STAGE="$(mktemp -d /tmp/wsl-rebuild-XXXXXX)"
trap 'rm -rf "$STAGE"' EXIT
CACHE="$STAGE/wsl-rebuild"
mkdir -p "$CACHE"

say "collecting roots"
INPUTS=$(nix flake archive --json | jq -r '.. | .path? // empty' | sort -u)
NP="(import (builtins.getFlake (toString ./.)).inputs.nixpkgs.outPath {})"
STDENV=$(nix build --no-link --print-out-paths --impure --expr "$NP.stdenvNoCC")
MAKEWRAPPER=$(nix build --no-link --print-out-paths --impure --expr "$NP.makeWrapper")
JSONLSP=$(nix build --no-link --print-out-paths --impure --expr "$NP.vscode-langservers-extracted")
TOMBI=$(nix build --no-link --print-out-paths --impure --expr "$NP.tombi")
DELTA_ROOTS=$(nix build --no-link --print-out-paths --impure \
    --expr 'let f = builtins.getFlake (toString ./.); in f.wslDeltaRoots')
printf '%s\n' "$INPUTS" "$STDENV" "$MAKEWRAPPER" "$JSONLSP" "$TOMBI" "$DELTA_ROOTS"

say "nix copy -> $CACHE"
# shellcheck disable=SC2086
nix copy --to "file://$CACHE?compression=xz" \
    $INPUTS "$STDENV" "$MAKEWRAPPER" "$JSONLSP" "$TOMBI" $DELTA_ROOTS

say "packing"
rm -f "$CACHE_TAR"
tar -C "$STAGE" -czf "$CACHE_TAR" wsl-rebuild
ls -lh "$CACHE_TAR"
du -sh "$CACHE"
