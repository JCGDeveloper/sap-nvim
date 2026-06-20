-- sap-nvim.core.debugger
-- Cliente del ADT Debugger (PATH B) — productización del spike validado en vivo.
-- Protocolo de abap-adt-api/src/api/debugger.ts. Sesión STATEFUL mantenida por un cookie
-- jar propio + cabecera X-sap-adt-sessiontype: stateful. Todo async por vim.fn.jobstart
-- (sin --max-time, para que el long-poll de /listeners no muera). NO usa
-- adt_http.request_async (su fallback de 12s mataría el long-poll).
--
-- IMPORTANTE: ADT no usa un "session id" en la URL; la sesión ES el cookie jar stateful.
-- Guardamos debugSessionId solo para logging. La señal terminal "debuggeeEnded" (HTTP 500
-- con subType=debuggeeEnded) es NORMAL: el programa se reanudó y terminó.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local DEBUG = true

-- Pilar 3: tope de filas/hijos que exponemos al expandir una variable, para no colapsar
-- Neovim con tablas enormes (la API ADT de paginación real no está en abap-adt-api).
M.MAX_CHILDREN = 500

-- Estado de la sesión de depuración activa (una a la vez).
-- { jar, csrf, terminalId, ideId, user, listener_job, debugSessionId, breakpoints }
M.session = nil

-- ── logging ──────────────────────────────────────────────────────────────────

local function log(tag, msg)
	if DEBUG then
		local line = "[dbg] " .. tag .. ": " .. msg
		print(line)
		vim.schedule(function()
			vim.notify(line, vim.log.levels.INFO)
		end)
	end
end
local function fail(tag, msg)
	local line = "[dbg] " .. tag .. " FALLO: " .. msg
	print(line)
	vim.schedule(function()
		vim.notify(line, vim.log.levels.ERROR)
	end)
end

-- ── util ─────────────────────────────────────────────────────────────────────

math.randomseed(os.time())
local function uuid()
	return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end)):upper()
end

-- terminalId/ideId ESTABLES por máquina (como VSCode): persistidos, reutilizados entre
-- sesiones. Imprescindible para poder LIMPIAR los listeners del usuario (si fueran random
-- por sesión, los huérfanos quedarían inalcanzables). Devuelve terminalId, ideId.
local IDS_FILE = vim.fn.stdpath("cache") .. "/sap-nvim/debug_ids"
local function stable_ids()
	local t, i
	if vim.fn.filereadable(IDS_FILE) == 1 then
		local lines = vim.fn.readfile(IDS_FILE)
		t, i = lines[1], lines[2]
	end
	if not t or t == "" or not i or i == "" then
		t, i = uuid(), uuid()
		pcall(vim.fn.mkdir, vim.fn.fnamemodify(IDS_FILE, ":h"), "p")
		pcall(vim.fn.writefile, { t, i }, IDS_FILE)
	end
	return t, i
end

local function unxml(s)
	return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- encodeURIComponent (para valores de query como variableName, que lleva @ \ -).
