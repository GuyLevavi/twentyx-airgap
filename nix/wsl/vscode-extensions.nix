# The VS Code extensions the WSL server seeds into ~/.vscode-server and the
# Windows kit ships for a manual sideload. Explicit fetchurls pinned to the
# versions that match nix/vscode-version.nix, so a nixpkgs bump cannot move
# them (and cannot break offline installs). LSP sharing with Zed/nvim: ruff
# and nixd are the SAME closure binaries the other editors use, pinned by
# absolute path in the remote machine settings; basedpyright and the YAML
# server ride bundled inside their extensions. JSON is built into VS Code
# (schema download disabled). No extension here fetches at activation.
#
# Re-pin: take the version from the Marketplace page, then
#   nix store prefetch-file --json <url>
# and paste url + hash. The URL shape is nixpkgs':
#   https://<publisher>.gallery.vsassets.io/_apis/public/gallery/publisher/<publisher>/extension/<name>/<version>/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage
{ pkgs }:
let
  fetchVsix =
    {
      name,
      url,
      hash,
    }:
    pkgs.fetchurl { inherit name url hash; };
in
[
  # Python lint/format; points at the closure ruff.
  {
    src = fetchVsix {
      name = "charliermarsh.ruff-2026.74.0.vsix";
      url = "https://charliermarsh.gallery.vsassets.io/_apis/public/gallery/publisher/charliermarsh/extension/ruff/2026.74.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage?targetPlatform=linux-x64";
      hash = "sha256-19D0nudX3NWF8dtkfkbXctb/BtPr4VuIVGXLBcg9JzQ=";
    };
  }
  # Python types (bundled server, offline).
  {
    src = fetchVsix {
      name = "detachhead.basedpyright-1.39.10.vsix";
      url = "https://detachhead.gallery.vsassets.io/_apis/public/gallery/publisher/detachhead/extension/basedpyright/1.39.10/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
      hash = "sha256-jvhWtI8orTEKT/NZf+ADzi2BZUGN9sZImEi7UuaJjzg=";
    };
  }
  # Nix; points at the closure nixd.
  {
    src = fetchVsix {
      name = "jnoortheen.nix-ide-0.5.13.vsix";
      url = "https://jnoortheen.gallery.vsassets.io/_apis/public/gallery/publisher/jnoortheen/extension/nix-ide/0.5.13/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
      hash = "sha256-0pMMnYFX+Ghs42Tvfcv9QqwhrEhCjIa7+6xJ51Fa0Dk=";
    };
  }
  # YAML; bundled server, schema store disabled.
  {
    src = fetchVsix {
      name = "redhat.vscode-yaml-1.24.0.vsix";
      url = "https://redhat.gallery.vsassets.io/_apis/public/gallery/publisher/redhat/extension/vscode-yaml/1.24.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
      hash = "sha256-Bmh1gxKn+mvtolnKWmhJ2QxdUZ32QV7b4kbBNeBtcWg=";
    };
  }
  # Theme, matching the tmux/WezTerm palette.
  {
    src = fetchVsix {
      name = "enkia.tokyo-night-1.1.2.vsix";
      url = "https://enkia.gallery.vsassets.io/_apis/public/gallery/publisher/enkia/extension/tokyo-night/1.1.2/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
      hash = "sha256-oW0bkLKimpcjzxTb/yjShagjyVTUFEg198oPbY5J2hM=";
    };
  }
  # The Zed default's theme family.
  {
    src = fetchVsix {
      name = "catppuccin.catppuccin-vsc-3.19.0.vsix";
      url = "https://catppuccin.gallery.vsassets.io/_apis/public/gallery/publisher/catppuccin/extension/catppuccin-vsc/3.19.0/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
      hash = "sha256-6/NHZkg37b6RyZIP89FMltSii+7sC5UTfHYFgyYyl4A=";
    };
  }
]
