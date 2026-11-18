-- [NIX] Disable treesitter healthcheck - parsers are pre-built by Nix
-- LazyVim's healthcheck expects tree-sitter CLI and C compiler which aren't needed
vim.api.nvim_create_autocmd("User", {
  pattern = "VeryLazy",
  once = true,
  callback = function()
    local ok, ts = pcall(require, "lazyvim.util.treesitter")
    if ok and ts then
      ts.check = function()
        return true, { ["nix"] = true }
      end
    end
  end,
})
return {}
