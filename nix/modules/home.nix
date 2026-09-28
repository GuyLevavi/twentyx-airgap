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
  ...
}:
let
  cfg = config.twentyx;

  # Full glibcLocales is 222 MB of closure for locales nobody uses; trimmed to
  # the two we actually need it is 3 MB. Measured, not guessed.
  locales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [
      "en_US.UTF-8/UTF-8"
      "C.UTF-8/UTF-8"
    ];
  };

  # The official opencode extension for code-server (the pod IDE). It is
  # seeded as a packaged default; the raw .vsix below rides along for a
  # machine that ever wants to sideload it manually. Version and hash are
  # pinned deliberately: a moving ref would break offline rebuilds.
  opencodeVscode = pkgs.vscode-utils.buildVscodeMarketplaceExtension {
    mktplcRef = {
      publisher = "sst-dev";
      name = "opencode";
      version = "0.0.13";
      hash = "sha256-6adXUaoh/OP5yYItH3GAQ7GpupfmTGaxkKP6hYUMYNQ=";
    };
  };

  # The raw .vsix, for `code --install-extension` on the Windows side.
  opencodeVsix = pkgs.fetchurl {
    url = "https://sst-dev.gallery.vsassets.io/_apis/public/gallery/publisher/sst-dev/extension/opencode/0.0.13/assetbyname/Microsoft.VisualStudio.Services.VSIXPackage";
    hash = "sha256-6adXUaoh/OP5yYItH3GAQ7GpupfmTGaxkKP6hYUMYNQ=";
  };

  # Zed's remote-development server, built by the same zed-editor derivation.
  # Shipping it in the closure is what makes Zed remote work offline: the
  # client looks under ~/.zed_server/ for a file named after its OWN version
  # string and only checks that it runs -- no download, ever.
  zedRemote = pkgs.zed-editor.remote_server;
  zedRemoteExecName =
    pkgs.zed-editor.remoteServerExecutableName
      or "zed-remote-server-stable-${pkgs.zed-editor.version}+stable";

  # The nixpkgs-named server binary already covers one spelling; the client
  # looks the server up under its OWN full version string — build metadata
  # included (zed crates/remote/src/transport/wsl.rs builds
  # `zed-remote-server-stable-<version.to_string()>`) — and treats the file as
  # present iff `<file> version` exits 0. The full-version shim is therefore
  # the one that actually prevents the first-connect download; the bare
  # `<nixpkgs-version>+stable` spelling stays as a fallback for clients that
  # report without build metadata. (The `.gz` name seen in client logs is a
  # PID-suffixed temporary upload, not the lookup name.)
  zedClientShims = builtins.filter (n: n != zedRemoteExecName) (
    lib.unique [
      "zed-remote-server-stable-${cfg.zed.remoteClientVersion}"
      "zed-remote-server-stable-${pkgs.zed-editor.version}+stable"
    ]
  );
