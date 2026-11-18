-- User options configured via Nix
vim.g.lazyvim_python_lsp = "basedpyright"

-- Only yanks reach the system clipboard (see autocmds); d/c/x stay
-- in nvim's registers. In a pod "+" is OSC 52, so this is also what
-- keeps every delete from being shipped to the Windows clipboard.
vim.opt.clipboard = ""

