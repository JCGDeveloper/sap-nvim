-- Offline regression test: DAP commands exist even when nvim-dap is absent.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

package.loaded.dap = nil
package.preload.dap = function()
	error("dap intentionally absent")
end

require("sap-nvim.integrations.dap").setup()

local function must_command(name)
	if vim.fn.exists(":" .. name) ~= 2 then
		error(name .. " command is not registered")
	end
end

must_command("SapDap")
must_command("SapDapClearBreakpoints")
must_command("SapDapClearBreakpointsRecursive")

print("DAP_COMMANDS_OK")
vim.cmd("qa!")
