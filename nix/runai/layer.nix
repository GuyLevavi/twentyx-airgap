# The RunAI image layers: the full closure tarball and the cheap opt/ tree.
#
# Nix never runs in a pod. These derivations are evaluated and built on the
# connected machine, and what crosses the gap is a plain filesystem tree.
#
# The store closure MUST land at literal /nix/store: every Nix-built binary
# names its ELF interpreter by absolute store path, so relocating the tree to
# /opt/twentyx/nix would produce several hundred megabytes of binaries that
# cannot exec. Appending as an image layer puts it at / for free.
#
# `layer` packs the whole closure. `opt` is only what we add ourselves (the
# /opt/twentyx tree), so a closure change ships as a small cumulative delta --
# `opt` plus the store paths the base layer does not have -- instead of a new
# ~1 GB base. Store paths are immutable, so the delta is purely additive.
{
  lib,
  runCommand,
  closureInfo,
  writeText,
  gnutar,
  gzip,
  profile,
  sessionEnv,
  homeDefaults,
  nvimPlugins,
}:
let
  closure = closureInfo {
    rootPaths = [
      profile
      homeDefaults
      nvimPlugins
    ];
  };

  sessionEnvFile = writeText "session-env" (
    lib.concatMapStrings (l: l + "\n") (
      lib.mapAttrsToList (k: v: "${k}=${toString v}") sessionEnv
    )
  );

  opt = runCommand "runai-layer-opt" { } ''
    mkdir -p $out/opt/twentyx
    ln -s ${profile} $out/opt/twentyx/profile
    ln -s ${homeDefaults} $out/opt/twentyx/home-defaults
    ln -s ${nvimPlugins} $out/opt/twentyx/nvim-plugins

    # sudo lands here as a plain copy (Nix strips setuid bits from outputs, so
    # the bit cannot be set in this derivation). docker/mklayer.sh extracts
    # this file from the topmost layer and sets the bit on the repo-layer copy,
    # which is appended after it and therefore wins.
    if [ -e "${profile}/bin/sudo" ]; then
        mkdir -p $out/opt/twentyx/bin
        cp "${profile}/bin/sudo" $out/opt/twentyx/bin/sudo
    fi

    # Record the closure inside the image so doctor can verify the layer
    # arrived intact without needing Nix to ask.
    cp ${closure}/store-paths $out/opt/twentyx/store-paths

    # Consumed by docker/assemble.sh, one KEY=VALUE per line.
    cp ${sessionEnvFile} $out/opt/twentyx/session-env
  '';
in
{
  inherit opt;

  layer = runCommand "runai-layer.tar.gz" {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    meta.description = "Nix toolchain tree for crane-append onto RunAI bases";
  } ''
    tar --owner=0 --group=0 --mode='g=u' \
        --sort=name --mtime='@1' \
        -C ${opt} -cf layer.tar opt

    # Append the store closure, with paths made relative to / so they unpack to
    # /nix/store rather than anywhere else.
    sed 's|^/||' ${closure}/store-paths > paths.txt
    tar --owner=0 --group=0 --sort=name --mtime='@1' \
        -rf layer.tar -C / -T paths.txt

    gzip -n -6 < layer.tar > $out
  '';
}
