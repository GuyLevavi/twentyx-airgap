-- Airgap overrides: no runtime downloads, language servers from the Nix
-- profile, nixd instead of the nix extra's nil_ls.
return {
  { "mason-org/mason.nvim", enabled = false },
  { "mason-org/mason-lspconfig.nvim", enabled = false },

  {
    "neovim/nvim-lspconfig",
    opts = {
      servers = {
        nil_ls = { enabled = false },
        nixd = {},
        basedpyright = {},
        ruff = {},
        bashls = {},
        taplo = {},
      },
    },
  },

  {
    "nvim-treesitter/nvim-treesitter",
    opts = { install_dir = vim.env.TWENTYX_NVIM_PLUGINS },
  },

  {
    "saghen/blink.cmp",
    opts = { fuzzy = { prebuilt_binaries = { download = false } } },
  },

  {
    "linux-cultist/venv-selector.nvim",
    ft = "python",
    opts = {},
  },
}
