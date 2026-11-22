# Packages both the pod profile (nix/modules/tools.nix) and the WSL system
# (nix/wsl/packages.nix) ship. One definition, so both get the same store paths.
{ fetchurl, linkFarm, callPackage }:
let
  # Old interpreters for old wheels. See nix/pkgs/pbs-python.nix for why
  # these are python-build-standalone and not nixpkgs' python. 3.10 is the
  # last build upstream will ever cut: CPython 3.10 reached end of life.
  pbsPython = callPackage ./pbs-python.nix { };
  pbs310 = pbsPython {
    version = "3.10.22";
    release = "20261009";
    hash = "sha256-yqZrMI4Q81uBFAVN99knkD+XH2Mc+jI3uExA1dXzVUk=";
  };
  pbs311 = pbsPython {
    version = "3.11.18";
    release = "20261026";
    hash = "sha256-F8SXijbEltxTwIiZ742tGtJzT2Ml8I1gM6HmZBngryY=";
  };

  # pip source builds need a build backend. With build isolation pip fetches
  # setuptools from the index, which inside the gap works only while
  # Artifactory is reachable and mirrors it; with --no-build-isolation, or in
  # a `uv venv` created without --seed, there is nothing to fetch it from at
  # all. A find-links directory is consulted in addition to the index, so this
  # costs nothing when the index works and rescues the build when it does not.
  # Filenames are load-bearing: pip reads the version from the wheel name.
  wheelhouse = linkFarm "wheelhouse" (
    map
      (w: {
        inherit (w) name;
        path = fetchurl w;
      })
      [
        {
          name = "setuptools-84.2.1-py3-none-any.whl";
          url = "https://files.pythonhosted.org/packages/ef/55/6dc6d6bb953bdfc52519a0059592c52b6e3b8ad51cf8256dffceb55b0610/setuptools-84.2.1-py3-none-any.whl";
          sha256 = "ca140b45d5325a9478f880e351484f62fef15f336462e449ca0c03c873d589c2";
        }
        {
          name = "wheel-0.48.0-py3-none-any.whl";
          url = "https://files.pythonhosted.org/packages/2e/29/69cfbb602cd91690c55d38ba9fe53e6a7e76a6fa647bf38f19c138d25449/wheel-0.48.0-py3-none-any.whl";
          sha256 = "3217dcc807155e45db462d7ef2431f5ddda0d7273b700d05a67b271ceb1287ab";
        }
      ]
  );
in
{
  inherit pbs310 pbs311 wheelhouse;
  harlequin = callPackage ./harlequin.nix { };
  openCodeReview = callPackage ./open-code-review.nix { };
}
