# The Microsoft VS Code release whose Remote-WSL server this closure ships.
#
# Why a Microsoft server and not the closure's code-server: the Windows client
# the team installs is Microsoft's VS Code, and its Remote-WSL extension
# demands a server tarball for the client's EXACT commit (`code --version`).
# There is no download in the gap, so the tarball is pinned here and seeded by
# nix/hosts/wsl.nix. The pod keeps its separate code-server (a different,
# browser-reached product) -- this file is about the WSL side.
#
# Re-pin procedure (all on a connected machine):
#   1. pick the new VS Code release version X.Y.Z
#   2. derive the commit from the download redirect:
#        curl -sIL "https://update.code.visualstudio.com/${version}/server-linux-x64/stable" \
#          | grep -i '^location' | tail -1        # .../stable/<commit>/vscode-server-linux-x64.tar.gz
#      (or read `product.json` -> `.commit` from an existing server tarball)
#   3. fetch both artifacts and paste the hashes:
#        nix store prefetch-file --json --name VSCodeSetup-x64-${version}.exe \
#          "https://update.code.visualstudio.com/${version}/win32-x64/stable"
#        nix store prefetch-file --json --name vscode-server-linux-x64.tar.gz \
#          "https://update.code.visualstudio.com/commit:${commit}/server-linux-x64/stable"
#   4. re-pin nix/vscode-extensions.nix in the same commit (the .vsix engine
#      ranges must satisfy the new release)
{ ... }:
let
  version = "1.115.0";
  commit = "41dd792b5e652393e7787322889ed5fdc58bd75b";
in
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
