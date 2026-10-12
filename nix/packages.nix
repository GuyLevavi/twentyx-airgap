# The package set, selected with plain wsl/nvim booleans. Built on the
# connected machine; the closure crosses the gap, nothing evaluates Nix in it.
{
  lib,
  pkgs,
  inputs,
  wsl,
  nvim,
}:
let
  # nixpkgs patchelf's bun, and `bun build --compile` recycles the moved
  # PT_GNU_STACK slot so the highest-vaddr PT_LOAD lands first; Linux <= 6.6
  # never maps the BSS. fix-phdr-order reorders and fails the build if unsafe.
  fixPhdrOrder = pkgs.runCommand "fix-phdr-order" {
    nativeBuildInputs = [ pkgs.python3 ];
  } ''
    install -Dm755 ${./scripts/fix-phdr-order.py} $out/bin/fix-phdr-order
    patchShebangs $out/bin/fix-phdr-order
  '';

  opencodeFixed = pkgs.opencode.overrideAttrs (old: {
    nativeBuildInputs = old.nativeBuildInputs ++ [ fixPhdrOrder ];
    postFixup = (old.postFixup or "") + ''
      fix-phdr-order $out/bin/.opencode-wrapped
    '';
  });

  # fish's only use of python is the unreachable fish_config UI (209 MB).
  fishNoPython = pkgs.fish.override { usePython = false; };

  # One declaration of every language server: PATH for fish, nvim, the Zed
  # server, the VS Code pins and opencode's spawn-by-name.
  lspPackages = with pkgs; [
    basedpyright
    ruff
    nixd
    nixfmt
    bash-language-server
    yaml-language-server
    taplo
    package-version-server
    vscode-langservers-extracted
    tombi
  ];

  shared = with pkgs; [
    # ── core CLI ───────────────────────────────────────────────────────────
    fd
    gitMinimal
    delta
    lazygit
    jq
    yq-go
    btop
    dust
    sd
    tree
    file
    less

    # ── offline documentation ──────────────────────────────────────────────
    man-pages
    man-pages-posix
    glow

    # ── terminal ───────────────────────────────────────────────────────────
    ncurses # infocmp must be on PATH for fish's TERM clamp to work

    # ── debugging what already bit you ─────────────────────────────────────
    strace
    lsof
    binutils
    patchelf
    psmisc
    procs

    # ── TLS / patching / networking ────────────────────────────────────────
    openssl
    patch
    curl
    dnsutils
    iproute2
    socat
    xh

    # ── agent ──────────────────────────────────────────────────────────────
    opencodeFixed

    # ── daily drivers ──────────────────────────────────────────────────────
    yazi
    lazydocker
    podman-compose
    gcc
    nodejs
    bubblewrap

    # ── cluster / object storage clients (both targets) ────────────────────
    minio-client # mc
    openshift # oc

    # ── data ───────────────────────────────────────────────────────────────
    sqlite
    jless

    # ── archives / transfer ────────────────────────────────────────────────
    rsync
    zstd
    unzip
    p7zip
    pv

    # ── shell hygiene ──────────────────────────────────────────────────────
    shfmt
    glab

    # ── shell programs ─────────────────────────────────────────────────────
    bat
    eza
    ripgrep
    fishNoPython
    starship
    zoxide
    fzf
    atuin
    direnv
    tmux

    inputs.workmux.packages.${pkgs.stdenv.hostPlatform.system}.default
  ]
  ++ lspPackages
  ++ lib.optionals nvim [ pkgs.neovim ]
  ++ lib.optionals (!nvim) [ pkgs.nano ]
  ++ lib.optionals wsl [
    # ── cluster + image pipeline (you drive the cluster from WSL) ──────────
    pkgs.kubectl
    pkgs.k9s
    pkgs.kubectx
    pkgs.stern
    pkgs.kubernetes-helm
    pkgs.go-containerregistry
    pkgs.skopeo
    pkgs.dive

    # ── Nix development ────────────────────────────────────────────────────
    pkgs.statix
    pkgs.deadnix
    pkgs.nix-tree

    # ── Python: WSL only; the pytorch bases own torch and CUDA ─────────────
    pkgs.python312
    pkgs.uv

    # Obsidian-style markdown LSP for the vault.
    pkgs.markdown-oxide
  ]
  ++ lib.optionals (!wsl) [
    # ── RunAI pod only; WSL gets these from the NixOS system ───────────────
    pkgs.podman
    pkgs.nginx
    pkgs.openssh
    pkgs.code-server
    pkgs.sudo
    pkgs.nvtopPackages.nvidia
  ];
in
shared
