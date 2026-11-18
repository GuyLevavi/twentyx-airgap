#!/usr/bin/env bash
# Run OUTSIDE, before every transfer that touches nvim.
#
#   ./scripts/check-nvim-offline.sh [flake-attr]   default: runai-nvim
#
# Starts the built LazyVim in a network namespace with no route out, which is
# the only honest test of "works in the gap". Online, lazy.nvim quietly
# `git clone`s anything lazyvim-nix failed to resolve, so a missing plugin
# looks exactly like a working one. Both bugs this exists for were invisible
# that way: the starter cloning lazy.nvim itself, and blink.cmp, catppuccin and
# the dap/yaml dependencies never making it into the dev path.
#
# Checks: no clone attempts, the markdown and python LSPs attach,
# render-markdown loads, the imported options are in force, and a debugpy
# session stops on a breakpoint.
set -euo pipefail

cd "$(dirname "${BASH_SOURCE[0]}")/.."
ATTR="${1:-runai-nvim}"

say() { printf '\033[36m==>\033[0m %s\n' "$*"; }

command -v unshare >/dev/null || { echo "needs unshare (util-linux)" >&2; exit 1; }

say "building $ATTR"
FILES="$(nix build --no-link --print-out-paths ".#homeConfigurations.$ATTR.config.home-files")"
PROFILE="$(nix build --no-link --print-out-paths ".#homeConfigurations.$ATTR.config.home.path")"

T="$(mktemp -d)"
trap 'rm -rf "$T"' EXIT
H="$T/home"
mkdir -p "$H/w"
# Copied, not symlinked: lazy.nvim writes state next to its config.
cp -rL "$FILES/.config" "$FILES/.local" "$H/"
chmod -R u+w "$H"
printf '# Title\n\n| a | b |\n|---|---|\n| 1 | 2 |\n' > "$H/w/t.md"
printf 'x = 1\ny = x + 1\nprint(y)\n' > "$H/w/t.py"

cat > "$T/check.lua" <<'EOF'
local out, fail = {}, false
local function check(name, ok, detail)
  if not ok then fail = true end
  table.insert(out, (ok and "ok   " or "FAIL ") .. name .. (detail and ("  (" .. detail .. ")") or ""))
  vim.fn.writefile(out, vim.env.RESULT)
end
local function clients()
  return table.concat(vim.tbl_map(function(c) return c.name end, vim.lsp.get_clients({ bufnr = 0 })), ",")
end

vim.cmd.edit(vim.env.HOME .. "/w/t.md")
vim.wait(10000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 0 end)
check("markdown lsp", clients():find("markdown_oxide") ~= nil, clients())
check("render-markdown", package.loaded["render-markdown"] ~= nil)
check("yank-only clipboard", vim.o.clipboard == "")

require("lazy").load({ plugins = { "blink.cmp" } })
local srcs = table.concat(require("blink.cmp.config").sources.default, ",")
check("blink sources", srcs == "lsp,path,snippets", srcs)

vim.cmd.edit(vim.env.HOME .. "/w/t.py")
vim.wait(15000, function() return #vim.lsp.get_clients({ bufnr = 0 }) > 1 end)
check("python lsps", clients():find("basedpyright") ~= nil, clients())

local dap = require("dap")
local stopped = false
dap.listeners.after.event_stopped["offline-check"] = function(_, body) stopped = body.reason end
vim.api.nvim_win_set_cursor(0, { 2, 0 })
dap.toggle_breakpoint()
dap.run({ type = "python", request = "launch", name = "t", program = vim.env.HOME .. "/w/t.py" })
vim.wait(30000, function() return stopped end, 100)
check("debugpy breakpoint", stopped == "breakpoint", tostring(stopped))
if stopped then dap.terminate() end

table.insert(out, fail and "RESULT: FAIL" or "RESULT: ok")
vim.fn.writefile(out, vim.env.RESULT)
vim.cmd("qa!")
EOF

say "starting nvim with no network"
# -r maps us to root inside the namespace, which is what lets us bring up
# loopback: a fresh netns has it down, and debugpy talks to its adapter over
# 127.0.0.1. A pod has loopback, so without this the dap check fails for a
# reason the real environment does not share.
#
# Inside, PATH is only the profile under test, so `ip` and `timeout` are
# resolved here, on the host, and passed in.
# shellcheck disable=SC2016 # expanded by the inner sh, from its arguments
unshare -rn sh -c '
    "$4" link set lo up 2>/dev/null || true
    exec env -i HOME="$1" PATH="$2/bin" TERM=xterm-256color \
        XDG_CACHE_HOME="$1/.cache" RESULT="$3/result" \
        "$5" 120 nvim --headless -c "luafile $3/check.lua"
' _ "$H" "$PROFILE" "$T" "$(command -v ip || echo true)" "$(command -v timeout)" \
    > "$T/nvim.log" 2>&1 || true

cat "$T/result" 2>/dev/null || echo "no result written -- nvim died before the checks ran"

# lazy.nvim logs each install task; any of them means a plugin was missing.
clones="$(sed 's/\x1b\[[0-9;]*m//g' "$T/nvim.log" | grep -oE '\[[A-Za-z0-9._-]+\] +clone|Failed to clone [^:]*' | sort -u || true)"
if [ -n "$clones" ]; then
    echo "FAIL clone attempts (unresolved plugins):"
    printf '  %s\n' "$clones"
    exit 1
fi
grep -q '^RESULT: ok' "$T/result" 2>/dev/null
