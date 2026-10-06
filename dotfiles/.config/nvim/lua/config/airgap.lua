-- lazy.nvim bootstrap. No git clone and no lockfile writes: the plugin tree
-- is the Nix closure (TWENTYX_NVIM_PLUGINS, set by the profile).
local root = vim.env.TWENTYX_NVIM_PLUGINS
if not root or root == "" then
  vim.notify(
    "TWENTYX_NVIM_PLUGINS is not set -- start nvim from a seeded shell",
    vim.log.levels.ERROR
  )
  return
end

vim.opt.rtp:prepend(root .. "/lazy.nvim")

require("lazy").setup({
  spec = {
    { "LazyVim/LazyVim", import = "lazyvim.plugins" },
    { import = "lazyvim.plugins.extras.coding.blink" },
    { import = "lazyvim.plugins.extras.lang.nix" },
    { import = "lazyvim.plugins.extras.lang.json" },
    { import = "lazyvim.plugins.extras.lang.yaml" },
    { import = "lazyvim.plugins.extras.lang.toml" },
    { import = "plugins" },
  },
  dev = {
    path = root,
    patterns = { "" },
    fallback = false,
  },
  install = { missing = false },
  checker = { enabled = false },
  change_detection = { enabled = false },
  rocks = { enabled = false },
  performance = {
    rtp = { reset = false },
    reset_packpath = false,
  },
})