in
{
  imports = [
    # Always imported; nvim.nix gates it on twentyx.nvim.enable, because
    # `imports` cannot depend on config without infinite recursion.
    ./shell.nix
    ./tools.nix
    ./nvim.nix
    ./skills.nix
  ];

  options.twentyx = {
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
        Pure nvim with curated treesitter grammars, drawing its language
        servers from the shared closure. ~48 MiB of profile closure, which is
        why the RunAI side builds it as a separate image flavor.
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

    zed.remoteClientVersion = lib.mkOption {
      type = lib.types.str;
      default = import ../zed-client-version.nix;
      description = ''
        The EXACT version string of the Zed client that will connect to this
        host remotely, INCLUDING upstream build metadata (build number + git
        sha). DEFAULT = the version of the client shipped as the pinned
        installer in .#windows-kit, from nix/zed-client-version.nix — install
        the shipped installer and this matches by construction, no manual
        step. Re-pin in lockstep whenever the kit's Zed moves: take the string
        verbatim from the client log line `starting zed version ...` on first
        connect. The lookup is exact-match on this string (the remote-server
        download path in zed), so a bare semver like `1.17.2` misses and the
        client downloads its own server instead.
      '';
    };
  };

  config = {
    home.stateVersion = "25.05";
    programs.home-manager.enable = cfg.target == "wsl";

    # home-manager's reference man page drags a full python3 + nixos-render-docs
    # into BOTH closures for documentation nobody reads offline. ~133 MB.
    manual.manpages.enable = false;

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
      # truecolor detection fails and nvim falls back to 16 colours.
      COLORTERM = "truecolor";

      # The plain pod flavor has no nvim — an $EDITOR pointing at it would
      # fail the first `git commit` at the worst moment. nano is 2 MB.
      EDITOR = if cfg.nvim.enable then "nvim" else "nano";
      VISUAL = if cfg.nvim.enable then "nvim" else "nano";
      PAGER = "less";
      LESS = "-FRX";

      # uv cannot download interpreters in an airgap; make it fail loudly and
      # immediately rather than hanging on a DNS lookup that cannot resolve.
      UV_PYTHON_DOWNLOADS = "never";
      PIP_DEFAULT_TIMEOUT = "10";
      GIT_TERMINAL_PROMPT = "0";

      # The models.dev catalog is baked into the binary at build time; fetching
      # it at runtime is a hang in the airgap, not an error.
      OPENCODE_DISABLE_MODELS_FETCH = "true";
    }
    // lib.optionalAttrs (cfg.target == "runai") {
      # Nix binaries consult LOCALE_ARCHIVE; a foreign container has none, and
      # fish then warns on every start and mangles Nerd Font glyphs. The full
      # glibcLocales is 222 MB — this trimmed build is 3 MB.
      LOCALE_ARCHIVE = "${locales}/lib/locale/locale-archive";
      LANG = "en_US.UTF-8";
    };

    # ── git: the binary and NOTHING else ──────────────────────────────────
    # Deliberately no packaged ~/.config/git/config: it would be a store
    # symlink, and `git config --global user.email` on the PVC would then
    # try to write through it and fail. The neutral settings (defaultBranch,
    # pager, delta) ship as /etc/gitconfig instead — from the repo layer in a
    # pod, from environment.etc on WSL — and every user owns
    # ~/.config/git/config as a real, durable, editable file. Identity in a
    # pod comes from the workspace-name convention (session_user in
    # common.sh), never from a baked email: this closure is
    # distributed to a team.
    home.packages = [ pkgs.gitMinimal ];

    # All packaged defaults in one merge. Each entry is a per-file symlink:
    # bootstrap links it into $HOME only when no real file is there, and the
    # repo layer can override any single one per commit (overlayfs merges
    # directories across layers).
    home.file = lib.mkMerge [
      # The preload plugin is OUR fix, not user config: riding home-defaults
      # means bootstrap keeps it fresh across images unless the user
      # deliberately overrides it with a real file.
      {
        ".config/opencode/plugins/preload.ts".source = ../../agent/plugins/preload.ts;
      }

      # Editor integration. code-server (the pod's IDE) scans this dir, so a
      # symlinked store path is enough. The user's own opencode.json is NOT
      # packaged: the working config already lives on the PVC, and a real
      # file there would shadow this anyway.
      {
        ".local/share/code-server/extensions/sst-dev.opencode".source = opencodeVscode;
        ".local/share/vsix/sst-dev.opencode-0.0.13.vsix".source = opencodeVsix;
      }

      # Zed: agent integration through opencode's ACP mode, plus the
      # language-server wiring that keeps the airgap honest: without the
      # per-language overrides Zed falls back to fetching its own servers at
      # runtime. Measured on the connected laptop (Zed.log, 2026-09-26): with
      # the pins shadowed, Zed downloaded Node.js from nodejs.org, the
      # basedpyright npm package and the ruff release tarball from GitHub;
      # with the pins in effect nothing appears under
      # ~/.local/share/zed/{node,languages} and the nix binaries serve.
      # The servers themselves come from nix/modules/lsp.nix (the same list
      # fish, nvim and the opencode PATH see).
      #
      # The personal look lives in the tracked zed-settings.json next to the
      # flake, but the pins CANNOT live in a static file: store paths move
      # when nixpkgs moves, and a hardcoded /nix/store path would silently
      # point at something the next transfer does not carry. So the shipped
      # settings are composed here -- personal file first, dynamic pins over
      # it -- and are a per-file symlink like every other packaged default.
      # bootstrap never clobbers a real settings.json on the PVC; merge the
      # lsp/languages blocks into yours by hand if you already configured
      # Zed (check with `ls -l ~/.config/zed/settings.json`: a symlink is
      # ours, a real file is yours and wins).
      (
        let
          zedSettingsFile = ../../zed-settings.json;
          # Strict JSON (builtins.fromJSON): no comments in that file.
          personal =
            if builtins.pathExists zedSettingsFile
            then builtins.fromJSON (builtins.readFile zedSettingsFile)
            else { };
          airgap = {
            agent_servers = {
              "OpenCode" = {
                "type" = "custom";
                "command" = "opencode";
                "args" = [ "acp" ];
              };
            };
            # Pin every language server to its closure path.
            lsp = {
              nixd.binary.path = "${pkgs.nixd}/bin/nixd";
              basedpyright.binary.path = "${pkgs.basedpyright}/bin/basedpyright-langserver";
              ruff.binary.path = "${pkgs.ruff}/bin/ruff";
              # Zed's built-in JSON support npm-installs
              # vscode-langservers-extracted by default; this is the
              # closure build of the same server.
              json-language-server.binary.path = "${pkgs.vscode-langservers-extracted}/bin/vscode-json-language-server";
              bash-language-server = {
                binary.path = "${pkgs.bash-language-server}/bin/bash-language-server";
                binary.arguments = [ "start" ];
              };
              yaml-language-server = {
                binary.path = "${pkgs.yaml-language-server}/bin/yaml-language-server";
                binary.arguments = [ "--stdio" ];
                # yaml-language-server fetches schemas from schemastore.org
                # for every YAML file by default -- a hang per file behind
                # the gap. Validation still works from inlined $schema and
                # the settings below.
                settings.yaml.schemaStore.enable = false;
              };
              # TOML: the toml extension is syntax-only now; Tombi is Zed's
              # TOML server (taplo remains nvim's).
              tombi = {
                binary.path = "${pkgs.tombi}/bin/tombi";
                binary.arguments = [ "lsp" ];
              };
            };
            # Prettier is downloaded through node when a language that
            # defaults to it (JSON/JS/TS/HTML/Markdown) is formatted.
            # Nothing in this toolchain uses it; the language servers
            # format instead. Measured: "Installing default prettier and
            # plugins" in the client log.
            prettier.allowed = false;
            languages = {
              Nix.language_servers = [
                "nixd"
                "!nil"
              ];
              Python = {
                language_servers = [
                  "basedpyright"
                  "!pyright"
                  "ruff"
                ];
                formatter.language_server.name = "ruff";
              };
            };
            # Terminal Threads (agent panel -> New Thread -> Terminal):
            # the TUI, not ACP -- starts opencode in the shell the thread
            # creates. The agent_servers entry above stays for the panel.
            agent.terminal_init_command = "opencode";
            auto_update = false;
            telemetry = {
              metrics = false;
              diagnostics = false;
            };
          };
          # Personal keys win; `agent` is merged so the personal panel
          # styling and our terminal_init_command coexist; `lsp` is ours
          # outright (a stale personal lsp block was the bug this fixes).
          merged = airgap // personal // {
            agent = airgap.agent // (personal.agent or { });
            lsp = airgap.lsp;
          };
        in
        {
          ".config/zed/settings.json".text = builtins.toJSON merged + "\n";
        }
      )

      # btop: a themed default instead of the stock black. The theme file
      # ships inside the closure's btop package (share/btop/themes);
      # theme_background = false keeps the terminal's own background, which is
      # the "inherit from the terminal" behavior. Replace with a real file to
      # customise -- packaged defaults never win over the user's own.
      {
        ".config/btop/btop.conf".text = ''
          color_theme = "tokyo-night"
          theme_background = false
        '';
      }

      # Zed remote development, fully declared. The server binary ships
      # under its nixpkgs name; shims with the filenames a client looks for
      # exec it. The default client version matches the nixpkgs release --
      # the same release the shipped Windows installer (.#windows-kit) is
      # pinned to -- so using the shipped installer means connecting needs
      # zero manual steps. Packaged defaults: overridable, never fetched.
      {
        ".zed_server/${zedRemoteExecName}".source = "${zedRemote}/bin/${zedRemoteExecName}";
      }
      (lib.listToAttrs (
        map (name: {
          name = ".zed_server/${name}";
          value = {
            executable = true;
            text = ''
              #!/bin/sh
              # Packaged default: the client requires this exact filename (its
              # own version string) and only checks that "<file> version"
              # exits 0 -- it never downloads.
              exec "${zedRemote}/bin/${zedRemoteExecName}" "$@"
            '';
          };
        }) zedClientShims
      ))
    ];
  };
}
