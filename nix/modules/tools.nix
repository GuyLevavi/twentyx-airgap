# The package set. Grouped by what the group is *for*, because the deciding
# question for every entry is "will I need this at 2am with no internet".
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.airgap;
  wsl = cfg.target == "wsl";

  # Old interpreters for old wheels. See nix/pkgs/pbs-python.nix for why
  # these are python-build-standalone and not nixpkgs' python. 3.10 is the
  # last build upstream will ever cut: CPython 3.10 reached end of life.
  pbsPython = pkgs.callPackage ../pkgs/pbs-python.nix { };
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

  # tealdeer downloads its page cache on first use. Inside the gap that is not
  # an error, it is a DNS lookup that hangs -- so the pages have to be a store
  # path, fetched here on the connected machine and carried across like
  # everything else. This is the shape the old manifest.toml was reaching for,
  # except Nix pins the hash and puts it in the closure automatically.
  #
  # The tag's source archive, not the release asset: upstream re-uploaded
  # tldr-pages.en.zip under the same v2.3 tag, which turned the pinned hash
  # into a build failure. A git tag archive is generated from the tree and
  # does not drift.
  tldrPages = pkgs.fetchzip {
    url = "https://github.com/tldr-pages/tldr/archive/refs/tags/v2.3.tar.gz";
    hash = "sha256-uMQ9Bul2g86AEcFYmFD9sOnUJaz08fguy9HENnKLwik=";
  };

  # tealdeer looks for `<cache_dir>/tldr-pages/pages.<lang>/<platform>/`.
  # Only the two platforms that can ever match: the archive also carries
  # android, osx, freebsd, netbsd, openbsd, sunos, dos and cisco-ios pages,
  # none of which will ever be looked up from a Linux container.
  tldrCache = pkgs.runCommand "tldr-cache" { } ''
    mkdir -p $out/tldr-pages/pages.en
    cp -r ${tldrPages}/pages/common ${tldrPages}/pages/linux $out/tldr-pages/pages.en/
  '';

  # pip source builds need a build backend. With build isolation pip fetches
  # setuptools from the index, which inside the gap works only while
  # Artifactory is reachable and mirrors it; with --no-build-isolation, or in
  # a `uv venv` created without --seed, there is nothing to fetch it from at
  # all. A find-links directory is consulted in addition to the index, so this
  # costs nothing when the index works and rescues the build when it does not.
  # Filenames are load-bearing: pip reads the version from the wheel name.
  wheelhouse = pkgs.linkFarm "wheelhouse" (
    map
      (w: {
        inherit (w) name;
        path = pkgs.fetchurl w;
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
  home.sessionVariables = {
    PIP_FIND_LINKS = "${wheelhouse}";
    UV_FIND_LINKS = "${wheelhouse}";
  };

  programs.bat.enable = true;
  programs.eza.enable = true;
  programs.ripgrep.enable = true;

  programs.tealdeer = {
    enable = true;
    settings = {
      # A store path, so it is read-only and shared -- and deliberately not
      # under XDG_CACHE_HOME, which airgap-bootstrap puts on ephemeral local
      # disk. A cache you cannot refill is not a cache; it is data.
      directories.cache_dir = "${tldrCache}";
      # Without this every invocation tries the network first.
      updates.auto_update = false;
    };
    # Otherwise the module installs a systemd timer running `tldr --update`.
    # On WSL that is a unit failing on every boot against a network that is not
    # there; in a pod there is no systemd to run it at all. The cache is a
    # store path -- updating it means a new closure, which means a transfer.
    #
    # (upstream removed the matching `updateOnActivation` for the same reason:
    # activation must not need the network. Setting it now is a hard error.)
    enableAutoUpdates = false;
  };

  home.packages =
    with pkgs;
    [
      # ── core CLI ───────────────────────────────────────────────────────
      fd
      jq
      yq-go # you had jq and zero YAML tooling, on OpenShift
      btop
      dust
      sd
      tree
      file
      less

      # ── offline documentation ──────────────────────────────────────────
      # You cannot google in there. This is the single highest-value group in
      # the whole list and the easiest one to forget.
      man-pages
      man-pages-posix
      glow # reading plan.md / agent output in-terminal

      # ── debugging what already bit you ─────────────────────────────────
      # The LD_PRELOAD hunt in NOTES.md and the OpenCode microarchitecture
      # segfault were both ten-minute problems with these present.
      strace
      lsof
      binutils # readelf, objdump — "why does this binary not start"
      patchelf
      psmisc
      procs

      # ── pod networking ─────────────────────────────────────────────────
      # The slim bases ship none of this, and without it you are blind the
      # first time the model endpoint stops answering.
      curl
      dnsutils # dig
      iproute2
      socat
      xh # poking the vLLM endpoint without writing a curl incantation

      # ── node ───────────────────────────────────────────────────────────
      # pi ships as JS via npm, so node is a hard runtime dependency in the
      # pod. It used to be a vendored tarball chosen for a conservative x86-64
      # baseline, because the compiled OpenCode binary segfaulted on older
      # cluster CPUs. nixpkgs builds for the same baseline, so that risk is
      # unchanged -- and it is now one line instead of a manifest entry, a
      # checksum, and an extract rule.
      nodejs_22

      # ── data ───────────────────────────────────────────────────────────
      sqlite # atuin's own store, plus general use
      jless

      # ── archives / transfer ────────────────────────────────────────────
      rsync
      zstd
      unzip
      p7zip
      pv

      # ── shell hygiene ──────────────────────────────────────────────────
      shellcheck # .gitlab-ci.yml already lints with this
      shfmt
      just
      hyperfine
      watchexec
      git-lfs
      glab # you are on GitLab and had vendored gh
      moreutils # sponge, ts

      # ── building sdists ────────────────────────────────────────────────
      # The pod bases ship gcc but no make, so any sdist with a Makefile step
      # dies halfway through a pip install. Deliberately NOT a Nix gcc: make
      # only execs `cc` from PATH, and the base image's compiler is the one
      # that matches its headers and the python it is building against.
      gnumake
    ]
    ++ lib.optionals cfg.tools.cluster.enable [
      # ── OpenShift / RunAI ──────────────────────────────────────────────
      # Deliberately NOT in the pod layer. You drive the cluster from WSL, and
      # a RunAI pod's service account generally cannot talk to the API server
      # anyway — so this would be several hundred MB of tools that cannot work
      # where they were shipped.
      kubectl
      k9s
      kubectx
      stern
      kubernetes-helm

      # ── your own image pipeline ────────────────────────────────────────
      # Build-side by definition: these produce and inspect the layer, so they
      # belong where the layer is built, not inside it.
      go-containerregistry # this *is* crane, and it is what assemble.sh runs
      skopeo
      dive
    ]
    ++ lib.optionals cfg.tools.gpu.enable [
      # The one cluster-side tool that IS worth carrying into the pod: it
      # reports the GPU you were actually fractioned, from inside.
      nvtopPackages.nvidia
    ]
    ++ lib.optionals cfg.tools.data.enable [
      # visidata is 1.38 GB of closure — it pulls pandas, pyarrow, matplotlib,
      # seaborn, h5py, numpy and arrow-cpp, an entire second Python data stack.
      # Genuinely useful on WSL; catastrophic in a layer that is supposed to be
      # tooling-only. Opt in deliberately, never by default.
      visidata
    ]
    ++ lib.optionals wsl [
      # ── Nix development, now that the config is Nix ────────────────────
      # Pointless in a pod: there is no Nix there to inspect.
      nixd
      nixfmt
      statix
      deadnix
      nix-tree # how you will answer "why is this closure 700 MB"
    ]
    ++ lib.optionals cfg.python.enable [
      # WSL only. See airgap.python.enable — on the *-pytorch bases the system
      # interpreter owns torch and CUDA, and a Nix python there would shadow it
      # while being unable to see any of it.
      #
      # 3.10 is not here: nixpkgs removed it, so it comes from PBS below.
      # Two interpreters cannot both own `python3` and `lib/libpython3.so` in
      # one profile, so the older one is lowPrio: buildEnv then resolves every
      # conflicting file in favour of 3.12, while `python3.11` stays on PATH
      # under its versioned name for `uv venv --python 3.11`.
      python312
      (lib.lowPrio python311)
      ruff
    ]
    ++ [
      # ── interpreters for old wheels, both targets ──────────────────────
      # Versioned names only, so whatever owns `python3` keeps owning it: the
      # base image's 3.12 in a pod, Nix 3.12 on WSL. `uv venv -p 3.10` finds
      # these on PATH; UV_PYTHON_DOWNLOADS=never stops it reaching for the
      # network when asked for one that is not here.
      uv
      pbs310
    ]
    # WSL already has 3.11 from nixpkgs (above), and two python3.11 on one
    # PATH is a coin toss about which one a venv gets built on.
    ++ lib.optionals (!cfg.python.enable) [ pbs311 ];
}
