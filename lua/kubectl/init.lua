local M = {}

local conf = require("kubectl.config")
local state = require("kubectl.state")
local dashboard = require("kubectl.ui.dashboard")

--- @param opts table|nil: see kubectl.config for the defaults
function M.setup(opts)
	conf.setup(opts)

	vim.api.nvim_create_user_command("Kubectl", function()
		dashboard.toggle()
	end, { desc = "Toggle the Kubernetes dashboard" })

	vim.api.nvim_create_autocmd("VimLeavePre", {
		callback = function()
			state.cleanup()
		end,
	})
end

M.open = dashboard.open
M.close = dashboard.close
M.toggle = dashboard.toggle
M.refresh = dashboard.refresh

return M
