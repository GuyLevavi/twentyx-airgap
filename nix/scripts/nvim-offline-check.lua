-- Offline check for the Nix-built nvim plugin tree. Runs in the Nix sandbox,
-- so any attempt to fetch is a failure by construction.
--
--   nvim --headless -c 'luafile nvim-offline-check.lua'
--
-- Asserts:
--   * every enabled lazy spec resolves to a directory inside
--     TWENTYX_NVIM_PLUGINS (the Nix linkFarm)
--   * every wanted treesitter parser is installed under install_dir
--   * every LSP binary resolves from PATH
--   * :messages holds no errors
local errors = {}

local root = vim.env.TWENTYX_NVIM_PLUGINS
if not root or root == "" then
  vim.api.nvim_err_writeln("TWENTYX_NVIM_PLUGINS is not set")
  vim.cmd("cquit 1")
end

local lazy = require("lazy")
local missing = {}
local foreign = {}
for _, p in ipairs(lazy.plugins()) do
  if p._.kind ~= "disabled" then
    if vim.fn.isdirectory(p.dir) == 0 then
      missing[#missing + 1] = p.name
    elseif not p.dir:find(root, 1, true) then
      foreign[#foreign + 1] = p.name .. " -> " .. p.dir
    end
  end
end
if #missing > 0 then
  errors[#errors + 1] = "not installed: " .. table.concat(missing, ", ")
end
if #foreign > 0 then
  errors[#errors + 1] = "not from the Nix tree: " .. table.concat(foreign, ", ")
end

local TS = require("nvim-treesitter")
local installed = {}
for _, lang in ipairs(TS.get_installed()) do
  installed[lang] = true
end
local wanted = {
  "bash", "c", "diff", "dockerfile", "fish", "gitcommit", "git_config",
  "gitignore", "html", "javascript", "jsdoc", "json", "json5", "lua",
  "luadoc", "luap", "markdown", "markdown_inline", "nix", "printf",
  "python", "query", "regex", "toml", "tsx", "typescript", "vim", "vimdoc",
  "xml", "yaml",
}
local absent = {}
for _, lang in ipairs(wanted) do
  if not installed[lang] then
    absent[#absent + 1] = lang
  end
end
if #absent > 0 then
  errors[#errors + 1] = "parsers missing: " .. table.concat(absent, ", ")
end

for _, bin in ipairs({
  "nixd", "nixfmt", "basedpyright-langserver", "ruff",
  "bash-language-server", "yaml-language-server",
  "vscode-json-language-server", "taplo", "tombi", "package-version-server",
}) do
  if vim.fn.executable(bin) ~= 1 then
    errors[#errors + 1] = "not on PATH: " .. bin
  end
end

local messages = vim.api.nvim_exec2("messages", { output = true }).output
local err = messages:match("E%d+:")
if err then
  errors[#errors + 1] = "error in :messages: " .. err
end

if #errors > 0 then
  vim.api.nvim_err_writeln(table.concat(errors, "\n"))
  vim.cmd("cquit 1")
end
vim.api.nvim_out_write("nvim offline check OK\n")
vim.cmd("qa!")
