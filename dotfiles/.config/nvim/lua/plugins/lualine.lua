-- Plugin configuration for lualine (configured via Nix)
return {
  "nvim-lualine/lualine.nvim",
  opts = function(_, opts)
    opts.sections.lualine_y = { "progress" }
    opts.sections.lualine_z = { "location" }
    table.insert(opts.sections.lualine_x, "encoding")
  end,
}