local function urlenc(s)
	return (tostring(s):gsub("[^%w%-_.!~*'()]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Extrae el mensaje de una <exc:exception> de ADT (o nil) + el subType (p.ej. debuggeeEnded).
local function parse_exception(body)
	if not body or not body:find("exception", 1, true) then
		return nil
	end
	local msg = body:match("<message[^>]*>([^<]*)</message>") or "excepción ADT"
	local subtype = body:match('communicationFramework%.subType">([^<]*)<')
	return unxml(msg), subtype
end

-- ── curl async (núcleo) ──────────────────────────────────────────────────────
-- opts: { method, path, query, body, accept, content_type, csrf_fetch }
-- cb(body, http_status, headers). Stateful + cookie jar SIEMPRE (la sesión de debug).
local function curl(opts, cb)
	local s = M.session
	local c = adt_http.creds()
	if not c or not s then
		if cb then
			cb(nil, "no-session")
		end
		return
	end

	local url = c.base .. opts.path
	url = url .. (opts.path:find("?") and "&" or "?") .. "sap-client=" .. c.client
	if opts.query then
		for k, v in pairs(opts.query) do
			url = url .. "&" .. k .. "=" .. urlenc(v)
		end
	end

	local hdrfile = vim.fn.tempname()
	local args = {
		"curl",
		"-sk",
		"-u",
		c.user .. ":" .. c.pass,
		"-b",
		s.jar,
		"-c",
		s.jar,
		"-D",
		hdrfile,
		"-H",
		"X-sap-adt-sessiontype: stateful",
	}
	vim.list_extend(args, { "-X", opts.method or "GET" })
	if opts.csrf_fetch then
		vim.list_extend(args, { "-H", "X-CSRF-Token: Fetch" })
	elseif s.csrf then
		vim.list_extend(args, { "-H", "X-CSRF-Token: " .. s.csrf })
	end
	if opts.accept then
		vim.list_extend(args, { "-H", "Accept: " .. opts.accept })
	end
	if opts.content_type then
		vim.list_extend(args, { "-H", "Content-Type: " .. opts.content_type })
	end

	local bodyfile
	if opts.body then
		bodyfile = vim.fn.tempname()
		vim.fn.writefile(vim.split(opts.body, "\n"), bodyfile)
		vim.list_extend(args, { "--data-binary", "@" .. bodyfile })
	end
	vim.list_extend(args, { url })

	local out = {}
	return vim.fn.jobstart(args, {
		stdout_buffered = true,
		on_stdout = function(_, d)
			for _, l in ipairs(d) do
				out[#out + 1] = l
			end
		end,
		on_exit = function(_, exit_code)
			local headers = ""
			pcall(function()
				headers = table.concat(vim.fn.readfile(hdrfile), "\n")
			end)
			if bodyfile then
				pcall(os.remove, bodyfile)
			end
			pcall(os.remove, hdrfile)
			local status
			for st in headers:gmatch("HTTP/[%d%.]+%s+(%d+)") do
				status = tonumber(st)
			end
			status = status or ("curl-exit-" .. exit_code)
			if cb then
				vim.schedule(function()
					cb(table.concat(out, "\n"), status, headers)
				end)
			end
		end,
	})
end

-- ── 1) init_session: cookie jar + CSRF ───────────────────────────────────────

function M.init_session(cb)
	if not adt_http.is_available() then
		fail("init", "ADT no disponible (config.yml/curl).")
		if cb then
			cb(false)
		end
		return
	end
	local c = adt_http.creds()
	local jar = vim.fn.stdpath("cache") .. "/sap-nvim/debug_" .. os.time() .. ".cookies"
	vim.fn.mkdir(vim.fn.fnamemodify(jar, ":h"), "p")
	pcall(os.remove, jar)

	local terminalId, ideId = stable_ids()
	M.session = {
		jar = jar,
		csrf = nil,
		terminalId = terminalId,
		ideId = ideId,
		user = c.user:upper(),
		listener_job = nil,
		debugSessionId = nil,
		breakpoints = {},
	}
	log("init", "sesión nueva user=" .. M.session.user)

	curl({ method = "GET", path = "/sap/bc/adt/core/discovery", csrf_fetch = true }, function(_, status, headers)
		local token = headers and headers:match("[Xx]%-[Cc][Ss][Rr][Ff]%-[Tt]oken:%s*(%S+)")
		if not token then
			fail("init", "sin token CSRF (HTTP " .. tostring(status) .. ")")
			if cb then
				cb(false)
			end
			return
		end
		M.session.csrf = token
		log("init", "CSRF OK, sesión stateful lista.")
		if cb then
			cb(true)
		end
	end)
end

-- ── 2) set_breakpoint ─────────────────────────────────────────────────────────
-- source_uri: ej. "/sap/bc/adt/programs/programs/znvim/source/main". line: número.
-- cb(verified, info) — info = { id, errorMessage, uri }.
-- Resuelve la URI del breakpoint según el tipo de objeto (igual que breakpointManager.ts).
-- Para INCLUDES (forms/includes de un programa) SAP exige la URI "VIT" con MAIN_PROGRAM e
-- INCLUDE combinados (cada uno rellenado a 40 chars). Para program/class: la source/main.
-- cb(bp_uri, sync_scope) — sync_scope es la source/main del objeto (syncScope mode=partial).
function M.resolve_bp_uri(group, name, source_uri, cb)
	source_uri = (source_uri or ""):gsub("%?.*$", "")
	if group ~= "include" or not name or name == "" then
		cb(source_uri, source_uri)
		return
	end
	curl({
		method = "GET",
		path = "/sap/bc/adt/programs/includes/" .. name:lower() .. "/mainprograms",
		accept = "application/*",
	}, function(body)
		local mainname = body and body:match('adtcore:name="([^"]*)"')
		if not mainname then
			log("bp", "include " .. name .. " sin programa principal; uso source normal.")
			cb(source_uri, source_uri)
			return
		end
		local function pad40(x)
			return (x:upper() .. string.rep(" ", 40)):sub(1, 40)
		end
		local combined = pad40(mainname) .. pad40(name)
		local vit = "/sap/bc/adt/vit/wb/object_type/"
			.. urlenc("PROGI  "):lower() -- 'PROG'+'I'+2 espacios → progi%20%20
			.. "/object_name/"
			.. urlenc(combined)
		log("bp", "include " .. name .. " → main " .. mainname .. " (URI VIT)")
		cb(vit, source_uri)
	end)
end

-- bp_uri: URI del breakpoint (VIT para includes, source/main para program/class).
-- sync_scope (opcional): source/main del objeto → syncScope mode="partial".
function M.set_breakpoint(bp_uri, line, cb, sync_scope)
	local s = M.session
	if not s then
		fail("bp", "sin sesión (init_session primero).")
		if cb then
			cb(false, {})
		end
		return
	end

	local clean_uri = bp_uri:gsub("%?.*$", "")
	local uri = clean_uri .. "#start=" .. line

	local scope_xml = '<syncScope mode="full"></syncScope>'
	if sync_scope and sync_scope ~= "" then
		scope_xml = '<syncScope mode="partial"><adtcore:objectReference xmlns:adtcore="http://www.sap.com/adt/core" adtcore:uri="'
			.. sync_scope:gsub("%?.*$", "")
			.. '"/></syncScope>'
	end

	local body = table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<dbg:breakpoints scope="external" debuggingMode="user" requestUser="' .. s.user .. '"',
		'  terminalId="' .. s.terminalId .. '" ideId="' .. s.ideId .. '" systemDebugging="false" deactivated="false"',
		'  xmlns:dbg="http://www.sap.com/adt/debugger">',
		"  " .. scope_xml,
		'  <breakpoint xmlns:adtcore="http://www.sap.com/adt/core" kind="line" clientId="sapnvim"',
		'    skipCount="0" adtcore:uri="' .. uri .. '"/>',
		"</dbg:breakpoints>",
	}, "\n")

	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger/breakpoints",
		body = body,
		content_type = "application/xml",
		accept = "application/xml",
	}, function(resp, status)
		local errmsg = resp and resp:match('errorMessage="([^"]+)"')
		local id = resp and resp:match('<breakpoint[^>]-%sid="([^"]*)"')
		if parse_exception(resp) or (errmsg and errmsg ~= "") then
			fail("bp", "L" .. line .. " rechazado (HTTP " .. tostring(status) .. "): " .. (errmsg or "ver SAP"))
			if cb then
				cb(false, { errorMessage = errmsg or "rechazado", uri = uri })
			end
			return
		end
		s.breakpoints[#s.breakpoints + 1] = { id = id, uri = uri, line = line }
		log("bp", "L" .. line .. " creado (id=" .. (id and id:sub(1, 40) or "?") .. "…)")
		if cb then
			cb(true, { id = id, uri = uri })
		end
	end)
