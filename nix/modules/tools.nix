# The package set. Grouped by what the group is *for*, because the deciding
# question for every entry is "will I need this at 2am with no internet".
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.twentyx;
  wsl = cfg.target == "wsl";

  # One declaration for every editor — see nix/modules/lsp.nix.
  lspPackages = import ./lsp.nix { inherit pkgs; };

  # opencode ships only ripgrep on its PATH (nixpkgs opencode/package.nix),
  # so its `lsp` config would fall back to runtime downloads — a hang in the
  # gap. Re-wrap the existing binary with the shared servers on PATH; the
  # symlinkJoin avoids an overrideAttrs source rebuild. Same shape as
  # /etc/nixos home/programs.nix.
  opencodeWithLsp = pkgs.symlinkJoin {
    name = "opencode-${pkgs.opencode.version}";
    paths = [ pkgs.opencode ];
    nativeBuildInputs = [ pkgs.makeWrapper ];
    postBuild = ''
      wrapProgram $out/bin/opencode \
        --prefix PATH : ${pkgs.lib.makeBinPath lspPackages}
    '';
  };
in
{
  programs.bat.enable = true;
  programs.eza.enable = true;
  programs.ripgrep.enable = true;

  home.packages =
    with pkgs;
    [
      # ── core CLI ───────────────────────────────────────────────────────
      fd
      # gitMinimal, not full git: 159 MB of closure vs 385. The neutral git
      # settings ship as /etc/gitconfig (repo layer / environment.etc); there
      # is deliberately NO packaged ~/.config/git/config — it would be a
      # store symlink, and `git config --global user.email` on the PVC could
      # then never write (EROFS through the symlink). Every user owns their
      # git identity as a real file on the durable home.
      gitMinimal
      delta
      lazygit
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

      # ── terminal ───────────────────────────────────────────────────────
      # infocmp MUST be on PATH in the pod: fish clamps every unknown TERM to
      # xterm-256color when it cannot probe, silently defeating the shipped
      # wezterm/tmux-256color terminfo, and doctor counts it as a
      # failure. ncurses is already in the closure via TERMINFO_DIRS — this
      # only puts its bin/ on PATH. Zero closure growth.
      ncurses

      # ── debugging what already bit you ─────────────────────────────────
      # The LD_PRELOAD hunt in NOTES.md and the OpenCode microarchitecture
      # segfault were both ten-minute problems with these present.
      strace
      lsof
      binutils # readelf, objdump — "why does this binary not start"
      patchelf
      psmisc
      procs

      # ── TLS debugging ──────────────────────────────────────────────────
      # openssl is in the closure transitively; the CLI is what turns
      # "endpoint not reachable" into a diagnosis against the injected CA.
      openssl

      # ── patching ───────────────────────────────────────────────────────
      # git apply covers git-generated patches; distro/vendored patches and
      # some pip build flows want the real thing, and slim bases omit it.
      patch

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
      # Shipped wrapped so its LSPs spawn the shared closure binaries by name.
      opencodeWithLsp
      # Terminal multiplexer for agent sessions; sessions outlive their SSH
      # exec, state per pane.
      herdr

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
      # shellcheck is deliberately absent: CI lints in its own image and the
      # connected machine reaches it via `nix shell nixpkgs#shellcheck`.
      # just/hyperfine/watchexec/git-lfs/moreutils went the same way -- no
      # script in this repo referenced them.
      shfmt
      glab # you are on GitLab and had vendored gh
    ]
    # ── language servers: declared, not downloaded ──────────────────────
    # One list for every consumer (fish PATH, nvim, the Zed server, and the
    # opencode PATH wrap above). The list and its rationale live in
    # nix/modules/lsp.nix — add a server there, not here.
    ++ (import ./lsp.nix { inherit pkgs; })
    ++ lib.optionals (!cfg.nvim.enable) [
      # The plain flavor has no nvim; see EDITOR in home.nix.
      nano
    ]
    ++ lib.optionals (!wsl) [
      # ── RunAI pod only ─────────────────────────────────────────────────
      # WSL gets these from the system (NixOS), a pod has to carry them.
      #
      # podman works both sides of the gap: on WSL via virtualisation.podman,
      # in a pod via the storage.conf that bootstrap writes into the
      # ephemeral cache (vfs driver -- no mount(2), no CAP_SYS_ADMIN needed).
      podman
      # RunAI's port-exposure machinery expects an nginx in the workspace; the
      # pytorch bases ship one, slim-based assemblies get it from here so
      # presence does not depend on the base. Its site config, when the exact
      # RunAI contract is pinned down, belongs in the env-injection mount (see
      # injection_exports in libexec/common.sh).
      nginx
      # sshd for the sshd -i bridge (libexec/sshd-inetd): Zed/SSH into
      # a pod with no exposed SSH port. On WSL this comes from the system.
      openssh
      # The pod's IDE, in the closure rather than borrowed from the base:
      # slim bases have no editor at all, and the vscode-* bases' bundled
      # code-server carries its own Node build — the same
      # bundled-runtime-microarchitecture trap that SIGILL'd opencode. The
      # nixpkgs build uses a baseline Node and lands on PATH ahead of the
      # base's copy (our PATH prepend wins), so the base entrypoint launches
      # this one. The sst-dev.opencode extension is seeded in home.nix.
      code-server
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
      # ── GUI editor: REMOVED (2026-09, measured) ────────────────────────
      # zed-editor used to be here for WSLg. But the airgap WSL machine is
      # edited from the Windows Zed client (remote_server, shipped in
      # home.nix for BOTH targets) and from nvim — the local GUI only ever
      # added zed's own binary (~410 MB), mesa (~272 MB) and livekit-webrtc
      # (~198 MB) to the SYSTEM closure, which is what pushed the WSL
      # tarball over the transfer cap. Re-adding is a deliberate closure
      # decision, not a tweak.

      # ── Nix development, now that the config is Nix ────────────────────
      # Pointless in a pod: there is no Nix there to inspect.
      # (nixd/nixfmt are NOT here — they are LSP-level tools and live in the
      # shared LSP group above, where Zed in a pod also finds them.)
      statix
      deadnix
      nix-tree # how you will answer "why is this closure 700 MB"

      # Obsidian-style markdown LSP (wikilinks, backlinks, daily notes) for
      # the vault. Zed's extension resolves the binary from PATH first, so
      # this nix build is what actually runs. Vault lives on the laptop.
      markdown-oxide

      # Deliberately ABSENT, measured against the tarball (6.6 GiB system
      # closure, 2026-09): clang-tools (clangd) alone is ~1.4 GB of unpacked
      # closure — C/C++ editing loses its LSP in the airgap until someone
      # deliberately re-adds it AND re-exports the cache; python3.11 is gone
      # (uv builds pinned 3.11 venvs without a system 3.11); and zed stays
      # remote-only on WSL like in the pod — the GUI dragged mesa (272 MB),
      # livekit-webrtc (198 MB) and the GUI binary (~410 MB) into the system
      # for an editor that is reached from the Windows client anyway. The
      # remote server still ships via home.nix, both targets.
    ]
    ++ lib.optionals cfg.python.enable [
      # WSL only. See twentyx.python.enable — on the *-pytorch bases the system
      # interpreter owns torch and CUDA, and a Nix python there would shadow it
      # while being unable to see any of it.
      #
      # One interpreter: python3.12 (uv builds pinned 3.11 venvs by itself,
      # and the second interpreter was 113 MB of closure for nothing — it
      # cannot own `python3` in the same profile anyway).
      python312
      uv
      ruff
    ];
}
