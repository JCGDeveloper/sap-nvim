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

local function config_mod()
	local ok, cfg = pcall(require, "sap-nvim.core.config")
	return ok and cfg or nil
end

local function productive()
	local cfg = config_mod()
	return cfg and cfg.productive and cfg.productive() or {}
end

local function profile_name()
	local cfg = config_mod()
	return cfg and cfg.profile_name and cfg.profile_name() or "dev"
end

local function audit_context()
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	local ctx = ok and adt_http.context_info and adt_http.context_info() or nil
	if not ctx then return {} end
	return {
		sysid = ctx.sysid,
		client = ctx.client,
		user = ctx.user,
		context = ctx.context,
	}
end

local function audit(action, detail)
	local cfg = config_mod()
	if cfg and cfg.audit then
		pcall(cfg.audit, action, vim.tbl_extend("force", audit_context(), detail or {}))
	end
end

local function action_target(args, start)
	for i = start or 3, #args do
		local v = tostring(args[i] or "")
		if v ~= "" and v ~= "-" and not v:match("^%-") then
			return v
		end
	end
	return table.concat(args or {}, " ")
end

local function classify_sensitive(args)
	if not is_sapcli(args) or is_local_command(args) then
		return nil
	end
	local a2 = tostring(args[2] or ""):lower()
	local a3 = tostring(args[3] or ""):lower()
	local a4 = tostring(args[4] or ""):lower()
	if a2 == "cts" and a3 == "release" then
		return { kind = "release_transport", target = args[4] or action_target(args, 3), allow = "allow_release_transports" }
	end
	if a2 == "cts" and a3 == "delete" and a4 == "transport" then
		return { kind = "delete_transport", target = args[5] or action_target(args, 4), allow = "allow_delete_transports" }
	end
	if a2 == "cts" and a3 == "reassign" then
		return { kind = "write_transport", target = args[5] or action_target(args, 4), allow = "allow_release_transports" }
	end
	if a2 == "cts" and a3 == "create" then
		return { kind = "create_transport", target = action_target(args, 4), allow = "allow_create_objects" }
	end
	for i = 2, #args do
		local v = tostring(args[i] or ""):lower()
		if v == "delete" then
			return { kind = "delete_object", target = action_target(args, i + 1), allow = "allow_delete_objects" }
		elseif v == "create" then
			return { kind = "create_object", target = action_target(args, i + 1), allow = "allow_create_objects" }
		elseif v == "write" then
			return { kind = "write_object", target = action_target(args, i + 1), allow = "allow_write_objects" }
		elseif v == "release" then
			return { kind = "release_transport", target = action_target(args, i + 1), allow = "allow_release_transports" }
		elseif v == "set-variable" or v == "set_variable" or v == "setvariable" then
			return { kind = "set_variable", target = action_target(args, i + 1), allow = "allow_debug_set_variable" }
		end
	end
	return nil
end

local function tls_block_reason()
	local cfg = config_mod()
	if not cfg then return nil end
	local prod = productive()
	if profile_name() ~= "prod" or prod.require_tls == false then
		return nil
	end
	local sec = cfg.security and cfg.security() or {}
	if sec.verify_tls ~= true then
		return "Perfil prod requiere TLS verificado: configura security.verify_tls=true o productive.require_tls=false."
	end
	if sec.ca_file and sec.ca_file ~= "" and vim.fn.filereadable(vim.fn.expand(sec.ca_file)) ~= 1 then
		return "Perfil prod requiere CA legible: " .. vim.fn.expand(sec.ca_file)
	end
	return nil
end

local function confirm_exact(action)
	local prod = productive()
	if prod.confirm_destructive == false then
		return true
	end
	local target = tostring(action.target or action.kind or "")
	if target == "" then
		return false
	end
	local prompt = "sap-nvim PROD: escribe " .. target .. " para confirmar " .. action.kind .. ": "
	local input = vim.fn.input(prompt)
	return input == target
end

