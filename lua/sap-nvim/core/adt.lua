-- sap-nvim.core.adt
-- Cliente ADT para conexión y operaciones con sistemas SAP remotos

local M = {
	connections = {},
	current = nil,
}
local sapcli = require("sap-nvim.core.sapcli")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function xmlesc(s)
	return (tostring(s or ""))
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;")
end

local function unxml(s)
	return (s or ""):gsub("&lt;", "<")
		:gsub("&gt;", ">")
		:gsub("&quot;", '"')
		:gsub("&apos;", "'")
		:gsub("&#x0A;", "\n")
		:gsub("&#x0D;", "\r")
		:gsub("&#10;", "\n")
		:gsub("&#13;", "\r")
		:gsub("&amp;", "&")
end

local function xml_attr(attrs, name)
	return attrs and (
		attrs:match('[%w_:-]*' .. name .. '="([^"]*)"')
		or attrs:match(name .. '="([^"]*)"')
	) or nil
end

local ADT_TYPE_BY_GROUP = {
	class = "CLAS/OC",
	interface = "INTF/OI",
	program = "PROG/P",
	include = "PROG/I",
	functiongroup = "FUGR/F",
	functionmodule = "FUGR/FF",
	table = "TABL/DT",
	structure = "TABL/DS",
	tabletype = "TTYP/TT",
	dataelement = "DTEL/DE",
	domain = "DOMA/DO",
	ddl = "DDLS/DF",
	ddls = "DDLS/DF",
	ddlx = "DDLX/EX",
	dcl = "DCLS/DL",
	bdef = "BDEF/BDO",
	srvd = "SRVD/SRV",
}

function M.adt_type(group)
	return ADT_TYPE_BY_GROUP[group]
end

-- Mapa INVERSO: tipo ADT completo (adtcore:type, p.ej. "CLAS/OC") -> grupo de sapcli/source.
-- Lo usan los consumidores de la búsqueda ADT (navigate goto_global) para abrir el objeto sin
-- heurística frágil: la fila ADT ya trae el tipo exacto.
local GROUP_BY_ADT_TYPE = {
	["CLAS/OC"] = "class",
	["INTF/OI"] = "interface",
	["PROG/P"] = "program",
	["PROG/I"] = "include",
	["FUGR/F"] = "functiongroup",
	["FUGR/FF"] = "functionmodule",
	["FUNC/FF"] = "functionmodule",
	["TABL/DT"] = "table",
	["TABL/DS"] = "structure",
	["VIEW/DV"] = "table",
	["TTYP/TT"] = "tabletype",
	["DTEL/DE"] = "dataelement",
	["DOMA/DO"] = "domain",
	["MSAG/N"] = "messageclass",
	["DDLS/DF"] = "ddls",
	["DDLX/EX"] = "ddlx",
	["DCLS/DL"] = "dcl",
	["BDEF/BDO"] = "bdef",
	["SRVD/SRV"] = "srvd",
}