end

-- ── 4) attach ─────────────────────────────────────────────────────────────────
-- cb(ok, info) — info = { isPostMortem, debugSessionId, processId }.
function M.attach(debuggeeId, cb)
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = {
			method = "attach",
			debuggeeId = debuggeeId,
			debuggingMode = "user",
			requestUser = M.session.user,
			dynproDebugging = "true",
		},
		accept = "application/xml",
	}, function(body, status)
		if parse_exception(body) then
			fail("attach", "rechazado (HTTP " .. tostring(status) .. ")")
			if cb then
				cb(false, {})
			end
			return
		end
		local info = {
			isPostMortem = (body and body:match('isPostMortem="true"')) ~= nil,
			debugSessionId = body and body:match('debugSessionId="([^"]*)"'),
			processId = body and body:match('processId="([^"]*)"'),
		}
		M.session.debugSessionId = info.debugSessionId
		log("attach", "OK sessionId=" .. (info.debugSessionId or "?") .. " postMortem=" .. tostring(info.isPostMortem))
		if cb then
			cb(true, info)
		end
	end)
end

-- ── 3) listen (long-poll) — ignora post-mortem, re-escucha hasta un live ─────
-- cb(debuggeeId, attach_info) cuando hay una parada EN VIVO.
function M.listen(cb)
	local s = M.session
	if not s then
		fail("listen", "sin sesión.")
		return
	end
	log("listen", "long-poll /listeners… (ejecuta el objeto para parar en el breakpoint)")
	s.listener_job = curl({
		method = "POST",
		path = "/sap/bc/adt/debugger/listeners",
		query = {
			debuggingMode = "user",
			requestUser = s.user,
			terminalId = s.terminalId,
			ideId = s.ideId,
			checkConflict = "true",
			isNotifiedOnConflict = "true",
		},
	}, function(body, status)
		s.listener_job = nil
		if not body or body == "" then
			fail("listen", "respuesta vacía (HTTP " .. tostring(status) .. ")")
			return
		end
		if body:find("conflictText", 1, true) then
			fail("listen", "conflicto: ya hay un debugger ADT/Eclipse escuchando con este usuario.")
			return
		end
		local debuggee = body:match("<DEBUGGEE_ID>([^<]+)</DEBUGGEE_ID>") or body:match('debuggeeId="([^"]+)"')
		if not debuggee then
			fail("listen", "sin DEBUGGEE_ID.")
			return
		end
		log("listen", "debuggee capturado: " .. debuggee:sub(1, 20) .. "…")

		-- Atachar para saber si es post-mortem; si lo es, terminarlo y volver a escuchar.
		M.attach(debuggee, function(ok, info)
			if not ok then
				return
			end
			if info.isPostMortem then
				log(
					"listen",
					"⚠️ era un DUMP (post-mortem). Lo ignoro (terminateDebuggee) y vuelvo a escuchar. Limpia ST22."
				)
				M.step("terminateDebuggee", function()
					M.listen(cb)
				end)
				return
			end
			if cb then
				cb(debuggee, info)
			end
		end)
	end)
