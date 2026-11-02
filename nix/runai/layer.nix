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
  hm,
  # A previous layer's opt/twentyx/store-paths. When set this builds a DELTA:
  # all of /opt/twentyx, but only the store paths that base does not already
  # carry. crane-appended on top of that base, the image ends up with exactly
  # the new closure -- an upper OCI layer replaces /opt/twentyx's symlinks and
  # files, and every store path it omits is already in the layer below.
  basePaths ? null,
}:
let
  # The buildEnv of every package in the home-manager config.
  profile = hm.config.home.path;

  # The generated dotfile tree (fish config, starship.toml, tmux.conf, the
  # nvim setup...). airgap-bootstrap symlinks out of this into $HOME, with the
  # persistent override layer winning — so packaged defaults come from Nix
  # while text iteration in a pod stays a file edit, not a rebuild.
  files = hm.config.home-files;

  closure = closureInfo {
    rootPaths = [
      profile
      files
    ];
  };

  # home-manager bakes absolute paths built from home.homeDirectory into some
  # generated values (STARSHIP_CONFIG is one today). In a pod $HOME is
  # relocated onto the PVC, so those paths point at a directory that does not
  # exist. Recording the eval-time home lets airgap-bootstrap rewrite them
  # generically, instead of us maintaining a list of which vars are affected.
  evalHome = hm.config.home.homeDirectory;

  # The session variables, as image ENV rather than shell config.
  #
  # A shell rc only reaches processes that source it, which leaves out exactly
  # the ones that break most confusingly: `runai exec -- cmd`, code-server's
  # task runner, anything spawned by the agent. Those need TERMINFO_DIRS and
  # LOCALE_ARCHIVE just as much as an interactive fish does -- without them a
  # subprocess gets a dumb terminal and mangles every multibyte glyph.
  #
  # Values mentioning the eval-time home are excluded: $HOME is relocated at
  # pod start, so those are wrong here and are fixed per-shell instead (see
  # nix/modules/shell.nix).
  sessionEnv = writeText "airgap-session-env" (
    lib.concatMapStrings (l: l + "\n") (
      lib.mapAttrsToList (k: v: "${k}=${toString v}") (
        lib.filterAttrs (
          _: v:
          let
            str = toString v;
          in
          # Wrong here: $HOME is relocated at pod start, so these are fixed
          # per-shell instead (see nix/modules/shell.nix).
          !(lib.hasInfix evalHome str)
          # home-manager allows a session variable to be a shell EXPRESSION --
          # TMUX_TMPDIR is `''${XDG_RUNTIME_DIR:-"/run/user/$(id -u)"}`. A shell
          # expands that; image ENV does not, and tmux would be handed the
          # literal text. Anything needing expansion stays shell-only.
          && !(lib.hasInfix "$" str)
        ) hm.config.home.sessionVariables
      )
    )
  );
in
runCommand (if basePaths == null then "runai-layer.tar.gz" else "runai-layer-delta.tar.gz")
  {
    nativeBuildInputs = [
      gnutar
      gzip
    ];
    passthru = { inherit profile files closure basePaths; };
    meta.description = "Nix toolchain tree for crane-append onto RunAI bases";
  }
  ''
    mkdir -p root/opt/twentyx
    ln -s ${profile} root/opt/twentyx/profile
    ln -s ${files}   root/opt/twentyx/home-defaults

    # Record the closure inside the image so `airgap doctor` can verify the
    # layer arrived intact without needing Nix to ask.
    cp ${closure}/store-paths root/opt/twentyx/store-paths
    printf '%s' "${evalHome}" > root/opt/twentyx/eval-home

    # Consumed by docker/assemble.sh, one KEY=VALUE per line.
    cp ${sessionEnv} root/opt/twentyx/session-env

    # Everything is group-0 and group-readable: OpenShift assigns an arbitrary
    # UID at runtime and only GID 0 is guaranteed. Store paths are already
    # world-readable, so this only matters for what we add ourselves.
    tar --owner=0 --group=0 --mode='g=u' \
        --sort=name --mtime='@1' \
        -C root -cf layer.tar opt

    # Append the store closure, with paths made relative to / so they unpack to
    # /nix/store rather than anywhere else.
    ${
      if basePaths == null then
        "cp ${closure}/store-paths wanted.txt"
      else
        "comm -13 <(sort ${basePaths}) <(sort ${closure}/store-paths) > wanted.txt"
    }
    sed 's|^/||' wanted.txt > paths.txt
    tar --owner=0 --group=0 --sort=name --mtime='@1' \
        -rf layer.tar -C / -T paths.txt

    gzip -n -6 < layer.tar > $out
  ''
