-- A link into the repo; edit it there and commit.
--
-- The plugin tree is Nix-built and read-only: lazy.nvim's dev mechanism
-- resolves every spec inside $TWENTYX_NVIM_PLUGINS, so nothing is ever
-- fetched. See lua/config/airgap.lua and lua/plugins/airgap.lua.
require("config.airgap")