end

-- ── 5) get_stack ──────────────────────────────────────────────────────────────
-- cb(frames) — frame = { program, include, line, position, stackUri, stackType,
--                        eventName, systemProgram, uri }.
function M.get_stack(cb)
	curl({
		method = "GET",
		path = "/sap/bc/adt/debugger/stack",
		query = { method = "getStack", emode = "_", semanticURIs = "true" },
		accept = "application/xml",
	}, function(body, status)
		if parse_exception(body) or not (body or ""):find("stackEntry", 1, true) then
			fail("stack", "sin stack (HTTP " .. tostring(status) .. ")")
			if cb then
				cb({})
			end
			return
		end
		local frames = {}
		for attrs in body:gmatch("<stackEntry(.-)/?>") do
			local uri = attrs:match('adtcore:uri="([^"]*)"') or attrs:match('stackUri="([^"]*)"')
			frames[#frames + 1] = {
				program = attrs:match('programName="([^"]*)"'),
				include = attrs:match('includeName="([^"]*)"'),
				line = tonumber(attrs:match('line="([^"]*)"')) or 1,
				position = tonumber(attrs:match('stackPosition="([^"]*)"')),
				stackUri = attrs:match('stackUri="([^"]*)"'),
				stackType = attrs:match('stackType="([^"]*)"'),
				eventName = attrs:match('eventName="([^"]*)"'),
				systemProgram = attrs:match('systemProgram="true"') ~= nil,
				uri = uri and unxml(uri) or nil,
			}
		end
		log("stack", #frames .. " frame(s).")
		if cb then
			cb(frames)
		end
	end)
end

-- Selecciona un frame del stack (para inspeccionar sus variables). stackUri viene de
-- get_stack (campo stackUri). PUT, sin body. cb(ok).
function M.goto_stack(stackUri, cb)
	if not stackUri then
		if cb then
			cb(false)
		end
		return
	end
	curl({ method = "PUT", path = stackUri }, function(_, status)
		if cb then
			cb(tostring(status):match("^2") ~= nil)
		end
	end)
end

-- ── 6) get_variables ──────────────────────────────────────────────────────────
-- scope: id del nodo a expandir ("@ROOT" para los scopes; "@GLOBALS"/"@LOCALS"/<var id>
--   para variables). Acepta string o lista de ids.
-- cb(vars, scopes) — vars = hojas; scopes = nodos hijos (para drill posterior).
--   var = { id, name, value, type, meta, expandable, table_lines }.
function M.get_variables(scope, cb)
	local parents = type(scope) == "table" and scope or { scope or "@ROOT" }
	local h = {}
	for _, p in ipairs(parents) do
		h[#h + 1] = "<STPDA_ADT_VARIABLE_HIERARCHY><PARENT_ID>" .. p .. "</PARENT_ID></STPDA_ADT_VARIABLE_HIERARCHY>"
	end
	local body = '<?xml version="1.0" encoding="UTF-8" ?><asx:abap version="1.0" xmlns:asx="http://www.sap.com/abapxml"><asx:values><DATA><HIERARCHIES>'
		.. table.concat(h)
		.. "</HIERARCHIES></DATA></asx:values></asx:abap>"

	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "getChildVariables" },
		accept = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.debugger.ChildVariables",
		content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.debugger.ChildVariables",
		body = body,
	}, function(resp, status)
		if parse_exception(resp) then
			fail("vars", "error (HTTP " .. tostring(status) .. ")")
			if cb then
				cb({}, {})
			end
			return
		end
		resp = resp or ""
		local vars = {}
		local truncated = false
		for v in resp:gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
			if #vars >= M.MAX_CHILDREN then
				truncated = true
				break
			end -- Pilar 3: tope anti-crash
			local meta = v:match("<META_TYPE>([^<]*)</META_TYPE>") or "simple"
			vars[#vars + 1] = {
				id = v:match("<ID>([^<]*)</ID>"),
				name = v:match("<NAME>([^<]*)</NAME>"),
				value = unxml((v:match("<VALUE>(.-)</VALUE>") or "")),
				type = v:match("<DECLARED_TYPE_NAME>([^<]*)</DECLARED_TYPE_NAME>"),
				meta = meta,
				table_lines = tonumber(v:match("<TABLE_LINES>([^<]*)</TABLE_LINES>")) or 0,
				-- expandible si NO es escalar (table/struct/object/dataref tienen hijos).
				expandable = (meta ~= "simple" and meta ~= "string"),
			}
		end
		if truncated then
			vars[#vars + 1] = {
				id = "",
				name = "…",
				value = "(>" .. M.MAX_CHILDREN .. " filas; paginación de tablas pendiente)",
				type = "",
				meta = "info",
				table_lines = 0,
				expandable = false,
			}
		end
		local scopes = {}
		for hy in resp:gmatch("<STPDA_ADT_VARIABLE_HIERARCHY>(.-)</STPDA_ADT_VARIABLE_HIERARCHY>") do
			local cid = hy:match("<CHILD_ID>([^<]*)</CHILD_ID>")
			local cname = hy:match("<CHILD_NAME>([^<]*)</CHILD_NAME>")
			if cid then
				scopes[#scopes + 1] = { id = cid, name = (cname ~= "" and cname) or cid }
			end
		end
		log("vars", #vars .. " var(s), " .. #scopes .. " scope(s) bajo '" .. tostring(parents[1]) .. "'.")
		if cb then
			cb(vars, scopes)
		end
	end)
end

-- getVariables: pide variables CONCRETAS por su ID. Es el endpoint para TABLAS (las filas
-- NO salen por getChildVariables; se construyen sus ids ID[1]..ID[N] y se piden por aquí).
-- También sirve para leer la metadata de una variable suelta. cb(vars).
function M.get_vars_by_id(ids, cb)
	ids = type(ids) == "table" and ids or { ids }
	local b = {}
	for _, id in ipairs(ids) do
		b[#b + 1] = "<STPDA_ADT_VARIABLE><ID>" .. id .. "</ID></STPDA_ADT_VARIABLE>"
	end
	local body = '<?xml version="1.0" encoding="UTF-8" ?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
		.. table.concat(b)
		.. "</DATA></asx:values></asx:abap>"
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "getVariables" },
		accept = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.debugger.Variables",
		content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.debugger.Variables",
		body = body,
	}, function(resp, status)
		if parse_exception(resp) then
			fail("vars", "getVariables error (HTTP " .. tostring(status) .. ")")
			if cb then cb({}) end
			return
		end
		local vars = {}
		for v in (resp or ""):gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
			if #vars >= M.MAX_CHILDREN then break end
			local meta = v:match("<META_TYPE>([^<]*)</META_TYPE>") or "simple"
			vars[#vars + 1] = {
				id = v:match("<ID>([^<]*)</ID>"),
				name = v:match("<NAME>([^<]*)</NAME>"),
				value = unxml((v:match("<VALUE>(.-)</VALUE>") or "")),
				type = v:match("<DECLARED_TYPE_NAME>([^<]*)</DECLARED_TYPE_NAME>"),
				meta = meta,
				table_lines = tonumber(v:match("<TABLE_LINES>([^<]*)</TABLE_LINES>")) or 0,
				expandable = (meta ~= "simple" and meta ~= "string"),
			}
		end
		log("vars", #vars .. " var(s) by id.")
		if cb then cb(vars) end
	end)
