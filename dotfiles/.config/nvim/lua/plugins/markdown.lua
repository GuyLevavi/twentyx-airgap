-- Plugin configuration for markdown (configured via Nix)
return {
  {
    dir = "/nix/store/03hdzawfn4g7svvff54y7wlpmra6hrpa-vimplugin-render-markdown.nvim-8.13.0",
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

