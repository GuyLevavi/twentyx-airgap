# The RunAI CLI, pinned and declared. Fill this in from the Linux executable
# the RunAI UI offers -- that binary is built for YOUR cluster's server
# version, which is exactly what the bridge client wants.
#
#   1. Get the binary (download from the UI, or its internal URL).
#   2. nix store prefetch-file --json ./runai-cli-linux-amd64   # capture sha256
#   3. Fill version + hash + url below.
#   4. Wire it into nix/hosts/wsl.nix:
#        environment.systemPackages = [
#          (pkgs.callPackage ../packages/runai-cli.nix { })
#        ];
#
# Nothing else is needed: a static Go build (typical for the runai CLI) runs
# as-is; a dynamically linked one is covered by nix-ld, already enabled on
# the WSL host.
{
  pkgs,
  version ? "0.0.0-set-me",
  hash ? "sha256-set-me",
  url ? "https://REPLACE-ME/runai-cli-linux-amd64",
}:
pkgs.stdenvNoCC.mkDerivation {
  pname = "runai-cli";
  inherit version;
  src = pkgs.fetchurl {
    inherit url hash;
  };
  sourceRoot = ".";
  dontUnpack = true;
  preferLocalBuild = true;
  installPhase = ''
    install -Dm755 "$src" "$out/bin/runai"
  '';
  meta.description = "RunAI CLI, pinned from the cluster's own build";
}