end

-- IDs de las filas de una tabla: ID[1]..ID[min(lines, MAX_CHILDREN)] (igual que VSCode).
function M.table_row_ids(id, lines)
	local n = math.min(lines or 0, M.MAX_CHILDREN)
	local ids = {}
	for k = 1, n do
		ids[#ids + 1] = (id:gsub("%[%]$", "")) .. "[" .. k .. "]"
	end
	return ids
end

-- ── 7) step ───────────────────────────────────────────────────────────────────
-- action: stepInto | stepOver | stepReturn | stepContinue | stepRunToLine |
--         stepJumpToLine | terminateDebuggee.
-- cb(result) — result = { ended=bool, error=string|nil }. ended=true cuando el debuggee
--   terminó (HTTP 500 + subType=debuggeeEnded) → NO es un crash, es fin normal.
function M.step(action, cb)
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = action },
		accept = "application/xml",
	}, function(body, status)
		local msg, subtype = parse_exception(body)
		if subtype == "debuggeeEnded" or (body and body:find("debuggeeEnded", 1, true)) then
			log("step", action .. " → debuggee TERMINADO (fin normal de ejecución).")
			if cb then
				cb({ ended = true })
			end
			return
		end
		if msg then
			fail("step", action .. " error (HTTP " .. tostring(status) .. "): " .. msg)
			if cb then
				cb({ ended = false, error = msg })
			end
			return
		end
		log("step", action .. " OK (HTTP " .. tostring(status) .. ").")
		if cb then
			cb({ ended = false })
		end
	end)
