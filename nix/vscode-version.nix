# The Microsoft VS Code release whose Remote-WSL server this closure ships.
#
# Why a Microsoft server and not the closure's code-server: the Windows client
# the team installs is Microsoft's VS Code, and its Remote-WSL extension
# demands a server tarball for the client's EXACT commit (`code --version`).
# There is no download in the gap, so the tarball is pinned here and pre-seeded
# by nix/hosts/wsl.nix. The pod keeps its separate code-server (a different,
# browser-reached product) -- this file is about the WSL side.
#
# The version tracks the nixpkgs code-server pin, so the two IDE stacks cannot
# skew: code-server 4.Y.Z is built from VS Code 1.Y.Z (same minor), and the
# extensions in nix/vscode-extensions.nix are nixpkgs' pins, which is what
# makes their engine ranges meaningful. The check below fails evaluation the
# moment nixpkgs moves code-server without this file following.
#
# Re-pin procedure (all on a connected machine):
#   1. note the new `pkgs.code-server.version` (X.Y.Z)
#   2. set version = "1.Y.Z" (the same minor)
#   3. derive the commit from the download redirect:
#        curl -sIL "https://update.code.visualstudio.com/${version}/server-linux-x64/stable" \
#          | grep -i '^location' | tail -1        # .../stable/<commit>/vscode-server-linux-x64.tar.gz
#      (or read `product.json` -> `.commit` from an existing server tarball)
#   4. fetch both artifacts and paste the hashes:
#        nix store prefetch-file --json --name VSCodeSetup-x64-${version}.exe \
#          "https://update.code.visualstudio.com/${version}/win32-x64/stable"
#        nix store prefetch-file --json --name vscode-server-linux-x64.tar.gz \
#          "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/stable"
#   5. build .#windows-kit and the WSL tarball; both pick the pin up
{ pkgs }:
let
  lib = pkgs.lib;

  version = "1.115.0";
  commit = "41dd792b5e652393e7787322889ed5fdc58bd75b";

  # code-server 4.<minor> == VS Code 1.<minor>; anything else means nixpkgs
  # moved and this pin is stale (the extensions' engines and the server
  # tarball no longer match the pod's IDE).
  expectedCodeServer = "4.${lib.removePrefix "1." version}";
in
if pkgs.code-server.version != expectedCodeServer then
  throw ''
    nix/vscode-version.nix is stale: nixpkgs code-server is ${pkgs.code-server.version},
    but the VS Code pin is ${version} (expected code-server ${expectedCodeServer}).
    Follow the re-pin procedure at the top of nix/vscode-version.nix.
  ''
else
  {
    inherit version commit;

    server = {
      name = "vscode-server-linux-x64.tar.gz";
      url = "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/stable";
      hash = "sha256-2CQBU7TfYNO4m1Mf6Q0QXFt8C2txJgcN9kd7wX355J4=";
    };

    windowsInstaller = {
      name = "VSCodeSetup-x64-${version}.exe";
      url = "https://update.code.visualstudio.com/${version}/win32-x64/stable";
      hash = "sha256-DIyjEcqesBgPl8TKvP3VvmfqRTGub4XdrGLxR131NmI=";
    };
  }
