-- sap-nvim.core.sapcli
-- Guard central para ejecutar sapcli sin saltarse el freno anti-bloqueo de ADT.

local M = {}

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.WARN)
end

local function is_sapcli(args)
	return type(args) == "table" and args[1] == "sapcli"
end

local function is_local_command(args)
	if not is_sapcli(args) then
		return true
	end
	return args[2] == "config" or args[2] == "--version" or args[2] == "-V" or args[2] == "version"
end

local function ready()
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	return ok and adt_http.ready()
end

function M.ensure_ready(args, opts)
	opts = opts or {}
	if is_local_command(args) or opts.allow_unvalidated then
		return true
	end
	if ready() then
		return true
	end
	if opts.notify ~= false then
		notify("Conexión SAP no validada o pausada. Usa :SapLogin o :SapRelogin antes de lanzar sapcli.")
	end
	return false
end

function M.jobstart(args, opts, gate_opts)
	opts = opts or {}
	if not M.ensure_ready(args, gate_opts) then
		if opts.on_exit then
			vim.schedule(function()
				pcall(opts.on_exit, 0, -1, "blocked")
			end)
		end
		return -1
	end
	return vim.fn.jobstart(args, opts)
end

function M.system(args, input, gate_opts)
	if not M.ensure_ready(args, gate_opts) then
		return ""
	end
	return vim.fn.system(args, input)
end

function M.systemlist(args, input, gate_opts)
	if not M.ensure_ready(args, gate_opts) then
		return {}
	end
	return vim.fn.systemlist(args, input)
end

return M
