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

  # tealdeer downloads its page cache on first use. Inside the gap that is not
  # an error, it is a DNS lookup that hangs -- so the pages have to be a store
  # path, fetched here on the connected machine and carried across like
  # everything else. This is the shape the old manifest.toml was reaching for,
  # except Nix pins the hash and puts it in the closure automatically.
  tldrPages = pkgs.fetchzip {
    url = "https://github.com/tldr-pages/tldr/releases/download/v2.3/tldr-pages.en.zip";
    hash = "sha256-v71Vc/Lv7zBhncoLqQOFYdcnthCmuKpE90qMKBkUlRc=";
    stripRoot = false;
  };

  # tealdeer looks for `<cache_dir>/tldr-pages/pages.<lang>/<platform>/`.
  # Only the two platforms that can ever match: the archive also carries
  # android, osx, freebsd, netbsd, openbsd, sunos, dos and cisco-ios pages,
  # none of which will ever be looked up from a Linux container.
  tldrCache = pkgs.runCommand "tldr-cache" { } ''
    mkdir -p $out/tldr-pages/pages.en
    cp -r ${tldrPages}/common ${tldrPages}/linux $out/tldr-pages/pages.en/
  '';
in
{
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
      # python310 is gone from nixpkgs (past EOL, removed upstream); 3.11 and
      # 3.12 are what remain of what you asked for.
      # Two interpreters cannot both own `python3` and `lib/libpython3.so` in
      # one profile, so the older one is lowPrio: buildEnv then resolves every
      # conflicting file in favour of 3.12, while `python3.11` stays on PATH
      # under its versioned name for `uv venv --python 3.11`.
      python312
      (lib.lowPrio python311)
      uv
      ruff
    ];
}
