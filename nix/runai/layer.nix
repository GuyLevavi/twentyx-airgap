# The /opt/twentyx tree a pod layer starts with: what we add ourselves, plus
# the closure list. scripts/pod-tar.sh packs it first and the store paths
# after it, as a full layer (whole closure) or a delta (closure minus the
# base's), so this derivation never holds a tarball.
#
# Nix never runs in a pod. The store paths MUST land at literal /nix/store:
# every Nix-built binary names its ELF interpreter by absolute store path, so
# relocating them would produce binaries that cannot exec. Appending the tar as
# an image layer puts them at / for free.
{
  lib,
  runCommand,
  closureInfo,
  writeText,
  profile,
  sessionEnv,
  homeDefaults,
}:
let
  sessionEnvFile = writeText "session-env" (
    lib.concatMapStrings (l: l + "\n") (
      lib.mapAttrsToList (k: v: "${k}=${toString v}") sessionEnv
    )
  );

  # Rooted at the session-env file too: anything image ENV names (the
  # locales, extra terminfo, the LazyVim tree) must ship even when no profile
  # binary references it.
  closure = closureInfo {
    rootPaths = [
      profile
      homeDefaults
      sessionEnvFile
    ];
  };
in
runCommand "twentyx-pod-opt" { } ''
  mkdir -p $out/opt/twentyx
  ln -s ${profile} $out/opt/twentyx/profile
  ln -s ${homeDefaults} $out/opt/twentyx/home-defaults

  # sudo lands here as a plain copy: Nix strips setuid bits from outputs.
  # scripts/pod-tar.sh writes this member with mode 4555 -- a mode bit in a
  # tar header is data, so the layer carries the setuid binary.
  if [ -e "${profile}/bin/sudo" ]; then
      mkdir -p $out/opt/twentyx/bin
      cp "${profile}/bin/sudo" $out/opt/twentyx/bin/sudo
  fi

  # The closure inside the image, so doctor can verify the layer arrived
  # intact without Nix; the transfer diffs these lists for the delta.
  cp ${closure}/store-paths $out/opt/twentyx/store-paths

  # Image ENV, one KEY=VALUE per line (docker/assemble.sh).
  cp ${sessionEnvFile} $out/opt/twentyx/session-env
''
