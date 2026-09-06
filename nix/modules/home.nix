# The single source of truth for both targets.
#
# Evaluated twice: once inside nixosConfigurations.wsl (as a home-manager user
# module) and once standalone as homeConfigurations.runai, whose build products
# are extracted into an OCI layer by nix/runai/layer.nix. Nix never runs in a
# pod, so anything that needs Nix at runtime must be guarded by
# `cfg.target == "wsl"`.
{
  lib,
  pkgs,
  config,
  inputs,
  ...
}:
let
  cfg = config.airgap;

  # Full glibcLocales is 222 MB of closure for locales nobody uses; trimmed to
  # the two we actually need it is 3 MB. Measured, not guessed.
  locales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [
      "en_US.UTF-8/UTF-8"
      "C.UTF-8/UTF-8"
    ];
  };
in
{
  imports = [
    # Always imported; nvim.nix gates it on airgap.nvim.enable, because
    # `imports` cannot depend on config without infinite recursion.
    inputs.lazyvim.homeManagerModules.default
    ./shell.nix
    ./tools.nix
    ./nvim.nix
  ];

  options.airgap = {
    target = lib.mkOption {
      type = lib.types.enum [
        "wsl"
        "runai"
      ];
      description = ''
        Which side of the airgap this evaluation is for. `wsl` is a real NixOS
        system that can rebuild offline; `runai` is a read-only tree baked into
        a container layer, with no Nix present at runtime.
      '';
    };

    nvim.enable = lib.mkOption {
      type = lib.types.bool;
      default = true;
      description = ''
        LazyVim with curated treesitter grammars and LSPs. ~750 MB of closure,
        which is why the RunAI side builds it as a separate image flavor.
      '';
    };

    python.enable = lib.mkOption {
      type = lib.types.bool;
      default = cfg.target == "wsl";
      description = ''
        Nix-provided CPython. WSL only, deliberately: on the *-pytorch RunAI
        bases the system python owns torch and CUDA, and a second interpreter
        there would shadow it while being unable to see any of it.
      '';
    };

    tools = {
      cluster.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.target == "wsl";
        description = "kubectl/k9s/stern/helm and the image pipeline (crane, skopeo, dive).";
      };
      gpu.enable = lib.mkOption {
        type = lib.types.bool;
        default = cfg.target == "runai";
        description = "nvtop — only meaningful where there is a GPU to watch.";
      };
      data.enable = lib.mkOption {
        type = lib.types.bool;
        default = false;
        description = "visidata. 1.38 GB of closure; opt in on WSL only.";
      };
    };

    git = {
      userName = lib.mkOption {
        type = lib.types.str;
        default = "guy";
      };
      userEmail = lib.mkOption {
        type = lib.types.str;
        default = "guylevavi@gmail.com";
        description = "TODO: set the work address for the airgapped targets.";
      };
    };
  };

  config = {
    home.stateVersion = "25.05";
    programs.home-manager.enable = cfg.target == "wsl";

    # ── Environment that a foreign container does not provide ────────────
    # On NixOS these are set by the system. In a RunAI pod nothing sets them,
    # and their absence is the difference between a working terminal and a
    # monochrome one that mangles every multibyte glyph.
    home.sessionVariables = {
      # The slim bases ship a minimal /usr/share/terminfo that has neither
      # tmux-256color nor wezterm. Without this, tmux refuses to start and nvim
      # degrades to a dumb terminal.
      TERMINFO_DIRS = lib.concatStringsSep ":" [
        "${pkgs.ncurses}/share/terminfo"
        "${pkgs.wezterm.terminfo}/share/terminfo"
        "/usr/share/terminfo"
        "/etc/terminfo"
      ];

      # kubectl exec forwards TERM from the client but never COLORTERM, so
      # truecolor detection fails and LazyVim falls back to 16 colours.
      COLORTERM = "truecolor";

      EDITOR = "nvim";
      VISUAL = "nvim";
      PAGER = "less";
      LESS = "-FRX";

      # uv cannot download interpreters in an airgap; make it fail loudly and
      # immediately rather than hanging on a DNS lookup that cannot resolve.
      UV_PYTHON_DOWNLOADS = "never";
      PIP_DEFAULT_TIMEOUT = "10";
      GIT_TERMINAL_PROMPT = "0";
    }
    // lib.optionalAttrs (cfg.target == "runai") {
      # Nix binaries consult LOCALE_ARCHIVE; a foreign container has none, and
      # fish then warns on every start and mangles Nerd Font glyphs. The full
      # glibcLocales is 222 MB — this trimmed build is 3 MB.
      LOCALE_ARCHIVE = "${locales}/lib/locale/locale-archive";
      LANG = "en_US.UTF-8";
    };

    programs.git = {
      enable = true;
      package = pkgs.gitMinimal; # full git is 385 MB of closure; this is 159
      settings = {
        user.name = cfg.git.userName;
        user.email = cfg.git.userEmail;
        init.defaultBranch = "main";
        pull.rebase = true;
        core.editor = "nvim";
      };
    };

    programs.delta = {
      enable = true;
      enableGitIntegration = true;
    };
    programs.lazygit.enable = true;
  };
}
