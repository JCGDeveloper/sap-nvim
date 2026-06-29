-- Offline regression test for sapcli productive gates.
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function same(actual, expected, msg)
	if actual ~= expected then
		fails = fails + 1
		print("  FAIL " .. msg .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
	else
		print("  OK  " .. msg)
	end
end

local config = {
	profile = "prod",
	prod = {
		read_only = true,
		require_tls = true,
		confirm_destructive = true,
		allow_create_objects = false,
		allow_write_objects = false,
		allow_release_transports = false,
		allow_delete_objects = false,
		allow_delete_transports = false,
	},
	sec = { verify_tls = true },
	audits = {},
}
config.profile_name = function() return config.profile end
config.productive = function() return config.prod end
config.security = function() return config.sec end
config.audit = function(action, detail)
	config.audits[#config.audits + 1] = { action = action, detail = detail }
end

local adt = {
	ready = function() return true end,
	creds = function() return { user = "DEVELOPER", pass = "secret" } end,
}

local calls = { notify = {}, jobstart = {}, input = {} }
_G.vim = _G.vim or {}
vim.log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } }
vim.notify = function(msg, level) calls.notify[#calls.notify + 1] = { msg = msg, level = level } end
vim.schedule = function(fn) fn() end
vim.env = {}
vim.trim = function(s) return tostring(s or ""):match("^%s*(.-)%s*$") end
vim.tbl_extend = function(_, ...)
	local out = {}
	for i = 1, select("#", ...) do
		local t = select(i, ...)
		if type(t) == "table" then for k, v in pairs(t) do out[k] = v end end
	end
	return out
end
vim.fn = {
	filereadable = function() return 1 end,
	expand = function(p) return p end,
	input = function(prompt)
		calls.input[#calls.input + 1] = prompt
		return "S4HK900001"
	end,
	jobstart = function(args, opts)
		calls.jobstart[#calls.jobstart + 1] = { args = args, opts = opts }
		return 77
	end,
}

package.loaded["sap-nvim.core.config"] = config
package.loaded["sap-nvim.core.adt_http"] = adt

local sapcli = require("sap-nvim.core.sapcli")

local job = sapcli.jobstart({ "sapcli", "program", "create", "ZREP", "Desc", "$TMP" }, {})
same(job, -1, "prod read_only blocks create")
same(#calls.jobstart, 0, "blocked create does not spawn")
same(config.audits[#config.audits].detail.reason, "read_only", "blocked create is audited")

job = sapcli.jobstart({ "sapcli", "program", "create", "ZREP", "Desc", "$TMP" }, {}, { allow_unvalidated = true })
same(job, -1, "allow_unvalidated does not bypass prod read_only")
same(#calls.jobstart, 0, "allow_unvalidated blocked create does not spawn")

config.prod.read_only = false
config.prod.allow_release_transports = false
job = sapcli.jobstart({ "sapcli", "cts", "release", "S4HK900001" }, {})
same(job, -1, "prod release requires opt-in")
same(config.audits[#config.audits].detail.reason, "opt_in", "release opt-in block is audited")

config.prod.allow_release_transports = true
job = sapcli.jobstart({ "sapcli", "cts", "release", "S4HK900001" }, {})
same(job, 77, "prod release runs after opt-in and exact confirmation")
same(#calls.input, 1, "prod release prompts for exact ID")
same(config.audits[#config.audits].action, "allowed", "allowed release is audited")

config.sec.verify_tls = false
job = sapcli.jobstart({ "sapcli", "program", "list" }, {})
same(job, -1, "prod requires verified TLS before remote sapcli")
same(config.audits[#config.audits].detail.reason, "tls", "TLS block is audited")

if fails == 0 then
	print("SAPCLI_PRODUCTIVE_GATE_OK")
else
	os.exit(1)
end
