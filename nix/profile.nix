# The user-level toolchain for both targets: one package profile, one session
# environment, one tree of packaged defaults. Nothing here is a home-manager
# module; the only outputs are store paths and attrsets.
{
  lib,
  pkgs,
  inputs,
  wsl,
}:
let
  packages = import ./packages.nix {
    inherit
      lib
      pkgs
      inputs
      wsl
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

  # The LazyVim plugin + parser tree; lazy.nvim resolves every spec here.
  nvimPlugins = import ./packages/nvim-plugins.nix { inherit lib pkgs; };

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
  # Binary-coupled files under stable names; see homeDefaults below.
  defaults = {
    # Zed looks under ~/.zed_server for its client's exact full version string.
    ".zed_server/zed-remote-server-stable-${zedClientVersion}" =
      "${zedRemote}/bin/${zedRemoteExecName}";
    # Same revision as the workmux binary; opencode.jsonc loads it by path.
    ".config/opencode/plugins/workmux-status.ts" =
      "${inputs.workmux}/resources/opencode/plugins/workmux-status.ts";
  }
  // lib.listToAttrs (
    # opencode.jsonc lists this directory in skills.paths.
    map (s: lib.nameValuePair ".config/opencode/skills/${s.name}" s.path) skillPaths
  )
  // lib.optionalAttrs (!wsl) {
    # code-server exists in pods only.
    ".local/share/code-server/extensions/sst-dev.opencode" = opencodeVscode;
    ".local/share/vsix/sst-dev.opencode-0.0.13.vsix" = opencodeVscode.src;
  };
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
    EDITOR = "nvim";
    VISUAL = "nvim";
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

    # lazy.nvim's dev root: every spec and the treesitter parsers resolve here.
    TWENTYX_NVIM_PLUGINS = "${nvimPlugins}";
  }
  // lib.optionalAttrs (!wsl) {
    LOCALE_ARCHIVE = "${locales}/lib/locale/locale-archive";
    LANG = "en_US.UTF-8";
  };

  # Binary-coupled files that change only with the closure, under stable paths
  # (/opt/twentyx/home-defaults/...). Nothing here is linked file by file:
  # opencode.jsonc points at the skills and the workmux plugin, and link-home
  # links ~/.zed_server (and the code-server extension in a pod) once -- the
  # names never change, so a transfer never touches $HOME.
  homeDefaults = pkgs.linkFarm "twentyx-home-defaults" defaults;
}
