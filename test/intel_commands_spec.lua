-- Offline regression test for intelligence commands registered by intel.setup().

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

local intel = require("sap-nvim.core.intel")
intel.setup()

local function must_command(name)
	if vim.fn.exists(":" .. name) ~= 2 then
		error(name .. " command is not registered")
	end
end

must_command("SapComplete")
must_command("SapCompleteDebug")
must_command("SapCheck")
must_command("SapHover")

print("INTEL_COMMANDS_OK")
