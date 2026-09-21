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
    # Hash re-pinned 2026-09: the v2.3 release asset was re-uploaded upstream,
    # so the old pin no longer matches what GitHub serves. Content is still
    # the tldr pages; the closure pins whatever this hash describes.
    url = "https://github.com/tldr-pages/tldr/releases/download/v2.3/tldr-pages.en.zip";
    hash = "sha256-EKNWCMVrbWTIdrXLnzDuqbyLawp/0uNKggiyeG2GZSA=";
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

      # ── agent ──────────────────────────────────────────────────────────
      # opencode from nixpkgs is built from source (bun --compile): autoupdate
      # is disabled by the wrapper and the models.dev catalog is baked in at
      # build time, so it runs fully offline. One caveat that cannot be seen
      # from here: the compiled binary targets x86-64-v3 (AVX2) and will SIGILL
      # on pre-Haswell cluster nodes -- if a node ever dies this way, the fix
      # is a local overlay building the --baseline variant, not a downgrade.
      opencode
      # Terminal multiplexer for agent sessions; sessions outlive their SSH
      # exec, state per pane.
      herdr
      # GUI editor (WSLg); its headless value is the agent integration via
      # `opencode acp` (packaged settings default) and, over the sshd -i
      # bridge, remote sessions into a pod.
      zed-editor

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
    ++ lib.optionals (!wsl) [
      # ── RunAI pod only ─────────────────────────────────────────────────
      # WSL gets these from the system (NixOS), a pod has to carry them.
      #
      # podman works both sides of the gap: on WSL via virtualisation.podman,
      # in a pod via the storage.conf that airgap-bootstrap writes into the
      # ephemeral cache (vfs driver -- no mount(2), no CAP_SYS_ADMIN needed).
      podman
      # RunAI's port-exposure machinery expects an nginx in the workspace; the
      # pytorch bases ship one, slim-based assemblies get it from here so
      # presence does not depend on the base. Its site config, when the exact
      # RunAI contract is pinned down, belongs in the env-injection mount (see
      # airgap_injection_exports in libexec/airgap-common.sh).
      nginx
      # sshd for the sshd -i bridge (libexec/airgap-sshd-inetd): Zed/SSH into
      # a pod with no exposed SSH port. On WSL this comes from the system.
      openssh
      # The runtime user (uid 10001, gid 0) elevates through the sudoers file
      # shipped in the repo layer; docker/mklayer.sh adds the setuid copy.
      # On NixOS sudo is a system setuid wrapper, so this is pod-only.
      sudo
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
