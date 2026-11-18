-- Plugin configuration for lsp (configured via Nix)
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