local function ensure_productive_gate(args, opts)
	opts = opts or {}
	if is_local_command(args) then
		return true
	end
	local tls_reason = tls_block_reason()
	if tls_reason then
		notify(tls_reason, vim.log.levels.ERROR)
		audit("blocked", { reason = "tls", command = table.concat(args or {}, " ") })
		return false
	end
	local action = classify_sensitive(args)
	if not action then
		return true
	end
	local prod = productive()
	if profile_name() ~= "prod" then
		audit("allowed", { action_kind = action.kind, target = action.target, command = table.concat(args or {}, " ") })
		return true
	end
	if prod.read_only == true then
		notify("Perfil prod en solo lectura: bloqueado " .. action.kind .. " " .. tostring(action.target or ""), vim.log.levels.ERROR)
		audit("blocked", { reason = "read_only", action_kind = action.kind, target = action.target, command = table.concat(args or {}, " ") })
		return false
	end
	if prod[action.allow] ~= true then
		notify("Perfil prod bloquea " .. action.kind .. ". Habilita productive." .. action.allow .. "=true como opt-in explícito.", vim.log.levels.ERROR)
		audit("blocked", { reason = "opt_in", action_kind = action.kind, target = action.target, command = table.concat(args or {}, " ") })
		return false
	end
	if not confirm_exact(action) then
		notify("Confirmación cancelada para " .. action.kind .. ".", vim.log.levels.WARN)
		audit("blocked", { reason = "confirm", action_kind = action.kind, target = action.target, command = table.concat(args or {}, " ") })
		return false
	end
	audit("allowed", { action_kind = action.kind, target = action.target, command = table.concat(args or {}, " ") })
	return true
end

local function ready()
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	return ok and adt_http.ready()
end

local function looks_auth_failure(text)
	text = table.concat(type(text) == "table" and text or { tostring(text or "") }, "\n")
	local low = text:lower()
	if low:match("401") or low:match("unauthorized") or low:match("nicht autorisiert") or low:match("logon failed") then
		return true
	end
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	return ok and adt_http.is_auth_error and adt_http.is_auth_error(text)
end

local function trigger_auth_failure()
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if ok and adt_http.on_auth_failure then
		adt_http.on_auth_failure()
	end
end

local function child_env(args)
	if is_local_command(args) then
		return nil
	end
	local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
	local c = ok and adt_http.creds and adt_http.creds() or nil
	if not c then
		return nil
	end
	return { SAP_USER = c.user, SAP_PASSWORD = c.pass }
end

local function merge_env(opts, env)
	if not env then
		return opts
	end
	opts = vim.tbl_extend("force", {}, opts or {})
	opts.env = vim.tbl_extend("force", opts.env or {}, env)
	return opts
end

local function with_process_env(env, fn)
	if not env then
		return fn()
	end
	local old_user, old_pass = vim.env.SAP_USER, vim.env.SAP_PASSWORD
	vim.env.SAP_USER = env.SAP_USER
	vim.env.SAP_PASSWORD = env.SAP_PASSWORD
	local ok, a, b, c = pcall(fn)
	vim.env.SAP_USER = old_user
	vim.env.SAP_PASSWORD = old_pass
	if not ok then
		error(a)
	end
	return a, b, c
end

function M.ensure_ready(args, opts)
	opts = opts or {}
	if is_local_command(args) then
		return true
	end
	if not ensure_productive_gate(args, opts) then
		return false
	end
	if opts.allow_unvalidated then
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

M._classify_sensitive = classify_sensitive
M._ensure_productive_gate = ensure_productive_gate

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
	local auth_probe = {}
	local user_stdout = opts.on_stdout
	local user_stderr = opts.on_stderr
	local user_exit = opts.on_exit
	opts = vim.tbl_extend("force", {}, opts)
	opts.on_stdout = function(job, data, event)
		for _, line in ipairs(data or {}) do
			if line ~= "" then auth_probe[#auth_probe + 1] = line end
		end
		if user_stdout then user_stdout(job, data, event) end
	end
	opts.on_stderr = function(job, data, event)
		for _, line in ipairs(data or {}) do
			if vim.trim(line) ~= "" then auth_probe[#auth_probe + 1] = line end
		end
		if user_stderr then user_stderr(job, data, event) end
	end
	opts.on_exit = function(job, code, event)
		if not is_local_command(args) and looks_auth_failure(auth_probe) then
			trigger_auth_failure()
		end
		if user_exit then user_exit(job, code, event) end
	end
	opts = merge_env(opts, child_env(args))
	return vim.fn.jobstart(args, opts)
end

function M.system(args, input, gate_opts)
	if not M.ensure_ready(args, gate_opts) then
		return ""
	end
	return with_process_env(child_env(args), function()
		local out = vim.fn.system(args, input)
		if not is_local_command(args) and looks_auth_failure(out) then
			trigger_auth_failure()
		end
		return out
	end)
end

function M.systemlist(args, input, gate_opts)
	if not M.ensure_ready(args, gate_opts) then
		return {}
	end
	return with_process_env(child_env(args), function()
		local out = vim.fn.systemlist(args, input)
		if not is_local_command(args) and looks_auth_failure(out) then
			trigger_auth_failure()
		end
		return out
	end)
end

return M
