# CPython from python-build-standalone -- the same relocatable builds uv
# downloads for itself, fetched here on the connected side instead.
#
# Why not nixpkgs' python: a Nix-built interpreter runs on Nix's own ld.so,
# which never looks in /usr/lib. In a pod that means manylinux wheels cannot
# find the base image's libstdc++, and nothing CUDA-shaped loads at all. PBS
# links only against the host glibc, so it behaves like a system python that
# happens to live in /nix/store. (nixpkgs also dropped 3.10 outright.)
#
# Only versioned names reach PATH -- python3.10, pip3.10 -- never `python3`.
# On a pytorch base the system interpreter owns torch and CUDA and must stay
# the default; these exist for `uv venv -p 3.10` and nothing else.
{
  lib,
  stdenvNoCC,
  fetchurl,
}:
{
  version,
  release,
  hash,
}:
let
  minor = lib.versions.majorMinor version;
in
stdenvNoCC.mkDerivation {
  pname = "pbs-python";
  version = "${version}+${release}";

  src = fetchurl {
    url = "https://github.com/astral-sh/python-build-standalone/releases/download/${release}/cpython-${version}%2B${release}-x86_64-unknown-linux-gnu-install_only_stripped.tar.gz";
    inherit hash;
  };

  # The binaries must keep /lib64/ld-linux-x86-64.so.2 as their interpreter:
  # in a pod that is the host's, on NixOS-WSL nix-ld provides it. Patching
  # them onto Nix's glibc would undo the entire reason for using PBS.
  dontConfigure = true;
  dontBuild = true;
  dontFixup = true;

  installPhase = ''
    runHook preInstall

    mkdir -p $out/lib $out/bin
    cp -a . $out/lib/python${minor}
    p=$out/lib/python${minor}

    # PBS is built with clang under /tools and installed to /install, and its
    # sysconfig remembers both. Every sdist build reads CC/LDSHARED from here,
    # so unpatched it tries to exec `clang` -- which the pod bases do not have.
    # Point it at the host toolchain instead, the same rewrite uv applies when
    # it installs a managed python. The flags themselves are gcc-compatible.
    for f in $p/lib/python${minor}/_sysconfigdata_*.py \
             $p/lib/python${minor}/config-${minor}-*/Makefile; do
      substituteInPlace "$f" \
        --replace-quiet '/tools/llvm/bin/llvm-ar' 'ar' \
        --replace-quiet 'clang++ ' 'c++ ' \
        --replace-quiet 'clang ' 'cc ' \
        --replace-quiet '"clang"' '"cc"' \
        --replace-quiet '/install' "$p"
    done

    for b in python${minor} pip${minor}; do
      ln -s $p/bin/$b $out/bin/$b
    done

    runHook postInstall
  '';

  meta = {
    description = "python-build-standalone CPython ${minor}, versioned names only";
    platforms = [ "x86_64-linux" ];
    license = lib.licenses.psfl;
    mainProgram = "python${minor}";
  };
}
