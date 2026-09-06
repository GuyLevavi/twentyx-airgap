# The RunAI image layer: a tarball crane-appends onto every base variant.
#
# Nix never runs in a pod. This derivation is evaluated and built on the
# connected machine, and what crosses the gap is a plain filesystem tree.
#
# The store closure MUST land at literal /nix/store: every Nix-built binary
# names its ELF interpreter by absolute store path, so relocating the tree to
# /opt/airgap/nix would produce several hundred megabytes of binaries that
# cannot exec. Appending as an image layer puts it at / for free.
{
  lib,
  runCommand,
  closureInfo,
  gnutar,
  gzip,
  hm,
}:
let
  # The buildEnv of every package in the home-manager config.
  profile = hm.config.home.path;

  # The generated dotfile tree (fish config, starship.toml, tmux.conf, the
  # nvim setup...). airgap-bootstrap symlinks out of this into $HOME, with the
  # persistent override layer winning — so packaged defaults come from Nix
  # while text iteration in a pod stays a file edit, not a rebuild.
  files = hm.config.home-files;

  closure = closureInfo { rootPaths = [ profile files ]; };
in
runCommand "runai-layer.tar.gz"
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    passthru = { inherit profile files closure; };
    meta.description = "Nix toolchain tree for crane-append onto RunAI bases";
  }
  ''
    mkdir -p root/opt/airgap
    ln -s ${profile} root/opt/airgap/profile
    ln -s ${files}   root/opt/airgap/home-defaults

    # Record the closure inside the image so `airgap doctor` can verify the
    # layer arrived intact without needing Nix to ask.
    cp ${closure}/store-paths root/opt/airgap/store-paths

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
