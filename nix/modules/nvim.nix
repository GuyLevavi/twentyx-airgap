# LazyVim, declaratively, with every plugin and grammar a store path.
#
# Nothing here may reach the network at runtime: no lazy.nvim bootstrap clone,
# no :TSInstall compile, no Mason. lazyvim-nix resolves the whole plugin set at
# build time, which is the only reason LazyVim is viable behind an airgap at
# all.
{
  lib,
  pkgs,
  config,
  ...
}:
let
  cfg = config.airgap;
in
{
  config = lib.mkIf cfg.nvim.enable {
    programs.lazyvim = {
      enable = true;

      extras = {
        lang.nix.enable = true;
        lang.python = {
          enable = true;
          # Both of these pull their dependency sets into the closure at build
          # time, which is exactly what we want — they are the alternative to
          # Mason downloading them into a pod that has no route out.
          installDependencies = true;
          installRuntimeDependencies = true;
        };
      };

      # LazyVim's lang.nix ships no auto-installed deps: nixd and the
      # formatter/linter its extras expect on PATH are manual.
      extraPackages = with pkgs; [
        nixd
        nixfmt
        statix
        basedpyright
        ruff
        taplo # you have a manifest.toml and no TOML LSP
        lua-language-server
        bash-language-server
        yaml-language-server
        marksman
      ];
    };

    # withAllGrammars is ~1 GB. This curated set is ~40 MB and covers every
    # language in this repo and the ones you actually work in.
    programs.neovim.plugins = [
      (pkgs.vimPlugins.nvim-treesitter.withPlugins (
        p: with p; [
          nix
          lua
          python
          bash
          fish
          yaml
          json
          toml
          markdown
          markdown_inline
          dockerfile
          gitcommit
          git_config
          gitignore
          diff
          regex
          vim
          vimdoc
          c
          query
        ]
      ))
    ];

    # OSC 52 clipboard. In a RunAI pod there is no X11, no Wayland and no
    # wl-copy, so the escape-sequence path is the only route from a yank in
    # nvim to the Windows clipboard. tmux passes it through (see shell.nix) and
    # WezTerm honours it at the far end.
    programs.neovim.initLua = lib.mkAfter ''
      if vim.env.SSH_TTY or vim.env.KUBERNETES_SERVICE_HOST or vim.env.RUNAI_JOB_NAME then
        vim.g.clipboard = {
          name = "OSC 52",
          copy = {
            ["+"] = require("vim.ui.clipboard.osc52").copy("+"),
            ["*"] = require("vim.ui.clipboard.osc52").copy("*"),
          },
          -- Reading the clipboard over OSC 52 requires the emulator to answer,
          -- which many refuse to do for security. Paste from the terminal
          -- instead; a paste that silently hangs is worse than no paste.
          paste = {
            ["+"] = function() return vim.split(vim.fn.getreg('"'), "\n") end,
            ["*"] = function() return vim.split(vim.fn.getreg('"'), "\n") end,
          },
        }
      end
    '';
  };
}
