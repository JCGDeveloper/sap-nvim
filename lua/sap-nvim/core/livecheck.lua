-- sap-nvim.core.livecheck
-- Pruebas vivas no destructivas contra SAP para validar el stack real:
-- login ADT, endpoints ADT, daemon, sapcli wrapper y visibilidad básica.

local M = {}

local function open_report(lines)
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modified = false
	vim.bo[buf].bufhidden = "wipe"
	local width = 86
	local height = math.min(#lines + 2, vim.o.lines - 6)
	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = width,
		height = height,
		row = math.floor((vim.o.lines - height) / 2),
		col = math.floor((vim.o.columns - width) / 2),
		style = "minimal",
		border = "rounded",
		title = " :SapLiveCheck — pruebas vivas SAP (solo lectura) ",
		title_pos = "center",
	})
	vim.wo[win].cursorline = true
	vim.keymap.set("n", "q", "<cmd>q<CR>", { buffer = buf, nowait = true })
	vim.keymap.set("n", "<Esc>", "<cmd>q<CR>", { buffer = buf, nowait = true })
end

local function okmark(ok)
	return ok and "  ✅ " or "  ❌ "
end

local function first_line(lines)
	for _, l in ipairs(lines or {}) do
		if vim.trim(l) ~= "" then
			return vim.trim(l)
		end
	end
	return nil
end

local function classify_error(text)
	text = tostring(text or ""):lower()
	if text:match("401") or text:match("unauthorized") or text:match("nicht autorisiert") then
		return "login rechazado; ejecuta :SapRelogin"
	end
	if text:match("403") or text:match("forbidden") or text:match("s_adt") or text:match("s_develop") then
		return "autorización insuficiente; revisar SU53/STAUTHTRACE"
	end
	if text:match("timeout") or text:match("could not resolve") or text:match("connection") then
		return "red/ICM/TLS; revisar host, puerto, VPN y certificado"
	end
	return nil
end

