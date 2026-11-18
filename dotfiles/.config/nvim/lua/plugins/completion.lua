-- Plugin configuration for completion (configured via Nix)
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

