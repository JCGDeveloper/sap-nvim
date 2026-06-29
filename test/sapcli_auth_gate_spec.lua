vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

package.loaded["sap-nvim.core.adt_http"] = {
	ready = function()
		return true
	end,
	creds = function()
		return { user = "USER", pass = "PASS" }
	end,
	is_auth_error = function(body)
		return tostring(body or ""):find("Unauthorized", 1, true) ~= nil
	end,
	on_auth_failure = function()
		_G.sap_auth_failed = true
	end,
}

local old_jobstart = vim.fn.jobstart
vim.fn.jobstart = function(_, opts)
	if opts.on_stderr then
		opts.on_stderr(1, { "HTTP 401 Unauthorized" }, "stderr")
	end
	if opts.on_exit then
		opts.on_exit(1, 1, "exit")
	end
	return 1
end

local sapcli = require("sap-nvim.core.sapcli")
local exited = false
sapcli.jobstart({ "sapcli", "abap", "systeminfo" }, {
	on_exit = function()
		exited = true
	end,
})

vim.fn.jobstart = old_jobstart

if not _G.sap_auth_failed then
	error("sapcli 401 did not trigger adt_http.on_auth_failure")
end
if not exited then
	error("wrapped on_exit was not called")
end

print("SAPCLI_AUTH_GATE_OK")
