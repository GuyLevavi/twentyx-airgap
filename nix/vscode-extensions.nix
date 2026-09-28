# The VS Code extensions the Windows client installs, and the WSL server
# seeds into ~/.vscode-server/extensions. One list for both sides so a
# "works on my machine" split cannot appear between them.
#
# These are nixpkgs' pins (`pkgs.vscode-extensions.<publisher>.<name>`), which
# is deliberate: the hashes and versions are maintained by nixpkgs and move
# with the same input everything else does, and every one of them declares an
# engines.vscode range satisfied by nix/vscode-version.nix's version (checked
# 2026-09: ruff ^1.75, basedpyright ^1.101, nix-ide >=1.105, yaml ^1.63,
# tokyo-night ^1.17, catppuccin ^1.80). The .src of each derivation is the
# raw .vsix, which is exactly what crosses to Windows and what the server's
# own CLI installs from.
#
# LSP sharing with Zed/nvim: ruff and nixd are the SAME closure binaries the
# other editors use, pinned by absolute path in the remote machine settings;
# basedpyright and the YAML server ride bundled inside their extensions so
# nothing is fetched at runtime. JSON is built into VS Code (schema download
# disabled). No extension here may be one that fetches at activation: that is
# the class this repo exists to prevent.
{ pkgs }:
with pkgs.vscode-extensions;
[
  charliermarsh.ruff # Python lint/format; points at the closure ruff
  detachhead.basedpyright # Python types (bundled server, offline)
  jnoortheen.nix-ide # Nix; points at the closure nixd
  redhat.vscode-yaml # YAML; bundled server, schema store disabled
  enkia.tokyo-night # theme, matching the tmux/WezTerm palette
  catppuccin.catppuccin-vsc # the Zed default's theme family
]
