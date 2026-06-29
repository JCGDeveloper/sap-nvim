-- Transacciones (TCODE): ver definición, dónde se usa y borrar (SE93).
--
-- Ruta de lectura preferente: ADT directo (TRAN/T, metadata VIT), con fallback a sapcli.
-- Firmas sapcli:
--   sapcli transaction read NAME
--   sapcli transaction whereused NAME
--   sapcli transaction delete NAME [--corrnr T]

local M = {}
local source = require("sap-nvim.core.source")
local sapcli = require("sap-nvim.core.sapcli")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function unxml(s)
	return (s or "")
		:gsub("&lt;", "<")
		:gsub("&gt;", ">")
		:gsub("&quot;", '"')
		:gsub("&apos;", "'")
		:gsub("&#x0A;", "\n")
		:gsub("&#x0D;", "\r")
		:gsub("&#10;", "\n")
		:gsub("&#13;", "\r")
		:gsub("&amp;", "&")
end

local function url_part(s)
	return tostring(s or ""):gsub("([^%w_%-%.~])", function(c)
		return string.format("%%%02X", string.byte(c))
	end)
end

local function uri_path(uri)
	uri = tostring(uri or "")
	if uri == "" then
		return nil
	end
	local path = uri:match("^https?://[^/]+(/.*)$") or uri
	path = path:gsub("#.*$", "")
	return path ~= "" and path or nil
end

local function pretty_xml(xml)
	return vim.split(unxml(xml):gsub("><", ">\n<"):gsub("\r", ""), "\n", { plain = true })
end

local function remote_delete_allowed()
	local ok, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	return ok and cfg.allow_delete_objects == true
end

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
local function show(bufname, lines, ft)
	local b = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.bo[b].modifiable = false
	vim.bo[b].buftype = "nofile"
	if ft then
		vim.bo[b].filetype = ft
	end
	pcall(vim.api.nvim_buf_set_name, b, bufname)
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, b)
	pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
	vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- Ejecuta sapcli async, acumula stdout/stderr y al terminar invoca on_done(code, stdout, stderr).
local function run(args, on_done)
	local stdout, stderr = {}, {}
	sapcli.jobstart(args, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(stdout, line)
				end
			end
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if vim.trim(line) ~= "" then
					table.insert(stderr, line)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				on_done(code, stdout, stderr)
			end)
		end,
	})
end

local function transaction_vit_uri(name)
	return "/sap/bc/adt/vit/wb/object_type/" .. url_part("TRAN  "):lower() .. "/object_name/" .. url_part(name:upper())
end

local function read_adt_uri(uri)
	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if not (ok_http and adt_http.ready()) then
		return nil
	end
	local path = uri_path(uri)
	if not path then
		return nil
	end
	local body, _, code = adt_http.raw({
		method = "GET",
		path = path,
		accept = "application/xml, application/vnd.sap.adt.vit.v1+xml, application/*",
	})
	if code < 200 or code >= 300 or not body or body == "" or adt_http.is_auth_error(body) then
		return nil
	end
	if body:find("<exc:exception", 1, true) or body:find("<exception", 1, true) then
		return nil
	end
	return body
end

local function show_adt_definition(name, body)
	local lines = pretty_xml(body)
	if #lines == 0 then
		return false
	end
	show("sap-tran://" .. name, lines, "xml")
	return true
end

local function read_transaction_adt(name, opts, cb)
	opts = opts or {}
	local direct = read_adt_uri(opts.uri)
	if direct and show_adt_definition(name, direct) then
		return cb(true)
	end

	direct = read_adt_uri(transaction_vit_uri(name))
	if direct and show_adt_definition(name, direct) then
		return cb(true)
	end

	local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
	if not (ok_adt and adt.find_objects_async) then
		return cb(false)
	end
	adt.find_objects_async(name, function(rows)
		local uri
		for _, r in ipairs(rows or {}) do
			if (r.type or "") == "TRAN/T" and (r.name or ""):upper() == name then
				uri = r.uri
				break
			end
		end
		local body = uri and read_adt_uri(uri) or nil
		if body and show_adt_definition(name, body) then
			cb(true)
		else
			cb(false)
		end
	end)
