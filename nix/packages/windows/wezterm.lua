-- =============================================================================
-- WezTerm configuration — shipped in .#windows-kit
-- =============================================================================
-- Copy to %USERPROFILE%\.wezterm.lua (C:\Users\<you>\.wezterm.lua).
--
-- Targets the airgap WSL workflow: launches straight into the twentyx distro,
-- Tokyo Night to match btop/opencode, and enables the kitty keyboard protocol
-- -- without it TUIs only see a plain Enter (no shift+enter in opencode) and
-- nvim reports modes 2026/2027/2031/2048 unavailable on every session.
-- =============================================================================

local wezterm = require("wezterm")
local config = wezterm.config_builder()

-- -----------------------------------------------------------------------------
-- Font
-- -----------------------------------------------------------------------------
config.font = wezterm.font("JetBrainsMono Nerd Font")
config.font_size = 14
-- Narrow cell width slightly to fix Nerd Font symbol spacing/overlap and
-- improve box-drawing character alignment (e.g. git diff separators).
config.cell_width = 0.9

-- -----------------------------------------------------------------------------
-- Color Scheme
-- -----------------------------------------------------------------------------
-- Uncomment ONE line below to switch. All options are WezTerm built-ins.
config.color_scheme = "Tokyo Night"
-- config.color_scheme = "Catppuccin Mocha"
-- config.color_scheme = "Gruvbox dark, medium (base16)"

-- -----------------------------------------------------------------------------
-- Default Shell / WSL2
-- -----------------------------------------------------------------------------
-- Launch directly into the twentyx distribution.
config.default_domain = "WSL:twentyx"
-- Disable audible bell
config.audible_bell = "Disabled"

-- Kitty keyboard protocol: without this, TUIs only see a plain Enter (no
-- shift+enter in opencode) and nvim reports modes 2026/2027/2031/2048
-- unavailable. Apps that don't speak the protocol are unaffected.
config.enable_kitty_keyboard = true

-- -----------------------------------------------------------------------------
-- GPU Rendering
-- -----------------------------------------------------------------------------
-- WebGpu is fastest (uses dGPU when available). WezTerm auto-selects the best
-- GPU adapter. If you experience crashes, switch to "OpenGL" as a fallback.
config.front_end = "WebGpu"
config.webgpu_power_preference = "HighPerformance" -- prefer dGPU over iGPU
-- config.front_end = "OpenGL"                     -- fallback if WebGpu crashes

-- Reduce input latency: don't wait to coalesce renders
config.max_fps = 144
config.animation_fps = 144

-- -----------------------------------------------------------------------------
-- Window Appearance
-- -----------------------------------------------------------------------------
config.window_decorations = "RESIZE"

config.window_padding = {
  left = 4,
  right = 4,
  top = 4,
  bottom = 0, -- 0 eliminates the dead-pixel gap at the bottom of the window
}

-- -----------------------------------------------------------------------------
-- Tab Bar
-- -----------------------------------------------------------------------------
config.tab_bar_at_bottom = false
config.use_fancy_tab_bar = false
config.hide_tab_bar_if_only_one_tab = true

-- -----------------------------------------------------------------------------
-- Mouse
-- -----------------------------------------------------------------------------
config.enable_scroll_bar = false
config.scrollback_lines = 10000

-- Allow scroll wheel to work inside alternate-screen programs (tmux, nvim, etc.)
config.bypass_mouse_reporting_modifiers = "SHIFT"

return config
