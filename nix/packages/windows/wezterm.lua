-- WezTerm configuration -- shipped in .#windows-kit, installed by UNPACK.ps1
-- as %USERPROFILE%\.wezterm.lua when absent.
--
-- Lean on purpose: every shell in the distro lands in tmux, which owns tabs,
-- panes, scrollback and copy mode. This file only opens the distro, picks the
-- look, and keeps rendering cheap on work PCs with integrated graphics.

local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- WSL straight into the twentyx distro (fish -> tmux).
config.default_domain = "WSL:twentyx"

-- JetBrains Mono and the Nerd Font symbols are both built into WezTerm, so
-- this needs no font install on the airgapped PC.
config.font = wezterm.font("JetBrains Mono")
config.font_size = 14
-- Slightly narrower cells: fixes Nerd Font symbol overlap and box-drawing
-- alignment (git diff separators).
config.cell_width = 0.9
config.color_scheme = "Tokyo Night" -- matches btop/opencode

-- Integrated GPU only: OpenGL, at the panel's 60 Hz.
config.front_end = "OpenGL"
config.max_fps = 60

config.audible_bell = "Disabled"
config.window_decorations = "RESIZE"
config.window_padding = { left = 4, right = 4, top = 4, bottom = 0 }
config.hide_tab_bar_if_only_one_tab = true

-- Alt+Enter is WezTerm's default fullscreen toggle; free it for the apps
-- (opencode and nvim bind it). Shift/Ctrl+Enter need no binding: tmux asks
-- for modifyOtherKeys (`extkeys` in tmux.conf) and forwards them as CSI u.
config.keys = {
  { key = "Enter", mods = "ALT", action = wezterm.action.DisableDefaultAssignment },
}

return config