-- Grupo de sapcli/source a partir del tipo ADT. nil si no se reconoce.
function M.group_from_adt_type(adt_type)
	if not adt_type or adt_type == "" then
		return nil
	end
	local g = GROUP_BY_ADT_TYPE[adt_type]
	if g then
		return g
	end
	-- Fallback por prefijo (subtipos no listados): PROG/*, FUGR/*, y aliases de grupo.
	local prefix, sub = adt_type:match("(%u+)/(%u+)")
	prefix = prefix or adt_type:match("^(%u+)")
	if prefix == "PROG" then
		return sub == "I" and "include" or "program"
	end
	if prefix == "FUGR" then
		return sub == "F" and "functiongroup" or "functionmodule"
	end
	return ({ CLAS = "class", INTF = "interface", FUGS = "functiongroup" })[prefix or ""]
end

-- Codifica un valor para la query string de ADT, conservando el comodín `*`.
local function search_url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("[^%w_]", function(c)
		if c == "*" then
			return "*"
		end
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Parsea el XML de resultados del Information System de ADT (mismo endpoint que core/search)
-- a filas ESTRUCTURADAS. Cada <... adtcore:.../> trae name/type/uri/packageName/description.
-- Dedupe por nombre (como hace core/search.parse_body).
local function parse_search_results(body)
	local rows, seen = {}, {}
	if not body or body == "" then
		return rows
	end
	for tag in body:gmatch("<[^>]+>") do
		local name = tag:match('adtcore:name="([^"]*)"')
		local typ = tag:match('adtcore:type="([^"]*)"')
		if name and typ and not seen[name] then
			seen[name] = true
			rows[#rows + 1] = {
				name = unxml(name),
				type = unxml(typ),
				uri = unxml(tag:match('adtcore:uri="([^"]*)"') or ""),
				packageName = unxml(tag:match('adtcore:packageName="([^"]*)"') or ""),
				description = unxml(tag:match('adtcore:description="([^"]*)"') or ""),
			}
		end
	end
	return rows
end

-- Búsqueda de objetos vía ADT (el MISMO endpoint que :SapSearchLive), asíncrona y fiable
-- (no parsea texto humano de sapcli ni arriesga ráfagas de login). callback(rows, err) con
-- rows = lista de { name, type (adtcore:type p.ej. "CLAS/OC"), uri, packageName, description }.
-- `query` se manda tal cual (en mayúsculas): usa `*` para prefijo, sin `*` = coincidencia exacta.
function M.find_objects_async(query, callback)
	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if not ok_http or not adt_http.is_available() then
		return callback(nil, "ADT no disponible")
	end
	local q = (query or ""):upper():gsub("%*+", "*")
	if q == "" then
		return callback(nil, "Consulta vacía")
	end
	local path = "/sap/bc/adt/repository/informationsystem/search?query="
		.. search_url_encode(q)
		.. "&maxResults=100&operation=quickSearch"
	adt_http.request_async({
		method = "GET",
		path = path,
		accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
	}, function(body)
		vim.schedule(function()
			if not body or body == "" then
				return callback(nil, "Sin respuesta de SAP en la búsqueda")
			end
			if adt_http.is_auth_error(body) then
				return callback(nil, "Autenticación rechazada por SAP")
			end
			callback(parse_search_results(body), nil)
		end)
	end)
end

local function productive()
	local ok, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	return ok and cfg or {}
end

local function confirm_activation_bulk(objects, opts, cb)
	opts = opts or {}
	local cfg = productive()
	if opts.confirmed or not cfg.safe_mode then
		return cb(true)
	end
	local count = #(objects or {})
	if count == 0 then
		return cb(false)
	end
	local label = count == 1 and ((objects[1].name or ""):upper()) or ("ACTIVAR " .. tostring(count))
	local prompt = count == 1
		and ("Activar " .. label .. " en SAP.")
		or ("Activar " .. tostring(count) .. " objeto(s) en SAP.")
	if cfg.confirm_destructive then
		vim.ui.input({ prompt = prompt .. " Escribe '" .. label .. "' para confirmar: " }, function(input)
			cb(input and vim.trim(input):upper() == label)
		end)
	else
		vim.ui.select({ "No", "Sí" }, { prompt = prompt }, function(choice)
			cb(choice and choice:match("^Sí") ~= nil)
		end)
	end
end

function M.setup(opts)
	opts = opts or {}
	M.connections = opts.connections or {}
end

-- Read current sapcli context from config file
function M.get_current_context()
	local config_path = vim.fn.expand("~/.sapcli/config.yml")
	local f = io.open(config_path, "r")
	if not f then
		return nil
	end
	local content = f:read("*a")
	f:close()

	local current = content:match("current%-context:%s*([%w_%-]+)")
	if not current then
		return nil
	end

	local in_ctx = false
	local user = nil
	for line in content:gmatch("[^\r\n]+") do
		if line:match("^" .. vim.pesc(current) .. ":%s*$") then
			in_ctx = true
		elseif in_ctx and not line:match("^%s") then
			break
		elseif in_ctx then
			local u = line:match("^%s+user:%s*(.+)$")
			if u then
				user = vim.trim(u)
			end
		end
	end

	return { name = current, user = user }
end

-- Returns true if sapcli has a configured current-context
function M.is_configured()
	return M.get_current_context() ~= nil
end

-- Fetch packages matching a prefix pattern, e.g. "Z*" (async)
-- callback(packages, err)
function M.fetch_packages(pattern, callback)
	pattern = pattern or "Z*"
	local packages = {}
	local stderr = {}

	sapcli.jobstart({ "sapcli", "package", "list", pattern }, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				local pkg = vim.trim(line)
				if pkg ~= "" then
					table.insert(packages, pkg)
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
			if code == 0 and #packages > 0 then
				callback(packages, nil)
			else
				local err = #stderr > 0 and stderr[1] or "No packages found for: " .. pattern
				callback(nil, err)
			end
		end,
	})
end

-- Fetch open transport orders (async)
-- callback(transports, err)  — each entry is the raw sapcli output line
function M.fetch_transport_orders(callback)
	local args = { "sapcli", "cts", "list", "transport" }
	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if ok_http and not adt_http.ready() then
		callback(nil, "Conexión SAP no validada. Usa :SapLogin.")
		return
	end
	local creds = ok_http and adt_http.creds() or nil
	local ctx = M.get_current_context()
	local owner = (creds and creds.user) or (ctx and ctx.user) or nil
	if owner and owner ~= "" then
		vim.list_extend(args, { "--owner", owner:upper() })
	end

	local transports = {}
	local stderr = {}

	vim.fn.jobstart(args, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				local t = vim.trim(line)
				if t ~= "" then
					table.insert(transports, t)
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
			if code == 0 then
				callback(transports, nil)
			else
				local err = #stderr > 0 and stderr[1] or "Could not fetch transport orders"
				callback(nil, err)
			end
		end,
	})
end

-- Órdenes que el usuario puede ASIGNAR a un objeto concreto (ADT transportchecks, como hace
-- VSCode al guardar). Devuelve TODAS las accesibles (propias + compartidas/tareas en órdenes
-- de otros), no solo las del owner. callback(list, err) — item: "TRKORR  descripción  (user)".
function M.fetch_object_transports(source_uri, devclass, callback)
	local adt_http = require("sap-nvim.core.adt_http")
	if not adt_http.ready() then
		callback(nil, "Conexión SAP no validada. Usa :SapLogin.")
		return
	end
	local uri = (source_uri or ""):gsub("%?.*$", "")
	if uri == "" then
		callback(nil, "sin URI de objeto")
		return
	end
	local mt = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.transport.service.checkData"
	local body = '<?xml version="1.0" encoding="UTF-8"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
		.. "<DEVCLASS>"
		.. (devclass or "")
		.. "</DEVCLASS><OPERATION>I</OPERATION><URI>"
		.. uri
		.. "</URI></DATA></asx:values></asx:abap>"
	-- raw es síncrono pero gestiona CSRF/cookies de forma fiable; el push es acción puntual.
	local resp, _, code = adt_http.raw({
		method = "POST",
		path = "/sap/bc/adt/cts/transportchecks",
		accept = mt,
		content_type = mt:gsub(";", "; "),
		body = body,
	})
	if code < 200 or code >= 300 or not resp or resp == "" then
		callback(nil, "transportchecks falló (HTTP " .. tostring(code) .. ")")
		return
	end
	if resp:find("<exc:exception", 1, true) or resp:find("<exception", 1, true) then
		local msg = resp:match("<message[^>]*>([^<]*)</message>") or "excepción ADT en transportchecks"
		callback(nil, msg:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
		return
	end
	local out = {}
	for req in resp:gmatch("<CTS_REQUEST>(.-)</CTS_REQUEST>") do
		local trkorr = req:match("<TRKORR>([^<]*)</TRKORR>")
		local text = req:match("<AS4TEXT>([^<]*)</AS4TEXT>")
		local user = req:match("<AS4USER>([^<]*)</AS4USER>")
		if trkorr and trkorr ~= "" then
			out[#out + 1] =
				string.format("%s  %s%s", trkorr, text or "", (user and user ~= "" and ("  (" .. user .. ")")) or "")
		end
	end
	callback(out, nil)
end

-- Fallback DEGRADADO: búsqueda por sapcli (texto humano) cuando ADT no está disponible.
local function fetch_objects_sapcli(query, callback)
	local results = {}
	local stderr = {}

	sapcli.jobstart({ "sapcli", "abap", "find", query }, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				local t = vim.trim(line)
				if t ~= "" then
					table.insert(results, t)
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
			if code == 0 then
				callback(results, nil)
			else
				local err = #stderr > 0 and stderr[1] or "Search failed for: " .. query
				callback(nil, err)
			end
		end,
	})
end

-- Search ABAP objects by name pattern (async). Ruta PRINCIPAL: ADT (find_objects_async);
-- fallback degradado a sapcli si ADT no está disponible.
-- callback(results, err) — results = lista de STRINGS en formato tabla "TIPO | NOMBRE | DESCR"
-- (col1 = adtcore:type p.ej. "CLAS/OC"), el shape que esperan sus llamadores (browser,
-- intel.fetch_objects, type_resolver.parse_ddic_output).
function M.fetch_objects(query, callback)
	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if not (ok_http and adt_http.is_available()) then
		return fetch_objects_sapcli(query, callback)
	end
	M.find_objects_async(query, function(rows, err)
		if not rows then
			return callback(nil, err)
		end
		local out = {}
		for _, r in ipairs(rows) do
			out[#out + 1] = string.format("%s | %s | %s", r.type, r.name, r.description or "")
		end
		callback(out, nil)
	end)
end

-- Seleccionar conexión activa
function M.select_connection(name)
	if M.connections[name] then
		M.current = M.connections[name]
		vim.notify(("sap-nvim: Conexión '%s' seleccionada"):format(name))
	else
		vim.notify(("sap-nvim: Conexión '%s' no encontrada"):format(name), vim.log.levels.ERROR)
	end
end

-- Parse sapcli activation / write output into quickfix entries.
--
-- sapcli emite los hallazgos de activación en bloques:
--     -- Programa ZCAR_X            <- línea de contexto (objeto/include)
--        E: The statement "FOO" is invalid. ...   <- error
--        W: incorrect syntax.                      <- warning
-- SIN número de línea. Para poder saltar, si el mensaje trae un token entre
-- comillas ("FOO") y se pasa `bufnr`, se busca ese token en el buffer y se usa
-- esa línea. Se mantienen además los formatos clásicos con número de línea.
--
-- Devuelve entradas de quickfix con type "E" (error) o "W" (warning).
function M._parse_activation_errors(lines, filename, bufnr)
	local qf = {}
	local context = nil

	-- Formatos clásicos con número de línea (fallback).
	local num_patterns = {
		function(l)
			return l:match("[Ll]ine%s+(%d+):%s*(.+)")
		end,
		function(l)
			return l:match("[Rr]ow%s+(%d+):%s*(.+)")
		end,
		function(l)
			return l:match("%((%d+),%d+%):%s*(.+)")
		end,
		function(l)
			return l:match("%((%d+)%):%s*(.+)")
		end,
		function(l)
			local n = l:match("[Ee]rror%s+at%s+[Ll]ine%s+(%d+)")
			if n then
				return n, l
			end
		end,
		function(l)
			return l:match("^%s*(%d+):%s+(.+)")
		end,
	}

	-- Nombre del objeto del buffer (si es un objeto remoto) para saber qué mensajes le
	-- pertenecen: un error en "Include X" NO es de este buffer (el programa principal).
	local buf_obj = (bufnr and vim.api.nvim_buf_is_valid(bufnr) and vim.b[bufnr].sap_obj) or nil

	local function belongs_to_buffer(ctx)
		if not ctx then
			return true
		end
		if buf_obj and buf_obj.name then
			return ctx:upper():find(buf_obj.name:upper(), 1, true) ~= nil
		end
		return ctx:lower():match("^include%s") == nil
	end

	-- Localiza la línea del mensaje en el buffer buscando el token entre comillas
	-- (SAP lo da en MAYÚSCULAS -> comparación case-insensitive). Solo si el mensaje
	-- pertenece a este buffer; los de includes no se pueden ubicar aquí (lnum 0).
	local function find_lnum(message, ctx)
		if not bufnr or not vim.api.nvim_buf_is_valid(bufnr) then
			return 0
		end
		if not belongs_to_buffer(ctx) then
			return 0
		end
		local tok = message:match('"([^"]+)"')
		if not tok or tok == "" then
			return 0
		end
		local needle = tok:lower()
		local blines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
		for i, l in ipairs(blines) do
			if l:lower():find(needle, 1, true) then
				return i
			end
		end
		return 0
	end

	for _, line in ipairs(lines) do
		local ctx = line:match("^%s*%-%-%s+(.+)$")
		if ctx then
			context = vim.trim(ctx)
		else
			local sev, msg = line:match("^%s*([EWew]):%s+(.+)$")
			if sev then
				local up = sev:upper()
				local text = (context and (context .. " — ") or "") .. vim.trim(msg)
				table.insert(qf, {
					filename = filename,
					lnum = up == "E" and find_lnum(msg, context) or 0,
					col = 1,
					text = text,
					type = up,
				})
			else
				for _, pat in ipairs(num_patterns) do
					local lnum, t = pat(line)
					if lnum then
						table.insert(qf, {
							filename = filename,
							lnum = tonumber(lnum),
							col = 1,
							text = vim.trim(t or line),
							type = "E",
						})
						break
					end
				end
			end
		end
	end

	-- Errores primero, warnings después (orden estable), deduplicando entradas idénticas
	-- (SAP repite el mismo mensaje de include en cascada varias veces).
	local ordered, seen = {}, {}
	local function add(e)
		local key = (e.type or "") .. "|" .. (e.lnum or 0) .. "|" .. (e.text or "")
		if not seen[key] then
			seen[key] = true
			ordered[#ordered + 1] = e
		end
	end
	for _, e in ipairs(qf) do
		if e.type == "E" then
			add(e)
		end
	end
	for _, e in ipairs(qf) do
		if e.type ~= "E" then
			add(e)
		end
	end
	return ordered
end

function M._parse_activation_response(body, filename)
	local qf = {}
	if not body or body == "" then
		return qf
	end

	local function add_from_attrs(attrs, text)
		attrs = attrs or ""
		local uri = attrs:match('[%w_:-]*uri="([^"]*)"') or attrs:match('href="([^"]*)"')
		local typ = attrs:match('[%w_:-]*type="([^"]*)"')
			or attrs:match('severity="([^"]*)"')
			or attrs:match('kind="([^"]*)"')
			or "E"
		local msg = attrs:match('shortText="([^"]*)"')
			or attrs:match('message="([^"]*)"')
			or attrs:match('text="([^"]*)"')
			or text
			or "Activation message"
		local line, col = (uri or ""):match("start=(%d+),(%d+)")
		local up = typ:upper():sub(1, 1)
		if up ~= "W" and up ~= "I" then
			up = "E"
		end
		qf[#qf + 1] = {
			filename = filename,
			lnum = tonumber(line) or 0,
			col = tonumber(col) or 1,
			text = unxml(msg),
			type = up,
		}
	end

	for attrs in body:gmatch("<[%w_:]*activationMessage%s+([^>]*)/?>") do
		add_from_attrs(attrs)
	end
	for attrs, inner in body:gmatch("<[%w_:]*activationMessage%s+([^>]-)>(.-)</[%w_:]*activationMessage>") do
		local text = inner:match("<[%w_:]*shortText[^>]*>(.-)</[%w_:]*shortText>")
			or inner:match("<[%w_:]*message[^>]*>(.-)</[%w_:]*message>")
		add_from_attrs(attrs, text)
	end
	for attrs in body:gmatch("<[%w_:]*message%s+([^>]*)/?>") do
		if attrs:match("activation") or attrs:match("shortText") or attrs:match("severity") then
			add_from_attrs(attrs)
		end
	end
	for attrs, inner in body:gmatch("<msg%s+([^>]-)>(.-)</msg>") do
		local msg = inner:match("<shortText[^>]*>%s*<txt[^>]*>(.-)</txt>%s*</shortText>")
			or inner:match("<shortText[^>]*>(.-)</shortText>")
		local href = xml_attr(attrs, "href")
		local line = xml_attr(attrs, "line")
		local typ = xml_attr(attrs, "type") or "E"
		local obj = xml_attr(attrs, "objDescr")
		local text = (obj and obj ~= "" and (unxml(obj) .. " - ") or "") .. unxml(msg or "Activation message")
		qf[#qf + 1] = {
			filename = filename,
			lnum = tonumber(line) or tonumber((href or ""):match("start=(%d+),")) or 0,
			col = tonumber((href or ""):match("start=%d+,(%d+)")) or 1,
			text = text,
			type = typ:upper():sub(1, 1) == "W" and "W" or "E",
		}
	end

	local ordered, seen = {}, {}
	for _, e in ipairs(qf) do
		local key = (e.type or "") .. "|" .. (e.lnum or 0) .. "|" .. (e.text or "")
		if not seen[key] then
			seen[key] = true
			ordered[#ordered + 1] = e
		end
	end
	return ordered
end

local function parse_inactive_objects_xml(resp)
	local objects = {}
	if not resp or resp == "" then
		return objects
	end

	for entry in resp:gmatch("<[%w_:]*entry[^>]*>(.-)</[%w_:]*entry>") do
		local obj_attrs, obj_inner = entry:match("<[%w_:]*object([^>]*)>(.-)</[%w_:]*object>")
		if obj_inner then
			local ref_attrs = obj_inner:match("<[%w_:]*ref%s+([^>]*)/?>")
				or obj_inner:match("<[%w_:]*objectReference%s+([^>]*)/?>")
			local uri = xml_attr(ref_attrs, "uri")
			local name = xml_attr(ref_attrs, "name")
			local typ = xml_attr(ref_attrs, "type")
			if uri and name and name:lower() ~= "inactive" then
				objects[#objects + 1] = {
					name = unxml(name),
					uri = unxml(uri),
					type = typ and unxml(typ) or "",
					parent_uri = unxml(xml_attr(ref_attrs, "parentUri") or ""),
					user = unxml(xml_attr(obj_attrs, "user") or ""),
					deleted = (xml_attr(obj_attrs, "deleted") == "true"),
				}
			end
		end
	end

	if #objects == 0 then
		for attrs in resp:gmatch("<[%w_:]*objectReference%s+([^>]*)/?>") do
			local uri = xml_attr(attrs, "uri")
			local name = xml_attr(attrs, "name")
			local typ = xml_attr(attrs, "type")
			if uri and name and name:lower() ~= "inactive" then
				objects[#objects + 1] = { name = unxml(name), uri = unxml(uri), type = typ and unxml(typ) or "" }
			end
		end
	end

	return objects
end
-- Activate the current ABAP object. On success clears quickfix.
-- On failure parses error lines and jumps to the first one.
-- Fetch the list of inactive objects (async)
-- callback(objects, err)
-- ========================================================================
-- MOTOR DE ACTIVACIÓN (INDIVIDUAL Y MASIVA) VÍA API ADT
-- ========================================================================

-- 1. Obtener objetos inactivos directamente desde la API nativa de SAP
function M.fetch_inactive_objects(callback)
	local adt_http = require("sap-nvim.core.adt_http")
	if not adt_http.is_available() then
		return callback(nil, "ADT no disponible")
	end

	local resp = adt_http.raw({
		method = "GET",
		path = "/sap/bc/adt/activation/inactiveobjects",
		accept = "application/vnd.sap.adt.inactivectsobjects.v1+xml, application/xml",
	})

	if not resp or resp == "" then
		-- Fallback antiguo: algunos sistemas exponen la vista por nodestructure.
		resp = adt_http.raw({
			method = "POST",
			path = "/sap/bc/adt/repository/nodestructure",
			accept = "application/xml",
			content_type = "application/xml",
			body = '<?xml version="1.0" encoding="UTF-8"?><tre:node xmlns:tre="http://www.sap.com/adt/core/tree"><tre:objectReference adtcore:uri="/workspace/inactive" xmlns:adtcore="http://www.sap.com/adt/core"/></tre:node>',
		})
	end

	if not resp or resp == "" then
		return callback(nil, "Sin respuesta del servidor SAP al pedir inactivos")
	end

	local objects = vim.tbl_filter(function(obj)
		return not obj.deleted
	end, parse_inactive_objects_xml(resp))

	callback(objects, nil)
end

-- 2. El motor que envía el bloque completo a compilar
function M.activate_bulk(selected_objects, callback, opts)
	if not selected_objects or #selected_objects == 0 then
		vim.notify("[sap-nvim] Nada que activar.", vim.log.levels.INFO)
		return
	end

	local function run_activation()
		local adt_http = require("sap-nvim.core.adt_http")
		vim.notify(string.format("[sap-nvim] Activando %d objeto(s)...", #selected_objects), vim.log.levels.INFO)

		local function payload_for(objects)
			local xml_parts = {
				'<?xml version="1.0" encoding="UTF-8"?><adtcore:objectReferences xmlns:adtcore="http://www.sap.com/adt/core">',
			}

			for _, obj in ipairs(objects) do
				table.insert(
					xml_parts,
					string.format(
						'<adtcore:objectReference adtcore:uri="%s" adtcore:name="%s" adtcore:type="%s"/>',
						xmlesc(obj.uri),
						xmlesc(obj.name),
						xmlesc(obj.type or M.adt_type(obj.group) or "")
					)
				)
			end
			table.insert(xml_parts, "</adtcore:objectReferences>")
			return table.concat(xml_parts, "")
		end

		local function send(objects, preaudit)
			local resp, headers, code = adt_http.raw({
				method = "POST",
				path = "/sap/bc/adt/activation",
				query = { method = "activate", preauditRequested = preaudit and "true" or "false" },
				accept = "application/xml",
				content_type = "application/xml",
				body = payload_for(objects),
			})
			return resp, headers, code
		end

		local resp, headers, code = send(selected_objects, true)
		if
			code >= 200
			and code < 300
			and resp
			and (
				resp:find("inactiveCtsObjects", 1, true)
				or (headers or ""):find("application/vnd.sap.adt.inactivectsobjects", 1, true)
			)
		then
			local preaudit_objects = vim.tbl_filter(function(obj)
				return not obj.deleted
			end, parse_inactive_objects_xml(resp))
			if #preaudit_objects > 0 then
				resp, headers, code = send(preaudit_objects, false)
			end
		end

		local qf = M._parse_activation_response(resp, vim.api.nvim_buf_get_name(0))
		if code < 200 or code >= 300 then
			qf[#qf + 1] = {
				filename = vim.api.nvim_buf_get_name(0),
				lnum = 0,
				col = 1,
				text = "Activación ADT falló (HTTP " .. tostring(code) .. ").",
				type = "E",
			}
		elseif resp and (resp:find("<exc:exception", 1, true) or resp:find("<exception", 1, true)) then
			qf[#qf + 1] = {
				filename = vim.api.nvim_buf_get_name(0),
				lnum = 0,
				col = 1,
				text = resp:match("<message[^>]*>([^<]*)</message>") or "Excepción ADT al activar.",
				type = "E",
			}
		end
		local errors = vim.tbl_filter(function(e)
			return e.type == "E"
		end, qf)
		if #qf == 0 and resp and resp:match("activationMessages") then
			qf[1] = {
				filename = vim.api.nvim_buf_get_name(0),
				lnum = 0,
				col = 1,
				text = "SAP devolvió mensajes de activación, pero sap-nvim no pudo parsear el detalle.",
				type = "E",
			}
			errors = qf
		end

		if #qf > 0 then
			vim.fn.setqflist({}, "r", { items = qf, title = "SAP activation" })
			if #errors > 0 then
				pcall(vim.cmd, "copen")
				pcall(vim.cmd, "cfirst")
				notify(#errors .. " error(es) al activar. Revisa quickfix.", vim.log.levels.ERROR)
			else
				notify("Activación completada con " .. #qf .. " warning(s). :copen para verlos.", vim.log.levels.WARN)
			end
		elseif resp then
			notify("Activación completada con éxito.", vim.log.levels.INFO)
		else
			notify("Error de conexión al activar.", vim.log.levels.WARN)
		end

		if callback then
			callback(resp, qf)
		end
	end

	confirm_activation_bulk(selected_objects, opts, function(confirmed)
		if not confirmed then
			vim.notify("[sap-nvim] Activación cancelada.", vim.log.levels.INFO)
			if callback then
				callback(nil, {})
			end
			return
		end
		run_activation()
	end)
end

local function include_names_from_lines(lines, seen, ordered)
	for _, raw in ipairs(lines or {}) do
		local inc = raw:match("^%s*[Ii][Nn][Cc][Ll][Uu][Dd][Ee]%s+([%w_/]+)")
		if inc then
			inc = inc:upper()
			if not seen[inc] then
				seen[inc] = true
				ordered[#ordered + 1] = inc
			end
		end
	end
end

local function add_related_name(name, seen, ordered)
	name = name and name:upper()
	if name and name ~= "" and not seen[name] then
		seen[name] = true
		ordered[#ordered + 1] = name
	end
end

local function program_name_from_uri(uri)
	return uri and uri:match("/programs/programs/([^/%?#]+)")
end

function M.related_object_names(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local seen, ordered = {}, {}
	local meta = vim.b[bufnr].sap_obj
	if meta and meta.name then
		add_related_name(meta.name, seen, ordered)
	end

	include_names_from_lines(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), seen, ordered)

	local ok_source, source = pcall(require, "sap-nvim.core.source")
	local ok_objtype, objtype = pcall(require, "sap-nvim.core.objtype")
	local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
	if ok_source and ok_objtype then
		local dir = source.cache_dir()

		if meta and meta.group == "include" and ok_intel and intel.main_programs then
			for _, uri in ipairs(intel.main_programs(meta.name) or {}) do
				local main = program_name_from_uri(uri)
				add_related_name(main, seen, ordered)
				local main_file = main and (dir .. "/" .. objtype.gitfile("program", main)) or nil
				if main_file and vim.fn.filereadable(main_file) == 0 then
					local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
					if ok_http and adt_http.is_available() then
						local body = adt_http.request({ method = "GET", path = uri .. "/source/main", accept = "text/plain" })
						if body and body ~= "" and not body:match("<exc:exception") then
							pcall(vim.fn.writefile, vim.split(body:gsub("\r", ""), "\n", { plain = true }), main_file)
						end
					end
				end
			end
		end

		local i = 1
		while i <= #ordered do
			local name = ordered[i]
			for _, group in ipairs({ "program", "include" }) do
				local p = dir .. "/" .. objtype.gitfile(group, name)
				if vim.fn.filereadable(p) == 1 then
					include_names_from_lines(vim.fn.readfile(p), seen, ordered)
				end
			end
			i = i + 1
		end
	end

	return seen, ordered
end

function M.activate_related_current(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	pcall(vim.cmd, "write")

	local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
	local meta = vim.b[bufnr].sap_obj
	local current_uri = ok_intel and intel.object_uri(bufnr) or nil
	if not current_uri then
		return M.activate_current()
	end

	local names, ordered = M.related_object_names(bufnr)
	local selected, by_uri = {}, {}
	local function add(obj)
		if not obj or not obj.uri or by_uri[obj.uri] then
			return
		end
		by_uri[obj.uri] = true
		selected[#selected + 1] = obj
	end

	add({
		name = meta and meta.name or ordered[1],
		group = meta and meta.group,
		uri = current_uri:gsub("/source/main$", ""),
		type = M.adt_type(meta and meta.group),
	})

	if meta and meta.group == "include" and ok_intel and intel.main_programs then
		for _, uri in ipairs(intel.main_programs(meta.name) or {}) do
			local main = program_name_from_uri(uri)
			add({
				name = main and main:upper() or main,
				group = "program",
				uri = uri:gsub("/source/main$", ""),
				type = M.adt_type("program"),
			})
		end
	end

	M.fetch_inactive_objects(function(objects, err)
		vim.schedule(function()
			if err then
				notify(err, vim.log.levels.ERROR)
				return
			end
			for _, obj in ipairs(objects or {}) do
				local name = (obj.name or ""):upper()
				if names[name] then
					add(obj)
				end
			end
			notify("Activando raíz + relacionados: " .. table.concat(ordered, ", "))
			M.activate_bulk(selected, nil, opts)
		end)
	end)
end

-- 3. EL FRANCOTIRADOR: Activa SOLO el buffer actual, haya lo que haya inactivo
function M.activate_current()
	local bufnr = vim.api.nvim_get_current_buf()
	local filename = vim.api.nvim_buf_get_name(bufnr)
	local objtype = require("sap-nvim.core.objtype")
	local meta = vim.b[bufnr].sap_obj
	local group = meta and meta.group or objtype.group(filename)
	local obj_name = meta and meta.name or objtype.name(filename)

	if obj_name == "" then
		return vim.notify("[sap-nvim] No hay un objeto ABAP válido para activar aquí.", vim.log.levels.WARN)
	end

	-- Guardamos el archivo antes de activar
	pcall(vim.cmd, "write")

	-- Buscamos SU propia URI exacta usando el motor de intel
	local intel = require("sap-nvim.core.intel")
	local uri = intel.object_uri(bufnr)

	if not uri then
		return vim.notify("[sap-nvim] No se pudo resolver la URI del objeto actual.", vim.log.levels.ERROR)
	end

	-- Lo empaquetamos como un único objeto y lo mandamos a activar
	local current_obj = {
		name = obj_name,
		uri = uri,
		group = group,
		type = M.adt_type(group),
	}

	M.activate_bulk({ current_obj })
end

-- 4. EL GESTOR: Muestra el menú para elegir qué activar de todo el Workspace
function M.activate_ui()
	pcall(vim.cmd, "write")

	M.fetch_inactive_objects(function(objects, err)
		if err or not objects or #objects == 0 then
			vim.notify("[sap-nvim] No tienes objetos inactivos en el sistema.", vim.log.levels.INFO)
			return
		end

		local items = { ">> ACTIVAR TODOS JUNTOS (Bloque transaccional)" }
		for _, obj in ipairs(objects) do
			table.insert(items, string.format("%s [%s]", obj.name, obj.type))
		end

		vim.ui.select(items, {
			prompt = "Selecciona qué activar:",
		}, function(choice, idx)
			if not choice then
				return
			end

			if idx == 1 then
				M.activate_bulk(objects)
			else
				local selected_obj = objects[idx - 1]
				M.activate_bulk({ selected_obj })
			end
		end)
	end)
end

-- Ejecutar ATC (ABAP Test Cockpit)
function M.run_atc()
	local filename = vim.api.nvim_buf_get_name(0)
	local objtype = require("sap-nvim.core.objtype")
	local group = objtype.group(filename)
	local object_name = objtype.name(filename)
	if object_name == "" then
		return
	end

	local atc_type = objtype.atc_type(group)
	vim.notify("[sap-nvim] Ejecutando ATC sobre " .. object_name .. " (" .. atc_type .. ")...")
	local lines = {}
	sapcli.jobstart({ "sapcli", "atc", "run", atc_type, object_name }, {
		on_stdout = function(_, data)
			for _, l in ipairs(data) do
				if l ~= "" then
					table.insert(lines, l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if #lines > 0 then
					vim.notify("[sap-nvim] ATC:\n" .. table.concat(lines, "\n"))
				end
				local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
				vim.notify("[sap-nvim] ATC " .. (code == 0 and "OK" or "encontro issues"), lvl)
			end)
		end,
	})
end

-- Ejecutar pruebas unitarias
function M.run_aunit()
	local object_name = vim.fn.expand("%:t:r")
	if object_name == "" then
		return
	end

	vim.notify("[sap-nvim] Ejecutando AUnit sobre " .. object_name .. "...")
	local lines = {}
	sapcli.jobstart({ "sapcli", "aunit", "run", "class", object_name, "--output", "junit4" }, {
		on_stdout = function(_, data)
			for _, l in ipairs(data) do
				if l ~= "" then
					table.insert(lines, l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if #lines > 0 then
					vim.notify("[sap-nvim] AUnit:\n" .. table.concat(lines, "\n"))
				end
				local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
				vim.notify("[sap-nvim] AUnit " .. (code == 0 and "OK" or "fallaron"), lvl)
			end)
		end,
	})
end

-- Buscar objetos en SAP (vía ADT; fallback sapcli si ADT no está disponible).
function M.search(query)
	local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if ok_http and adt_http.is_available() then
		M.find_objects_async(query, function(rows, err)
			if rows and #rows > 0 then
				vim.notify(("sap-nvim: %d resultados para '%s'"):format(#rows, query))
			elseif err then
				vim.notify("sap-nvim: " .. err, vim.log.levels.WARN)
			end
		end)
		return
	end
	sapcli.jobstart({ "sapcli", "abap", "find", query }, {
		on_stdout = function(_, data)
			if data then
				local results = vim.iter(data)
					:filter(function(line)
						return line ~= ""
					end)
					:totable()
				if #results > 0 then
					vim.notify(("sap-nvim: %d resultados para '%s'"):format(#results, query))
				end
			end
		end,
	})
end

-- Abrir SAP GUI (aplicación de escritorio)
function M.open_gui(connection_name)
	local sapgui_path = "/Applications/SAP GUI.app"

	-- Intentar rutas alternativas de SAP GUI
	local possible_paths = {
		"/Applications/SAP GUI.app",
		"/Applications/SAPGUI.app",
		"/Applications/SAP GUI 7.60.app",
		"/Applications/SAP GUI 7.70.app",
		"/Applications/SAPGUI/SAP GUI.app",
	}

	local app_path = nil
	for _, path in ipairs(possible_paths) do
		local f = io.open(path .. "/Contents/Info.plist", "r")
		if f then
			f:close()
			app_path = path
			break
		end
	end

	if not app_path then
		vim.notify("sap-nvim: SAP GUI no encontrado. Verifica la ruta de instalación.", vim.log.levels.ERROR)
		return
	end

	-- Determinar el objeto actual
	local object_name = vim.fn.expand("%:t:r")
	local file_ext = vim.fn.expand("%:e")
	local transaction = M._get_transaction_for_extension(file_ext)

	-- Elegir conexión
	local conn = nil
	if connection_name and M.connections[connection_name] then
		conn = M.connections[connection_name]
	elseif M.current then
		conn = M.current
	end

	vim.fn.jobstart({ "open", app_path })
	if object_name ~= "" and object_name ~= "[No Name]" and transaction then
		vim.notify(string.format("[sap-nvim] SAP GUI abierto. Buscá %s en %s.", object_name, transaction))
	else
		vim.notify("[sap-nvim] SAP GUI abierto.")
	end
end

-- Mapear extensión de archivo a transacción SAP
function M._get_transaction_for_extension(ext)
	if not ext or ext == "" then
		return nil
	end
	local map = {
		abap = "SE80", -- Object Navigator
		cls = "SE24", -- Class Builder
		prog = "SE38", -- ABAP Editor
		func = "SE37", -- Function Builder
		ddl = "SE80", -- CDS View (via SE80)
		dcl = "SE80", -- CDS Access Control
		bdef = "SE80", -- CDS Behavior Definition
		dbrel = "SE80", -- CDS Metadata Extension
		simple = "SE80",
		fugr = "SE37",
		cinclude = "SE80",
		ddls = "SE80",
		intf = "SE80",
		tabl = "SE11", -- Data Dictionary
		stru = "SE11",
		dtel = "SE11",
		dome = "SE11",
	}
	return map[ext:lower()]
end
-- ========================================================================
-- DEBUGGER: HACK PARA VER EL XML DE SAP EN BRUTO
-- ========================================================================
function M.debug_inactive_xml()
	local adt_http = require("sap-nvim.core.adt_http")

	-- Intento 1: GET clásico
	local resp1 = adt_http.raw({
		method = "GET",
		path = "/sap/bc/adt/repository/nodestructure",
		query = { parent_name = "/workspace/inactive" },
		accept = "application/xml",
	})

	-- Intento 2: POST forzado (estilo Eclipse antiguo)
	local resp2 = adt_http.raw({
		method = "POST",
		path = "/sap/bc/adt/repository/nodestructure",
		accept = "application/xml",
		content_type = "application/xml",
		body = '<?xml version="1.0" encoding="UTF-8"?><tre:node xmlns:tre="http://www.sap.com/adt/core/tree"><tre:objectReference adtcore:uri="/workspace/inactive" xmlns:adtcore="http://www.sap.com/adt/core"/></tre:node>',
	})

	-- Crear un buffer a la derecha y volcar la respuesta real
	vim.schedule(function()
		local bufnr = vim.api.nvim_create_buf(false, true)
		local lines = { "=== RESULTADO DEL GET ===" }
		for _, l in ipairs(vim.split(resp1 or "SIN_RESPUESTA_GET", "\n")) do
			table.insert(lines, l)
		end
		table.insert(lines, "")
		table.insert(lines, "=== RESULTADO DEL POST ===")
		for _, l in ipairs(vim.split(resp2 or "SIN_RESPUESTA_POST", "\n")) do
			table.insert(lines, l)
		end

		vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
		vim.cmd("vsplit")
		vim.api.nvim_win_set_buf(0, bufnr)
	end)
end
return M