end

-- Cambia el valor de una variable escalar en runtime (Pilar 2). variableName = el ID ADT
-- de la variable (p.ej. "SY-SUBRC" o "@GLOBALS\LV_X"). cb(ok, msg).
function M.set_variable(variableName, value, cb)
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "setVariableValue", variableName = variableName },
		body = value,
		content_type = "text/plain",
		accept = "application/xml",
	}, function(body, status)
		local msg = parse_exception(body)
		if msg or not tostring(status):match("^2") then
			fail(
				"setvar",
				variableName .. " = '" .. value .. "' (HTTP " .. tostring(status) .. "): " .. (msg or "rechazado")
			)
			if cb then
				cb(false, msg)
			end
			return
		end
		log("setvar", variableName .. " = '" .. value .. "' OK.")
		if cb then
			cb(true)
		end
	end)
end

-- Mueve el puntero de ejecución a una línea SIN ejecutar (Pilar 5, jump-to-line).
-- uri = source uri con #start=line. cb(result) — { ended, error }.
function M.jump(uri, cb)
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "stepJumpToLine", uri = uri },
		accept = "application/xml",
	}, function(body, status)
		local msg = parse_exception(body)
		if msg then
			fail("jump", "(HTTP " .. tostring(status) .. "): " .. msg)
			if cb then
				cb({ error = msg })
			end
			return
		end
		log("jump", "saltado a " .. uri)
		if cb then
			cb({ ended = false })
		end
	end)