end

-- VER la definición de una transacción (SE93) con `transaction read`.
function M.view(name, opts)
	if not name or name == "" then
		return
	end
	name = name:upper()
	opts = opts or {}

	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if ok_http and not adt_http.ready() then
		require("sap-nvim.core.connection").ensure(function(ok)
			if ok then
				M.view(name, opts)
			end
		end)
		return
	end

	notify("Leyendo transacción " .. name .. " por ADT...")
	read_transaction_adt(name, opts, function(done)
		if done then
			return
		end
		notify("ADT no pudo leer " .. name .. ". Probando fallback sapcli...", vim.log.levels.WARN)
		run({ "sapcli", "transaction", "read", name }, function(code, stdout, stderr)
			if code ~= 0 or #stdout == 0 then
				local msg = #stderr > 0 and stderr[1] or ("No se pudo leer la transacción " .. name)
				notify(msg, vim.log.levels.ERROR)
				return
			end
			show("sap-tran://" .. name, stdout)
		end)
	end)
end

-- VER dónde se usa una transacción con `transaction whereused`.
function M.where_used(name)
	if not name or name == "" then
		return
	end
	name = name:upper()
	notify("Buscando usos de la transacción " .. name .. "...")
	run({ "sapcli", "transaction", "whereused", name }, function(code, stdout, stderr)
		if code ~= 0 or #stdout == 0 then
			local msg = #stderr > 0 and stderr[1] or ("Sin usos o no accesible para " .. name)
			notify(msg, vim.log.levels.WARN)
			return
		end
		show("sap-tran-usos://" .. name, stdout)
	end)
end

-- BORRAR una transacción (§7 destructivo): confirma y resuelve transporte.
function M.delete(name)
	if not remote_delete_allowed() then
		notify(
			"Borrado remoto desactivado por seguridad. Para habilitarlo: productive.allow_delete_objects = true.",
			vim.log.levels.WARN
		)
		return
	end
	if not name or name == "" then
		return
	end
	name = name:upper()
	vim.ui.input({ prompt = "Borrar transacción " .. name .. ". Escribe '" .. name .. "' para confirmar: " }, function(input)
		if vim.trim(input or ""):upper() ~= name then
			return
		end

		source.resolve_transport(function(corrnr)
			local args = { "sapcli", "transaction", "delete", name }
			if corrnr then
				vim.list_extend(args, { "--corrnr", corrnr })
			end

			notify("Borrando transacción " .. name .. (corrnr and (" [" .. corrnr .. "]") or "") .. "...")
			run(args, function(code, _, stderr)
				if code == 0 then
					notify("Transacción borrada: " .. name)
				else
					local msg = #stderr > 0 and stderr[1] or ("Error borrando " .. name)
					notify(msg, vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

-- Resuelve el nombre de la transacción: argumento -> <cword> (si parece TCODE) -> input.
local function resolve_name(arg, cb)
	if arg and arg ~= "" then
		cb(arg)
		return
	end
	local w = vim.fn.expand("<cword>")
	if w and #w >= 3 and w:match("^[%w_/]+$") then
		cb(w)
		return
	end
	vim.ui.input({ prompt = "Transacción (TCODE): " }, function(v)
		if v and v ~= "" then
			cb(v)
		end
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("SapTransactionView", function(a)
		resolve_name(a.args, M.view)
	end, { desc = "sap-nvim: Ver definición de una transacción (SE93)", nargs = "?" })

	vim.api.nvim_create_user_command("SapTransactionWhereUsed", function(a)
		resolve_name(a.args, M.where_used)
	end, { desc = "sap-nvim: Dónde se usa una transacción", nargs = "?" })

	vim.api.nvim_create_user_command("SapTransactionDelete", function(a)
		resolve_name(a.args, M.delete)
	end, { desc = "sap-nvim: Borrar una transacción (SE93)", nargs = "?" })
end

return M
