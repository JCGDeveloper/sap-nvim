-- lua/sap-nvim/core/cts.lua
-- Gestión de órdenes de transporte (CTS) por ADT directo.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
	end)
end

local function xmlesc(s)
	return (tostring(s or "")):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function parse_exception(body)
	if not body or body == "" then
		return nil
	end
	if not body:find("exception", 1, true) and not body:find("<message", 1, true) then
		return nil
	end
	local msg = body:match("<message[^>]*>([^<]*)</message>") or body:match("<.->([^<]+)</.-exception>") or "error ADT"
	return (msg:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

local function confirm_destructive(id, prompt, cb)
	local ok_cfg, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	if ok_cfg and cfg and cfg.confirm_destructive then
		vim.ui.input({ prompt = prompt .. " Escribe '" .. id .. "' para confirmar: " }, function(input)
			cb(input and vim.trim(input):upper() == id:upper())
		end)
		return
	end
	vim.ui.select({ "No", "Sí" }, { prompt = prompt }, function(choice)
		cb(choice and choice:match("^Sí") ~= nil)
	end)
end

local function current_object()
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sap_obj
	local uri
	local ok, intel = pcall(require, "sap-nvim.core.intel")
	if ok and intel.object_uri then
		uri = intel.object_uri(bufnr)
	end
	local pkg = (meta and meta.package) or ""
	return uri and uri:gsub("%?.*$", ""), pkg
end

local function present_requests(body, title)
	local err = parse_exception(body)
	if err then
		notify("Error: " .. err, vim.log.levels.ERROR)
		return
	end

	local items, seen = {}, {}
	for req in (body or ""):gmatch("<tm:request%s(.-)>") do
		local number = req:match('tm:number="([^"]*)"')
		local desc = req:match('tm:desc="([^"]*)"')
		local status = req:match('tm:status="([^"]*)"')
		local owner = req:match('tm:owner="([^"]*)"')

		if number and number ~= "" and not seen[number] then
			seen[number] = true
			items[#items + 1] = string.format(
				"%-12s [%s] %-10s %s",
				number,
				status or "?",
				owner or "",
				(desc or ""):gsub("&amp;", "&")
			)
		end
	end

	if #items == 0 then
		notify(title .. " sin resultados.", vim.log.levels.WARN)
		return
	end

	vim.ui.select(items, { prompt = title }, function(choice)
		if not choice then
			return
		end
		local n = choice:match("^(%S+)")
		if n then
			pcall(vim.fn.setreg, "+", n)
			notify("Orden " .. n .. " copiada al portapapeles.")
		end
	end)
end

-- ── Función Maestra de Búsqueda (Motor Unificado VS Code) ────────────────────
local function fetch_transports_by_config(user_filter, title)
	if not adt_http.is_available() then
		return
	end
	notify("Consultando configuración de búsqueda en SAP...")

	local cfg_mt = "application/vnd.sap.adt.configuration.v1+xml"
	local cfg_path = "/sap/bc/adt/cts/transportrequests/searchconfiguration/configurations"

	local resp, _, code = adt_http.raw({ method = "POST", path = cfg_path, accept = cfg_mt })

	if not tostring(code):match("^2") or not resp or resp == "" then
		notify("No se pudo crear la config de búsqueda (HTTP " .. tostring(code) .. ")", vim.log.levels.ERROR)
		return
	end

	local link = resp:match('href="([^"]*)"')
	local etag = resp:match('etag="([^"]*)"')
	if not link then
		return
	end

	local xml_decl = '<?xml version="1.0" encoding="UTF-8"?>\n'
	-- Inyectamos el usuario que queremos buscar (vacío para todos, tu usuario para las tuyas)
	local cbody = resp:gsub(
		'(<configuration:property key="User">)[^<]*(</configuration:property>)',
		"%1" .. xmlesc(user_filter) .. "%2"
	)
	if not cbody:match("^%s*<%?xml") then
		cbody = xml_decl .. cbody
	end

	local _, _, put_code = adt_http.raw({
		method = "PUT",
		path = link,
		body = cbody,
		content_type = cfg_mt,
		accept = cfg_mt,
		headers = { "If-Match: " .. (etag or "") },
	})

	notify("Descargando " .. title:lower() .. "...")

	adt_http.request_async({
		method = "GET",
		path = "/sap/bc/adt/cts/transportrequests",
		query = { configUri = link, targets = "true" },
		accept = "application/vnd.sap.adt.transportorganizertree.v1+xml",
	}, function(tbody)
		vim.schedule(function()
			present_requests(tbody, title)
		end)
	end)
end

-- ── 1. Crear Orden ───────────────────────────────────────────────────────────
function M.create_transport()
	if not adt_http.ready() then
		notify("Conexión SAP no validada. Usa :SapLogin.", vim.log.levels.WARN)
		return
	end
	-- NO exige estar dentro de un objeto: si hay uno abierto, lo usamos como referencia; si
	-- no, se crea la orden referida al PAQUETE (su URI ADT es una referencia válida para el
	-- endpoint de creación), igual que crear una orden "suelta" en SE01/SE10.
	local ref, pkg = current_object()

	local function ask_pkg(cb)
		if pkg and pkg ~= "" then
			cb(pkg)
		else
			vim.ui.input({ prompt = "Paquete (DEVCLASS): " }, function(p)
				if p and vim.trim(p) ~= "" then
					cb(p:upper())
				end
			end)
		end
	end

	ask_pkg(function(devclass)
		-- Referencia del objeto: el objeto abierto, o el paquete si no hay ninguno.
		local objref = (ref and ref ~= "") and ref or ("/sap/bc/adt/packages/" .. devclass:lower())
		vim.ui.input({ prompt = "Descripción de la orden: " }, function(desc)
			if not desc or vim.trim(desc) == "" then
				return
			end
			local body = '<?xml version="1.0" encoding="UTF-8"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
				.. "<DEVCLASS>"
				.. xmlesc(devclass)
				.. "</DEVCLASS>"
				.. "<REQUEST_TEXT>"
				.. xmlesc(desc)
				.. "</REQUEST_TEXT>"
				.. "<REF>"
				.. xmlesc(objref)
				.. "</REF><OPERATION>I</OPERATION></DATA></asx:values></asx:abap>"

			notify("Creando orden de transporte…")
			local resp, _, code = adt_http.raw({
				method = "POST",
				path = "/sap/bc/adt/cts/transports",
				accept = "text/plain",
				content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.CreateCorrectionRequest",
				body = body,
			})
			local err = parse_exception(resp)
			if err or not (tostring(code):match("^2")) then
				notify("Error (HTTP " .. tostring(code) .. "): " .. (err or "ver SAP"), vim.log.levels.ERROR)
				return
			end

			local number = (resp or ""):gsub("%s+$", ""):match("([^/]+)$") or vim.trim(resp or "")
			notify("Orden creada: " .. number)
			pcall(vim.fn.setreg, "+", number)
		end)
	end)
end

-- ── 2. Eliminar Orden (NUEVO) ────────────────────────────────────────────────
function M.delete_transport()
	if not adt_http.ready() then
		notify("Conexión SAP no validada. Usa :SapLogin.", vim.log.levels.WARN)
		return
	end

	-- Sugerimos lo que haya en el portapapeles si parece una orden (ej. S4HK900123)
	local clipboard = vim.fn.getreg("+")
	local default_tr = clipboard:match("^[A-Z0-9]+K[0-9]+$") and clipboard or ""

	vim.ui.input({ prompt = "Número de orden a ELIMINAR: ", default = default_tr }, function(tr)
		if not tr or vim.trim(tr) == "" then
			return
		end
		tr = vim.trim(tr):upper()

		confirm_destructive(tr, "PELIGRO: borrar la orden " .. tr .. ".", function(confirm)
			if not confirm then
				notify("Operación cancelada.", vim.log.levels.INFO)
				return
			end

			notify("Eliminando orden " .. tr .. "...")
			local resp, _, code = adt_http.raw({
				method = "DELETE",
				path = "/sap/bc/adt/cts/transportrequests/" .. tr,
				accept = "application/vnd.sap.as+xml",
			})

			local err = parse_exception(resp)
			if err or not tostring(code):match("^2") then
				notify(
					"No se pudo eliminar (HTTP " .. tostring(code) .. "): " .. (err or "Error de SAP"),
					vim.log.levels.ERROR
				)
			else
				notify("Orden " .. tr .. " eliminada con éxito.", vim.log.levels.INFO)
			end
		end)
	end)
end

-- ── 3. Listados (Unificados) ─────────────────────────────────────────────────
function M.list_transports()
	if not adt_http.ready() then
		notify("Conexión SAP no validada. Usa :SapLogin.", vim.log.levels.WARN)
		return
	end
	local c = adt_http.creds()
	local user = (c and c.user or ""):upper()
	fetch_transports_by_config(user, "Mis órdenes de transporte")
end

function M.list_all_transports()
	if not adt_http.ready() then
		notify("Conexión SAP no validada. Usa :SapLogin.", vim.log.levels.WARN)
		return
	end
	fetch_transports_by_config("", "Todas las órdenes del sistema")
end

function M.setup()
	vim.api.nvim_create_user_command("SapCreateTransport", function()
		M.create_transport()
	end, { desc = "CTS: Crear orden" })
	vim.api.nvim_create_user_command("SapListTransports", function()
		M.list_transports()
	end, { desc = "CTS: Mis órdenes" })
	vim.api.nvim_create_user_command("SapListAllTransports", function()
		M.list_all_transports()
	end, { desc = "CTS: Todas las órdenes" })
	vim.api.nvim_create_user_command("SapDeleteTransport", function()
		M.delete_transport()
	end, { desc = "CTS: Eliminar orden" })

	vim.keymap.set("n", "<leader>ct", function()
		M.create_transport()
	end, { desc = "CTS: Crear orden" })
	vim.keymap.set("n", "<leader>cl", function()
		M.list_transports()
	end, { desc = "CTS: Mis órdenes" })
	vim.keymap.set("n", "<leader>cL", function()
		M.list_all_transports()
	end, { desc = "CTS: Todas las órdenes" })
	vim.keymap.set("n", "<leader>cx", function()
		M.delete_transport()
	end, { desc = "CTS: Eliminar orden" }) -- x de eXecute/eXterminate
end

return M
