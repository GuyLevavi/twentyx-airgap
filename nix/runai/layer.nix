# The RunAI image layer: a tarball crane-appends onto every base variant.
#
# Nix never runs in a pod. This derivation is evaluated and built on the
# connected machine, and what crosses the gap is a plain filesystem tree.
#
# The store closure MUST land at literal /nix/store: every Nix-built binary
# names its ELF interpreter by absolute store path, so relocating the tree to
# /opt/twentyx/nix would produce several hundred megabytes of binaries that
# cannot exec. Appending as an image layer puts it at / for free.
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
in
runCommand "runai-layer.tar.gz"
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    meta.description = "Nix toolchain tree for crane-append onto RunAI bases";
  }
  ''
    mkdir -p root/opt/twentyx
    ln -s ${profile} root/opt/twentyx/profile
    ln -s ${homeDefaults} root/opt/twentyx/home-defaults
    ln -s ${nvimPlugins} root/opt/twentyx/nvim-plugins

    # sudo lands here as a plain copy (Nix strips setuid bits from outputs, so
    # the bit cannot be set in this derivation). docker/mklayer.sh extracts
    # this file from the layer and sets the bit on the repo-layer copy, which
    # is appended after this one and therefore wins.
    if [ -e "${profile}/bin/sudo" ]; then
        mkdir -p root/opt/twentyx/bin
        cp "${profile}/bin/sudo" root/opt/twentyx/bin/sudo
    fi

    # Record the closure inside the image so doctor can verify the layer
    # arrived intact without needing Nix to ask.
    cp ${closure}/store-paths root/opt/twentyx/store-paths

    # Consumed by docker/assemble.sh, one KEY=VALUE per line.
    cp ${sessionEnvFile} root/opt/twentyx/session-env

    # Everything is group-0 and group-readable: OpenShift assigns an arbitrary
    # UID at runtime and only GID 0 is guaranteed. Store paths are already
    # world-readable, so this only matters for what we add ourselves.
    tar --owner=0 --group=0 --mode='g=u' \
        --sort=name --mtime='@1' \
        -C root -cf layer.tar opt

    # Append the store closure, with paths made relative to / so they unpack to
    # /nix/store rather than anywhere else.
    sed 's|^/||' ${closure}/store-paths > paths.txt
    tar --owner=0 --group=0 --sort=name --mtime='@1' \
        -rf layer.tar -C / -T paths.txt

    gzip -n -6 < layer.tar > $out
  ''
