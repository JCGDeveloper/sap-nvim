-- Offline regression test for sap-nvim.core.sapcli.
--
-- Run without SAP:
--   luajit test/sapcli_gate_spec.lua
--   nvim --headless -u NONE -i NONE -c "luafile test/sapcli_gate_spec.lua"
--
-- The test stubs Neovim and adt_http, so it never starts sapcli and never
-- reads ~/.sapcli/config.yml.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function ok(cond, msg)
	if cond then
		print("  OK  " .. msg)
	else
		fails = fails + 1
		print("  FAIL " .. msg)
	end
end

local function same(actual, expected, msg)
	ok(actual == expected, msg .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
end

local adt
adt = {
	ready_value = false,
	creds_value = { user = "DEVELOPER", pass = "secret" },
	ready = function()
		return adt.ready_value
	end,
	creds = function()
		return adt.creds_value
	end,
}

local calls = { notify = {}, jobstart = {}, system = {}, systemlist = {} }
local env = { SAP_USER = "outer-user", SAP_PASSWORD = "outer-pass" }

_G.vim = _G.vim or {}
vim.log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
vim.notify = function(msg, level)
	calls.notify[#calls.notify + 1] = { msg = msg, level = level }
end
vim.schedule = function(fn)
	fn()
end
vim.env = env
vim.tbl_extend = function(_, ...)
	local out = {}
	for i = 1, select("#", ...) do
		local t = select(i, ...)
		if type(t) == "table" then
			for k, v in pairs(t) do
				out[k] = v
			end
		end
	end
	return out
end
vim.fn = {
	jobstart = function(args, opts)
		calls.jobstart[#calls.jobstart + 1] = { args = args, opts = opts }
		return 42
	end,
	system = function(args, input)
		calls.system[#calls.system + 1] = {
			args = args,
			input = input,
			user = vim.env.SAP_USER,
			pass = vim.env.SAP_PASSWORD,
		}
		return "system-output"
	end,
	systemlist = function(args, input)
		calls.systemlist[#calls.systemlist + 1] = {
			args = args,
			input = input,
			user = vim.env.SAP_USER,
			pass = vim.env.SAP_PASSWORD,
		}
		return { "line-1", "line-2" }
	end,
}

package.loaded["sap-nvim.core.adt_http"] = adt
local sapcli = require("sap-nvim.core.sapcli")

print("sapcli gate - blocked remote commands:")
local blocked_exit
adt.ready_value = false
local job = sapcli.jobstart({ "sapcli", "program", "list" }, {
	on_exit = function(job_id, code, event)
		blocked_exit = { job_id = job_id, code = code, event = event }
	end,
})
same(job, -1, "remote jobstart returns -1 when ADT is not ready")
same(blocked_exit and blocked_exit.code, -1, "blocked jobstart reports exit code -1")
same(blocked_exit and blocked_exit.event, "blocked", "blocked jobstart reports blocked event")
same(#calls.jobstart, 0, "blocked jobstart does not spawn a process")
same(#calls.notify, 1, "blocked jobstart notifies once")

local out = sapcli.system({ "sapcli", "program", "read", "ZFOO" })
same(out, "", "blocked system returns empty string")
same(#calls.system, 0, "blocked system does not spawn")

local list = sapcli.systemlist({ "sapcli", "class", "read", "ZCL_FOO" })
same(#list, 0, "blocked systemlist returns empty list")
same(#calls.systemlist, 0, "blocked systemlist does not spawn")

print("sapcli gate - local commands:")
job = sapcli.jobstart({ "sapcli", "config", "current-context" }, { env = { KEEP = "yes" } })
same(job, 42, "sapcli config is allowed without validated ADT")
same(#calls.jobstart, 1, "local jobstart spawns once")
same(calls.jobstart[1].opts.env.KEEP, "yes", "local jobstart preserves opts.env")
same(calls.jobstart[1].opts.env.SAP_USER, nil, "local jobstart does not inject SAP_USER")

out = sapcli.system({ "sapcli", "--version" })
same(out, "system-output", "sapcli --version is allowed without validated ADT")
same(calls.system[#calls.system].user, "outer-user", "local system keeps process SAP_USER")
same(vim.env.SAP_USER, "outer-user", "local system leaves SAP_USER unchanged")

print("sapcli gate - validated remote commands:")
adt.ready_value = true
job = sapcli.jobstart({ "sapcli", "atc", "run", "program", "ZFOO" }, { env = { KEEP = "yes" } })
same(job, 42, "validated remote jobstart is allowed")
local remote_job = calls.jobstart[#calls.jobstart]
same(remote_job.opts.env.KEEP, "yes", "remote jobstart keeps caller env")
same(remote_job.opts.env.SAP_USER, "DEVELOPER", "remote jobstart injects SAP_USER")
same(remote_job.opts.env.SAP_PASSWORD, "secret", "remote jobstart injects SAP_PASSWORD")

out = sapcli.system({ "sapcli", "atc", "run", "program", "ZFOO" }, "stdin")
same(out, "system-output", "validated remote system returns output")
same(calls.system[#calls.system].user, "DEVELOPER", "remote system sets SAP_USER during call")
same(calls.system[#calls.system].pass, "secret", "remote system sets SAP_PASSWORD during call")
same(vim.env.SAP_USER, "outer-user", "remote system restores SAP_USER")
same(vim.env.SAP_PASSWORD, "outer-pass", "remote system restores SAP_PASSWORD")

list = sapcli.systemlist({ "sapcli", "aunit", "run", "class", "ZCL_FOO" })
same(#list, 2, "validated remote systemlist returns lines")
same(calls.systemlist[#calls.systemlist].user, "DEVELOPER", "remote systemlist sets SAP_USER during call")
same(vim.env.SAP_USER, "outer-user", "remote systemlist restores SAP_USER")

print("sapcli gate - explicit bypass:")
adt.ready_value = false
job = sapcli.jobstart({ "sapcli", "program", "list" }, {}, { allow_unvalidated = true })
same(job, 42, "allow_unvalidated bypasses the readiness gate")

if fails == 0 then
	print("\nTODO OK")
else
	print("\n" .. fails .. " FALLOS")
end

if vim and vim.cmd then
	vim.cmd(fails == 0 and "qa!" or "cquit")
else
	os.exit(fails == 0 and 0 or 1)
end