local function run_sapcli(label, args, results, done)
	local sapcli = require("sap-nvim.core.sapcli")
	local out = {}
	sapcli.jobstart(args, {
		on_stdout = function(_, data)
			for _, line in ipairs(data or {}) do
				if line ~= "" then
					out[#out + 1] = line
				end
			end
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data or {}) do
				if vim.trim(line) ~= "" then
					out[#out + 1] = line
				end
			end
		end,
		on_exit = function(_, code)
			local detail = first_line(out)
			local suffix = detail and ("  → " .. detail) or ""
			local hint = code ~= 0 and classify_error(table.concat(out, "\n")) or nil
			if hint then
				suffix = suffix .. "  [" .. hint .. "]"
			end
			table.insert(results, okmark(code == 0) .. label .. suffix)
			done()
		end,
	})
end

local function run_adt_raw(label, opts, validator, results)
	local adt = require("sap-nvim.core.adt_http")
	local body, _, code = adt.raw(opts)
	local ok = code >= 200 and code < 400 and (not validator or validator(body))
	local suffix = "  → HTTP " .. tostring(code)
	if not ok then
		local hint = classify_error((body or "") .. " " .. tostring(code))
		if hint then
			suffix = suffix .. "  [" .. hint .. "]"
		end
	end
	table.insert(results, okmark(ok) .. label .. suffix)
	return ok, body, code
end

local function readiness_summary(cfg)
	local sec = cfg.security()
	local prod = cfg.productive()
	local profile = cfg.profile_name and cfg.profile_name() or "dev"
	local ok_adt, adt = pcall(require, "sap-nvim.core.adt_http")
	local ready = ok_adt and adt.ready and adt.ready() == true
	local needs_login = ok_adt and adt.needs_login and adt.needs_login() == true
	local state = ready and "validada"
		or (needs_login and "pausada/no validada; posible 401 previo")
		or "no validada"
	local ctx = ok_adt and adt.context_info and adt.context_info() or nil
	local context = ctx and (tostring(ctx.sysid or "???") .. "/" .. tostring(ctx.client or "???") .. "/" .. tostring(ctx.user or "???"))
		or "sin contexto visible"
	return {
		"Perfil: " .. profile:upper()
			.. "  Contexto: " .. context
			.. "  Conexión: " .. state,
		"Seguridad: TLS verify=" .. tostring(sec.verify_tls == true)
			.. "  ca_file=" .. tostring(sec.ca_file and sec.ca_file ~= "" and vim.fn.expand(sec.ca_file) or "trust-store")
			.. "  safe_mode=" .. tostring(prod.safe_mode == true)
			.. "  read_only=" .. tostring(prod.read_only == true),
		"Bloqueos: create=" .. tostring(prod.allow_create_objects ~= true)
			.. "  write/activate=" .. tostring(prod.allow_write_objects ~= true)
			.. "  release=" .. tostring(prod.allow_release_transports ~= true)
			.. "  delete=" .. tostring(prod.allow_delete_objects ~= true and prod.allow_delete_transports ~= true),
	}
end

function M.run()
	local cfg = require("sap-nvim.core.config")
	local results = {
		"Objetivo: validar el entorno real sin crear, activar, bloquear ni borrar objetos.",
	}
	for _, line in ipairs(readiness_summary(cfg)) do
		table.insert(results, line)
	end
	table.insert(results, "")

	require("sap-nvim.core.connection").ensure(function(login_ok)
		if not login_ok then
			table.insert(results, "  ❌ Login SAP no validado. Ejecuta :SapLogin o :SapRelogin.")
			table.insert(results, "")
			table.insert(results, "  q / <Esc> para cerrar.")
			vim.schedule(function()
				open_report(results)
			end)
			return
		end

		table.insert(results, "ADT directo:")
		run_adt_raw("Discovery ADT", {
			method = "GET",
			path = "/sap/bc/adt/core/discovery",
			accept = "application/atomsvc+xml, application/xml;q=0.9, */*;q=0.8",
		}, function(body)
			return tostring(body or ""):find("collection", 1, true) ~= nil
				or tostring(body or ""):find("service", 1, true) ~= nil
		end, results)

		run_adt_raw("Information System search (*)", {
			method = "GET",
			path = "/sap/bc/adt/repository/informationsystem/search",
			query = { query = "*", maxResults = "5", operation = "quickSearch" },
			accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
		}, function(body)
			return body ~= nil and body ~= ""
		end, results)

		local adt = require("sap-nvim.core.adt_http")
		adt.daemon_self_test({
			method = "GET",
			path = "/sap/bc/adt/repository/informationsystem/search",
			query = { query = "*", maxResults = "1", operation = "quickSearch" },
			accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
		}, function(body, latency)
			table.insert(results, okmark(body ~= nil and body ~= "") .. "Daemon ADT keep-alive  → " .. tostring(latency or "?"))
			table.insert(results, "")
			table.insert(results, "sapcli wrapper (solo lectura):")

			local checks = {
				{ "System info", { "sapcli", "abap", "systeminfo" } },
				{ "Objetos inactivos visibles", { "sapcli", "activation", "inactiveobjects", "list" } },
				{ "Transportes visibles", { "sapcli", "cts", "list", "transport" } },
			}
			local i = 0
			local function next_check()
				i = i + 1
				local c = checks[i]
				if not c then
					table.insert(results, "")
					table.insert(results, "Resultado esperado en productivo: puede haber ❌ por roles, pero no debe haber 401 repetido ni bloqueo.")
					table.insert(results, "  q / <Esc> para cerrar.")
					vim.schedule(function()
						open_report(results)
					end)
					return
				end
				run_sapcli(c[1], c[2], results, next_check)
			end
			next_check()
		end)
	end)
end

M._readiness_summary = readiness_summary

function M.setup()
	vim.api.nvim_create_user_command("SapLiveCheck", M.run, {
		desc = "sap-nvim: pruebas vivas no destructivas contra SAP",
	})
end

return M
