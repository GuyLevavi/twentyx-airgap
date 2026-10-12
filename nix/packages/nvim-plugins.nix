# The nvim plugin tree, built by Nix and consumed by lazy.nvim through its
# `dev` mechanism: every plugin resolves to $out/<name>, nothing is fetched.
#
# The derivation also runs a headless nvim check in the Nix sandbox (no
# network): if any spec is missing, a parser is absent or an LSP binary is not
# on PATH, the build fails instead of the airgap session failing.
{
  lib,
  pkgs,
}:
let
  # Plugin name (what lazy.nvim derives from the repo URL, or the spec's
  # explicit name) -> nixpkgs attribute.
  pluginAttrs = {
    "LazyVim" = pkgs.vimPlugins.LazyVim;
    "lazy.nvim" = pkgs.vimPlugins.lazy-nvim;
    "snacks.nvim" = pkgs.vimPlugins.snacks-nvim;
    "blink.cmp" = pkgs.vimPlugins.blink-cmp;
    "blink.compat" = pkgs.vimPlugins.blink-compat;
    "friendly-snippets" = pkgs.vimPlugins.friendly-snippets;
    "nvim-cmp" = pkgs.vimPlugins.nvim-cmp;
    "bufferline.nvim" = pkgs.vimPlugins.bufferline-nvim;
    "lualine.nvim" = pkgs.vimPlugins.lualine-nvim;
    "noice.nvim" = pkgs.vimPlugins.noice-nvim;
    "nui.nvim" = pkgs.vimPlugins.nui-nvim;
    "mini.icons" = pkgs.vimPlugins.mini-icons;
    "mini.ai" = pkgs.vimPlugins.mini-ai;
    "mini.pairs" = pkgs.vimPlugins.mini-pairs;
    "which-key.nvim" = pkgs.vimPlugins.which-key-nvim;
    "gitsigns.nvim" = pkgs.vimPlugins.gitsigns-nvim;
    "trouble.nvim" = pkgs.vimPlugins.trouble-nvim;
    "todo-comments.nvim" = pkgs.vimPlugins.todo-comments-nvim;
    "flash.nvim" = pkgs.vimPlugins.flash-nvim;
    "grug-far.nvim" = pkgs.vimPlugins.grug-far-nvim;
    "persistence.nvim" = pkgs.vimPlugins.persistence-nvim;
    "plenary.nvim" = pkgs.vimPlugins.plenary-nvim;
    "conform.nvim" = pkgs.vimPlugins.conform-nvim;
    "nvim-lint" = pkgs.vimPlugins.nvim-lint;
    "nvim-lspconfig" = pkgs.vimPlugins.nvim-lspconfig;
    "lazydev.nvim" = pkgs.vimPlugins.lazydev-nvim;
    "nvim-treesitter" = pkgs.vimPlugins.nvim-treesitter;
    "nvim-treesitter-textobjects" = pkgs.vimPlugins.nvim-treesitter-textobjects;
    "nvim-ts-autotag" = pkgs.vimPlugins.nvim-ts-autotag;
    "ts-comments.nvim" = pkgs.vimPlugins.ts-comments-nvim;
    "tokyonight.nvim" = pkgs.vimPlugins.tokyonight-nvim;
    "catppuccin" = pkgs.vimPlugins.catppuccin-nvim;
    "SchemaStore.nvim" = pkgs.vimPlugins.SchemaStore-nvim;
    "venv-selector.nvim" = pkgs.vimPlugins.venv-selector-nvim;
    "mason.nvim" = pkgs.vimPlugins.mason-nvim;
    "mason-lspconfig.nvim" = pkgs.vimPlugins.mason-lspconfig-nvim;
  };

  # Union of LazyVim's ensure_installed (core + the json extra) and the
  # languages this repo actually works in.
  grammarNames = [
    "bash"
    "c"
    "diff"
    "dockerfile"
    "fish"
    "gitcommit"
    "git_config"
    "gitignore"
    "html"
    "javascript"
    "jsdoc"
    "json"
    "json5"
    "lua"
    "luadoc"
    "luap"
    "markdown"
    "markdown_inline"
    "nix"
    "printf"
    "python"
    "query"
    "regex"
    "toml"
    "tsx"
    "typescript"
    "vim"
    "vimdoc"
    "xml"
    "yaml"
  ];

  treesitter = pkgs.vimPlugins.nvim-treesitter.withPlugins (p: map (n: p.${n}) grammarNames);

  # withPlugins' deps are the grammar plugins (parser/<lang>.so) and the
  # associated query plugins (queries/<lang>).
  tsDeps = treesitter.passthru.dependencies;

  pluginLinks = lib.concatMapStrings (name: ''
    ln -s ${pluginAttrs.${name}} "$out/${name}"
  '') (lib.attrNames pluginAttrs);

  parserLinks = lib.concatMapStrings (dep: ''
    for f in ${dep}/parser/*.so; do
      [ -e "$f" ] && ln -s "$f" "$out/parser/$(basename "$f")"
    done
    for q in ${dep}/queries/*; do
      [ -e "$q" ] || continue
      n="$(basename "$q")"
      [ -e "$out/queries/$n" ] || ln -s "$q" "$out/queries/$n"
    done
  '') tsDeps;

  lspForCheck = with pkgs; [
    basedpyright
    ruff
    nixd
    nixfmt
    bash-language-server
    yaml-language-server
    vscode-langservers-extracted
    taplo
    tombi
    package-version-server
  ];
in
pkgs.runCommand "twentyx-nvim-plugins"
  {
    nativeBuildInputs = [ pkgs.neovim ] ++ lspForCheck;
    meta.description = "LazyVim plugin + treesitter parser tree for the airgap";
  }
  ''
    mkdir -p "$out/parser" "$out/queries"
    ${pluginLinks}
    ${parserLinks}

    # Offline check: run the seeded starter headless against this tree.
    export HOME="$TMPDIR/home"
    export XDG_CONFIG_HOME="$TMPDIR/config"
    export XDG_DATA_HOME="$TMPDIR/data"
    export XDG_STATE_HOME="$TMPDIR/state"
    export XDG_CACHE_HOME="$TMPDIR/cache"
    mkdir -p "$HOME" "$XDG_CONFIG_HOME" "$XDG_DATA_HOME" "$XDG_STATE_HOME" "$XDG_CACHE_HOME"
    # The spec is the inner repo's nvim config, as the outside last knew it
    # (inside-seed/): a plugin the inside wants is a REQUESTS.md line, added
    # to pluginAttrs and to that copy together.
    cp -r ${../../inside-seed/dotfiles/.config/nvim} "$XDG_CONFIG_HOME/nvim"
    export TWENTYX_NVIM_PLUGINS="$out"
    # The marker makes a hard lua error (which would exit 0) a failure too;
    # the timeout keeps a broken config from hanging the build.
    if ! timeout 120 nvim --headless -c 'luafile ${../scripts/nvim-offline-check.lua}' > "$TMPDIR/check.log" 2>&1 ||
      ! grep -q "nvim offline check OK" "$TMPDIR/check.log"; then
      cat "$TMPDIR/check.log" >&2
      exit 1
    fi
  ''
