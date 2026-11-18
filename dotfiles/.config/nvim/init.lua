vim.g.node_host_prog='/nix/store/qg0isnbvfc9xpimcmva6mf10zw7hx2hc-node-client-5.4.0/bin/neovim-node-host';vim.g.loaded_perl_provider=0;vim.g.loaded_ruby_provider=0;vim.g.python3_host_prog='/nix/store/g38xy15izkpi610gf4azdhvd30jiw5iz-nvim-host-python3-3.14.7-env/bin/nvim-python3'
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

-- LazyVim Nix Configuration
-- Based on LazyVim/starter (commit: 803bc181d7c0d6d5eeba9274d9be49b287294d99)
-- Patched for Nix compatibility by lazyvim-nix flake
-- Sections marked [NIX] are Nix-specific modifications

local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  local lazyrepo = "https://github.com/folke/lazy.nvim.git"
  local out = vim.fn.system({ "git", "clone", "--filter=blob:none", "--branch=stable", lazyrepo, lazypath })
  if vim.v.shell_error ~= 0 then
    vim.api.nvim_echo({
      { "Failed to clone lazy.nvim:\n", "ErrorMsg" },
      { out, "WarningMsg" },
      { "\nPress any key to exit..." },
    }, true, {})
    vim.fn.getchar()
    os.exit(1)
  end
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
spec = {
  -- [NIX] LazyVim with dev mode for Nix-managed packages
  { "LazyVim/LazyVim", import = "lazyvim.plugins", dev = true, pin = true },
  -- [NIX] LazyVim extras
  { import = "lazyvim.plugins.extras.dap.core" },
    { import = "lazyvim.plugins.extras.lang.nix" },
    { import = "lazyvim.plugins.extras.lang.python" },
    { import = "lazyvim.plugins.extras.lang.toml" },
    { import = "lazyvim.plugins.extras.lang.yaml" },
  -- [NIX] Mason disabled - Nix provides tools via extraPackages
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },
  { "jay-babu/mason-nvim-dap.nvim", enabled = false },
  -- [NIX] Treesitter configured for Nix-managed parsers
  {
      "nvim-treesitter/nvim-treesitter",
      event = { "BufReadPost", "BufNewFile", "BufWritePre", "VeryLazy" },
      cmd = { "TSUpdate", "TSInstall", "TSLog", "TSUninstall" },
      -- [NIX] Parser compilation is skipped when using Nix
      build = false,
      opts = {
        auto_install = false,
        ensure_installed = {},
        highlight = { enable = true },
        indent = { enable = true },
        incremental_selection = {
          enable = true,
          keymaps = {
            init_selection = "<C-space>",
            node_incremental = "<C-space>",
            scope_incremental = false,
            node_decremental = "<bs>",
          },
        },
      },
      dev = true,
      pin = true,
    },
  -- [NIX] Available plugins marked as dev (Nix-managed)
  { "LazyVim", dev = true, pin = true },
    { "grug-far.nvim", dev = true, pin = true },
    { "nui.nvim", dev = true, pin = true },
    { "bufferline.nvim", dev = true, pin = true },
    { "nvim", dev = true, pin = true },
    { "flash.nvim", dev = true, pin = true },
    { "lazy.nvim", dev = true, pin = true },
    { "lazydev.nvim", dev = true, pin = true },
    { "noice.nvim", dev = true, pin = true },
    { "persistence.nvim", dev = true, pin = true },
    { "snacks.nvim", dev = true, pin = true },
    { "todo-comments.nvim", dev = true, pin = true },
    { "tokyonight.nvim", dev = true, pin = true },
    { "trouble.nvim", dev = true, pin = true },
    { "ts-comments.nvim", dev = true, pin = true },
    { "which-key.nvim", dev = true, pin = true },
    { "gitsigns.nvim", dev = true, pin = true },
    { "mason-lspconfig.nvim", dev = true, pin = true },
    { "mason.nvim", dev = true, pin = true },
    { "nvim-lint", dev = true, pin = true },
    { "nvim-lspconfig", dev = true, pin = true },
    { "plenary.nvim", dev = true, pin = true },
    { "lualine.nvim", dev = true, pin = true },
    { "mini.ai", dev = true, pin = true },
    { "mini.icons", dev = true, pin = true },
    { "mini.pairs", dev = true, pin = true },
    { "conform.nvim", dev = true, pin = true },
    { "nvim-ts-autotag", dev = true, pin = true },
    { "mason-nvim-dap.nvim", dev = true, pin = true },
    { "venv-selector.nvim", dev = true, pin = true },
    { "nvim-dap", dev = true, pin = true },
    { "nvim-dap-ui", dev = true, pin = true },
  -- User plugins
  { import = "plugins" },
},
-- [NIX] Dev path for Nix-symlinked plugins
dev = {
  path = "/nix/store/6qsdnawnwfnqi5d2cija7dd1w9ai3m8c-lazyvim-dev-path",
  patterns = {},  -- Don't automatically match, use explicit dev = true
  fallback = false,
},
  defaults = {
    -- By default, only LazyVim plugins will be lazy-loaded. Your custom plugins will load during startup.
    -- If you know what you're doing, you can set this to `true` to have all your custom plugins lazy-loaded by default.
    lazy = false,
    -- It's recommended to leave version=false for now, since a lot the plugin that support versioning,
    -- have outdated releases, which may break your Neovim install.
    version = false, -- always use the latest git commit
    -- version = "*", -- try installing the latest stable version for plugins that support semver
  },
  install = { colorscheme = { "tokyonight", "habamax" } },
  checker = {
    enabled = false, -- [NIX] Disabled - Nix manages plugin versions
    notify = false,
  },
  -- [NIX] Disable config change notifications since Nix generates config
  change_detection = { notify = false },
  performance = {
    rtp = {
      -- disable some rtp plugins
      disabled_plugins = {
        "gzip",
        -- "matchit",
        -- "matchparen",
        -- "netrwPlugin",
        "tarPlugin",
        "tohtml",
        "tutor",
        "zipPlugin",
      },
    },
  },
})
