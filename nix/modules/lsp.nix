# One declaration of every language server in the closure, routed to each
# consumer — the shape of /etc/nixos home/lsp.nix, where Zed, opencode and
# nvim all pull from a single list:
#
#   tools.nix    -> home.packages        PATH for fish, nvim, the Zed server
#   tools.nix    -> opencode PATH wrap   spawn by name, never a runtime fetch
#   nvim.nix     -> argv map             vim.lsp.config cmd arrays (kept there:
#                                         flags are nvim-specific)
#   home.nix     -> Zed settings pins    explicit binary paths (kept: measured
#                                         npm/Node fallback when PATH is missed)
#
# In the airgap this list is the difference between editors that work and
# editors that hang trying to download a server at runtime. Add a server here
# and every consumer sees it; each editor config only has to name the binary.
{ pkgs }:
with pkgs;
[
  basedpyright # Python types (pyright fork)
  ruff # Python lint + format server
  nixd # Nix
  nixfmt # Nix formatter — not an LSP, rides along: nixd invokes it
  bash-language-server
  yaml-language-server
  taplo # pyproject.toml, and anything else TOML you touch
  package-version-server # package.json version hover (Zed side)
]
