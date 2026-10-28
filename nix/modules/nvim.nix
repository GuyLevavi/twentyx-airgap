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
        # nvim-dap, dap-ui and virtual text. lang.python then wires
        # nvim-dap-python to `debugpy-adapter` on PATH (see extraPackages).
        dap.core.enable = true;
        lang.nix.enable = true;
        lang.yaml.enable = true;
        lang.toml.enable = true;
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
        taplo # pyproject.toml, and anything else TOML you touch
        lua-language-server
        bash-language-server
        yaml-language-server
        # Rust, ~15 MB. Replaces marksman, which brought a .NET runtime
        # along and was never wired to a server config anyway.
        markdown-oxide

        # The DAP adapter LazyVim's lang.python launches by name. It shares
        # the python3 lang.python already pulls in, so it costs only debugpy.
        # The program being debugged runs on whichever venv is active
        # (python3.10, 3.11, or the base image's) -- debugpy injects itself
        # into that interpreter, so the versions need not match.
        python3Packages.debugpy
      ];

      # Carried over from the NixOS desktop config so the two editors behave
      # the same. Each entry becomes lua/plugins/<name>.lua.
      plugins = {
        # lazyvim-nix misses some plugins: ones that only appear as a nested
        # `dependencies` entry, blink.cmp, and the lazily-loaded catppuccin.
        # lazy.nvim installs every missing spec at startup, lazy or not, so in
        # the gap each one is a failed clone on every start. Pinning them by
        # store path is what makes completion, the dap.core and lang.yaml
        # extras, and LazyVim's snippets work offline. Found by starting nvim
        # in a network namespace with no route out; rerun that after any
        # lazyvim-nix bump.
        nix-pins =
          let
            pin = repo: pkg: ''{ "${repo}", dir = "${pkg}", dev = false },'';
          in
          ''
            return {
              ${pin "mfussenegger/nvim-dap-python" pkgs.vimPlugins.nvim-dap-python}
              ${pin "theHamsta/nvim-dap-virtual-text" pkgs.vimPlugins.nvim-dap-virtual-text}
              ${pin "nvim-neotest/nvim-nio" pkgs.vimPlugins.nvim-nio}
              ${pin "b0o/SchemaStore.nvim" pkgs.vimPlugins.SchemaStore-nvim}
              ${pin "rafamadriz/friendly-snippets" pkgs.vimPlugins.friendly-snippets}
              ${pin "nvim-treesitter/nvim-treesitter-textobjects" pkgs.vimPlugins.nvim-treesitter-textobjects}
              ${pin "saghen/blink.cmp" pkgs.vimPlugins.blink-cmp}
              { "catppuccin/nvim", name = "catppuccin", dir = "${pkgs.vimPlugins.catppuccin-nvim}", dev = false },
            }
          '';

        # Manual completion: the menu opens on <C-Space>, never on its own,
        # which also saves a redraw per keystroke over a slow exec stream.
        # A function, not a table: sources.default is opts_extend'ed, so a
        # table would append rather than replace.
        completion = ''
          return {
            {
              "saghen/blink.cmp",
              opts = function(_, opts)
                opts.sources.default = { "lsp", "path", "snippets" }
                opts.completion.menu.auto_show = false
                opts.completion.ghost_text.enabled = false
              end,
            },
          }
        '';

        lsp = ''
          return {
            {
              "neovim/nvim-lspconfig",
              opts = {
                inlay_hints = { enabled = false },
                servers = {
                  markdown_oxide = {},
                },
              },
            },
          }
        '';

        lualine = ''
          return {
            "nvim-lualine/lualine.nvim",
            opts = function(_, opts)
              opts.sections.lualine_y = { "progress" }
              opts.sections.lualine_z = { "location" }
              table.insert(opts.sections.lualine_x, "encoding")
            end,
          }
        '';

        # Hand-rolled instead of the lang.markdown extra, which would add
        # marksman, markdownlint and prettier. `dir` pins it to the store:
        # lazyvim-nix only resolves plugins named by an enabled extra.
        #
        # No snacks.image (the desktop config renders LaTeX with it): image
        # protocols do not survive tmux plus `runai exec`, and it would drag
        # imagemagick and tectonic into the layer.
        markdown = ''
          return {
            {
              dir = "${pkgs.vimPlugins.render-markdown-nvim}",
              name = "render-markdown.nvim",
              ft = { "markdown" },
              opts = {
                render_modes = true, -- render in insert too; anti_conceal keeps the cursor line raw
                code = { sign = false, width = "block", right_pad = 1 },
                heading = { sign = false, icons = {} },
                pipe_table = { preset = "round" },
                latex = { enabled = false },
              },
              config = function(_, opts)
                require("render-markdown").setup(opts)
                Snacks.toggle({
                  name = "Render Markdown",
                  get = require("render-markdown").get,
                  set = require("render-markdown").set,
                }):map("<leader>um")
              end,
            },
          }
        '';
      };

      config = {
        options = ''
          vim.g.lazyvim_python_lsp = "basedpyright"

          -- Only yanks reach the system clipboard (see autocmds); d/c/x stay
          -- in nvim's registers. In a pod "+" is OSC 52, so this is also what
          -- keeps every delete from being shipped to the Windows clipboard.
          vim.opt.clipboard = ""
        '';
        autocmds = ''
          vim.api.nvim_create_autocmd("TextYankPost", {
            group = vim.api.nvim_create_augroup("yank_to_clipboard", { clear = true }),
            callback = function()
              if vim.v.event.operator == "y" and vim.v.event.regname == "" then
                vim.fn.setreg("+", vim.v.event.regcontents, vim.v.event.regtype)
              end
            end,
          })
        '';
      };
    };

    # withAllGrammars is ~1 GB. This curated set is ~40 MB and covers every
    # language in this repo and the ones you actually work in.
    # The LazyVim starter's bootstrap `git clone`s lazy.nvim whenever this
    # path is missing, and lazyvim-nix keeps the starter as-is -- it ships
    # lazy.nvim on the runtimepath, which the bootstrap never checks. Online
    # that is a silent clone; in the gap it is "Failed to clone lazy.nvim"
    # and an editor that exits on the first start.
    xdg.dataFile."nvim/lazy/lazy.nvim".source = pkgs.vimPlugins.lazy-nvim;

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