end

-- ── stop / cleanup ─────────────────────────────────────────────────────────────

function M.stop(cb)
	local s = M.session
	if not s then
		if cb then
			cb()
		end
		return
	end
	if s.listener_job then
		pcall(vim.fn.jobstop, s.listener_job)
		s.listener_job = nil
	end
	curl({
		method = "DELETE",
		path = "/sap/bc/adt/debugger/listeners",
		query = {
			debuggingMode = "user",
			requestUser = s.user,
			terminalId = s.terminalId,
			ideId = s.ideId,
			checkConflict = "false",
			notifyConflict = "true",
		},
	}, function(_, status)
		log("stop", "listener eliminado (HTTP " .. tostring(status) .. "). Sesión cerrada.")
		pcall(os.remove, s.jar)
		M.session = nil
		if cb then
			cb()
		end
	end)
end

-- SPIKE/diagnóstico: vuelca el XML CRUDO de una tabla (sus FILAS) y de la PRIMERA fila (sus
-- CELDAS/columnas), para ver el formato exacto de los IDs. Ejecutar PARADO en un breakpoint.
function M.dump_table(name)
	if not M.session then
		fail("dump", "no hay sesión de debug activa (para en un breakpoint primero).")
		return
	end
	name = name:upper()
	local function get_raw(parent, cb)
		local body = '<?xml version="1.0" encoding="UTF-8" ?><asx:abap version="1.0" xmlns:asx="http://www.sap.com/abapxml"><asx:values><DATA><HIERARCHIES><STPDA_ADT_VARIABLE_HIERARCHY><PARENT_ID>'
			.. parent
			.. "</PARENT_ID></STPDA_ADT_VARIABLE_HIERARCHY></HIERARCHIES></DATA></asx:values></asx:abap>"
		curl({
			method = "POST",
			path = "/sap/bc/adt/debugger",
			query = { method = "getChildVariables" },
			accept = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.debugger.ChildVariables",
			content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.debugger.ChildVariables",
			body = body,
		}, function(resp)
			cb(resp or "")
		end)
	end

	-- Busca el CHILD_ID real de `target` dentro del XML de un scope (puede venir como
	-- HIERARCHY si es expandible, o como VARIABLE si es escalar).
	local function find_id(xml, target)
		for h in xml:gmatch("<STPDA_ADT_VARIABLE_HIERARCHY>(.-)</STPDA_ADT_VARIABLE_HIERARCHY>") do
			local cid = h:match("<CHILD_ID>([^<]*)</CHILD_ID>")
			local cname = h:match("<CHILD_NAME>([^<]*)</CHILD_NAME>")
			if cid and (cid:upper():find(target, 1, true) or (cname and cname:upper() == target)) then
				return cid
			end
		end
		for v in xml:gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
			local id = v:match("<ID>([^<]*)</ID>")
			if id and id:upper():find(target, 1, true) then return id end
		end
		return nil
	end
	-- Primer hijo (fila) de un XML: por VARIABLE o por HIERARCHY.
	local function first_child(xml)
		return xml:match("<STPDA_ADT_VARIABLE>.-<ID>([^<]+)</ID>")
			or xml:match("<STPDA_ADT_VARIABLE_HIERARCHY>.-<CHILD_ID>([^<]+)</CHILD_ID>")
	end

	local scopes = { "@GLOBALS", "@LOCALS" }
	local si = 0
	local function try_scope()
		si = si + 1
		local scope = scopes[si]
		if not scope then
			fail("dump", name .. " no encontrado en @GLOBALS/@LOCALS. Pega el RAW del scope de arriba.")
			return
		end
		get_raw(scope, function(scope_xml)
			print("[dump] ════════ RAW scope " .. scope .. " ════════")
			print(scope_xml)
			local tid = find_id(scope_xml, name)
			if not tid then
				try_scope()
				return
			end
			log("dump", name .. " → id=" .. tid .. " (en " .. scope .. "). Leyendo filas…")
			get_raw(tid, function(rows_xml)
				print("[dump] ════════ RAW FILAS (" .. tid .. ") ════════")
				print(rows_xml)
				print("[dump] ════════ fin FILAS ════════")
				local row1 = first_child(rows_xml)
				if not row1 then
					fail("dump", "sin filas (¿tabla vacía?).")
					return
				end
				log("dump", "primera fila id=" .. row1 .. " — leyendo celdas…")
				get_raw(row1, function(cells_xml)
					print("[dump] ════════ RAW CELDAS (fila " .. row1 .. ") ════════")
					print(cells_xml)
					print("[dump] ════════ fin CELDAS ════════")
					log("dump", "Listo: pega de :messages los 3 bloques (scope, FILAS, CELDAS).")
				end)
			end)
		end)
	end
	try_scope()
end

-- El control del debugger es 100% vía nvim-dap (integrations/dap.lua): <leader>db breakpoint,
-- <leader>dc arrancar, <leader>di/do/dO step, <leader>dt terminar. Aquí solo el spike de tabla.
function M.setup()
	vim.api.nvim_create_user_command("SapDumpTable", function(a)
		local n = (a.args ~= "" and a.args) or vim.fn.expand("<cexpr>")
		if n and n ~= "" then
			M.dump_table(n)
		else
			vim.notify("[sap-nvim] Pon el cursor sobre la tabla o usa :SapDumpTable NOMBRE", vim.log.levels.WARN)
		end
	end, { desc = "sap-nvim: SPIKE — volcar XML crudo de una tabla (filas+celdas)", nargs = "?" })
end

return M
