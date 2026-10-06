# The user-level toolchain for both targets: one package profile, one session
# environment, one tree of packaged defaults. Nothing here is a home-manager
# module; the only outputs are store paths and attrsets.
{
  lib,
  pkgs,
  inputs,
  wsl,
  nvim ? false,
}:
let
  packages = import ./packages.nix {
    inherit
      lib
      pkgs
      inputs
      wsl
      nvim
      ;
  };

  # Full glibcLocales is 222 MB for locales nobody uses; the two we need are 3 MB.
  locales = pkgs.glibcLocales.override {
    allLocales = false;
    locales = [
      "en_US.UTF-8/UTF-8"
      "C.UTF-8/UTF-8"
    ];
  };

  # Zed's remote server: the client looks under ~/.zed_server/ for a file named
  # after its OWN full version string (build metadata included) and only checks
  # that it runs. One entry, no shims.
  zedRemote = pkgs.zed-editor.remote_server;
  zedRemoteExecName =
    pkgs.zed-editor.remoteServerExecutableName
      or "zed-remote-server-stable-${pkgs.zed-editor.version}+stable";
  zedClientVersion = import ./zed-client-version.nix;

  # The official opencode extension for code-server. Version and hash pinned:
  # a moving ref would break offline rebuilds.
  opencodeVscode = pkgs.vscode-utils.buildVscodeMarketplaceExtension {
    mktplcRef = {
      publisher = "sst-dev";
      name = "opencode";
      version = "0.0.13";
      hash = "sha256-6adXUaoh/OP5yYItH3GAQ7GpupfmTGaxkKP6hYUMYNQ=";
    };
  };

  # opencode's loader npm-installs @opencode-ai/plugin in every config dir at
  # startup; with no registry that is a ~1.5 min TUI stall. It is skipped when
  # node_modules exists and the dependency is a root dependency in the lock.
  # ponytail: frozen at @opencode-ai/plugin; re-check when opencode bumps.
  packageLock = pkgs.writeText "opencode-package-lock.json" (
    builtins.toJSON {
      name = "opencode";
      lockfileVersion = 3;
      requires = true;
      packages."".dependencies."@opencode-ai/plugin" = pkgs.opencode.version;
    }
  );

  # The LazyVim plugin + parser tree. Only the nvim flavor carries it; the
  # plain pod flavor gets an empty dir so the layer shape is stable.
  nvimPlugins =
    if nvim then
      import ./packages/nvim-plugins.nix { inherit lib pkgs; }
    else
      pkgs.runCommand "twentyx-nvim-plugins" { } "mkdir -p $out";

  # Agent skills, vendored from the pinned input. Upstream's marketplace.json
  # only lists its shipped set; these siblings are Claude/git-hook machinery
  # opencode cannot run.
  skillsRoot = "${inputs.matt-skills}/skills";
  reject = [
    "deprecated"
    "in-progress"
    "misc"
  ];
  dirsIn =
    path:
    builtins.attrNames (lib.filterAttrs (_: type: type == "directory") (builtins.readDir path));
  skillPaths = lib.concatMap (
    category:
    map (name: {
      inherit name;
      path = "${skillsRoot}/${category}/${name}";
    }) (dirsIn "${skillsRoot}/${category}")
  ) (builtins.filter (category: !(builtins.elem category reject)) (dirsIn skillsRoot));
in
{
  # A buildEnv of the whole package set. On WSL it is folded into the system
  # profile; in a pod it is the layer's /opt/twentyx/profile.
  profile = pkgs.buildEnv {
    name = "twentyx-profile";
    paths = packages;
  };

  # Session variables become image ENV in a pod (assemble.sh) and
  # environment.sessionVariables on WSL: shell rc files reach only shells, and
  # `runai exec`/code-server never source one.
  sessionEnv = {
    TERMINFO_DIRS = lib.concatStringsSep ":" [
      "${pkgs.ncurses}/share/terminfo"
      "${pkgs.wezterm.terminfo}/share/terminfo"
      "/usr/share/terminfo"
      "/etc/terminfo"
    ];
    COLORTERM = "truecolor";
    EDITOR = if nvim then "nvim" else "nano";
    VISUAL = if nvim then "nvim" else "nano";
    PAGER = "less";
    LESS = "-FRX";

    # Runtime fetches are hangs in the gap, not errors.
    UV_PYTHON_DOWNLOADS = "never";
    PIP_DEFAULT_TIMEOUT = "10";
    GIT_TERMINAL_PROMPT = "0";
    OPENCODE_DISABLE_MODELS_FETCH = "true";
    OPENCODE_DISABLE_LSP_DOWNLOAD = "true";
    OPENCODE_DISABLE_DEFAULT_PLUGINS = "true";
    OPENCODE_DISABLE_SHARE = "true";
  }
  // lib.optionalAttrs nvim {
    # lazy.nvim's dev root: every spec and the treesitter parsers resolve here.
    TWENTYX_NVIM_PLUGINS = "${nvimPlugins}";
  }
  // lib.optionalAttrs (!wsl) {
    LOCALE_ARCHIVE = "${locales}/lib/locale/locale-archive";
    LANG = "en_US.UTF-8";
  };

  # A directory of store symlinks we own. seed-home refreshes these into $HOME
  # on every start; a real file at the same path is the user's and is never
  # touched.
  homeDefaults = pkgs.runCommand "twentyx-home-defaults" { } ''
    mkdir -p "$out/.zed_server"
    ln -s ${zedRemote}/bin/${zedRemoteExecName} \
      "$out/.zed_server/zed-remote-server-stable-${zedClientVersion}"

    mkdir -p "$out/.config/opencode/plugins"
    ln -s ${../agent/plugins/preload.ts} "$out/.config/opencode/plugins/preload.ts"
    ln -s ${inputs.workmux}/resources/opencode/plugins/workmux-status.ts \
      "$out/.config/opencode/plugins/workmux-status.ts"

    mkdir -p "$out/.config/opencode/node_modules"
    touch "$out/.config/opencode/node_modules/.keep"
    cp ${packageLock} "$out/.config/opencode/package-lock.json"

    mkdir -p "$out/.config/opencode/skills"
    ${lib.concatMapStrings (s: ''
      ln -s ${s.path} "$out/.config/opencode/skills/${s.name}"
    '') skillPaths}

    mkdir -p "$out/.local/share/code-server/extensions" "$out/.local/share/vsix"
    ln -s ${opencodeVscode} "$out/.local/share/code-server/extensions/sst-dev.opencode"
    ln -s ${opencodeVscode.src} "$out/.local/share/vsix/sst-dev.opencode-0.0.13.vsix"
  '';

  # Built in Phase 3; an empty dir keeps the layer shape stable until then.
  nvimPlugins = pkgs.runCommand "twentyx-nvim-plugins" { } "mkdir -p $out";
}
