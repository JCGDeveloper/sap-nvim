-- lua/sap-nvim/core/debugger.lua
local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local DEBUG = true
M.MAX_CHILDREN = 500
M.session = nil

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

local function xmlesc(s)
	return tostring(s or "")
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;")
		:gsub("'", "&apos;")
end

local function norm_meta(s, table_lines)
	s = vim.trim(tostring(s or "simple")):lower()
	if s == "" then
		s = "simple"
	end
	if (table_lines or 0) > 0 and s ~= "table" then
		return "table"
	end
	return s
end

math.randomseed(os.time())
local function uuid()
	return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
		local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
		return string.format("%x", v)
	end)):upper()
end

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

local function urlenc(s)
	return (tostring(s):gsub("[^%w%-_.!~*'()]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local function parse_exception(body)
	if not body or not body:find("exception", 1, true) then
		return nil
	end
	local msg = body:match("<message[^>]*>([^<]*)</message>") or "excepción ADT"
	local subtype = body:match('communicationFramework%.subType">([^<]*)<')
	return unxml(msg), subtype
end

local function curl_cfg(c)
	local esc = function(s)
		return (tostring(s or "")):gsub("\\", "\\\\"):gsub('"', '\\"')
	end
	return 'user = "' .. esc(c.user .. ":" .. c.pass) .. '"\n'
end

local function curl_base_args(opts)
	local ok, cfg = pcall(require, "sap-nvim.core.config")
	local sec = ok and cfg.security() or {}
	local args = { "curl", "-s" }
	if sec.verify_tls == false then
		args[#args + 1] = "-k"
	end
	if sec.ca_file and sec.ca_file ~= "" then
		vim.list_extend(args, { "--cacert", vim.fn.expand(sec.ca_file) })
	end
	local connect_timeout = tonumber(sec.connect_timeout) or 10
	if connect_timeout > 0 then
		vim.list_extend(args, { "--connect-timeout", tostring(connect_timeout) })
	end
	if not (opts and opts.no_timeout) then
		local request_timeout = tonumber(sec.request_timeout) or 45
		if request_timeout > 0 then
			vim.list_extend(args, { "--max-time", tostring(request_timeout) })
		end
	end
	return args
end

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
	local args = curl_base_args(opts)
	vim.list_extend(args, {
		"-K",
		"-",
		"-b",
		s.jar,
		"-c",
		s.jar,
		"-D",
		hdrfile,
		"-H",
		"X-sap-adt-sessiontype: stateful",
	})
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
	local job = vim.fn.jobstart(args, {
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
			local body = table.concat(out, "\n")
			if status == 401 or adt_http.is_auth_error(body) then
				adt_http.on_auth_failure()
			end
			if cb then
				vim.schedule(function()
					cb(body, status, headers)
				end)
			end
		end,
	})
	if job and job > 0 then
		pcall(vim.fn.chansend, job, curl_cfg(c))
		pcall(vim.fn.chanclose, job, "stdin")
	end
	return job
end

function M.init_session(cb)
	if not adt_http.is_available() then
		fail("init", "ADT no disponible.")
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
		listener_retries = 0,
		stopping = false,
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

function M.resolve_bp_uri(group, name, source_uri, cb)
	source_uri = (source_uri or ""):gsub("%?.*$", "")
	source_uri = source_uri:gsub("^adt://", "")

	local is_local = not source_uri:match("^/sap/bc/adt")

	if is_local then
		local is_class = source_uri:match("%.clas%.abap$")
		local clean_name = source_uri:match("([^/\\]+)%..+%.abap$") or source_uri:match("([^/\\]+)%.abap$")
		if clean_name then
			name = clean_name
		end

		if is_class then
			source_uri = "/sap/bc/adt/oo/classes/" .. urlenc((name or ""):lower()) .. "/source/main"
		else
			source_uri = "/sap/bc/adt/programs/programs/" .. urlenc((name or ""):lower()) .. "/source/main"
		end
	end

	if not name or name == "" then
		cb(source_uri, source_uri)
		return
	end

	curl({
		method = "GET",
		path = "/sap/bc/adt/programs/includes/" .. urlenc(name:lower()) .. "/mainprograms",
		accept = "application/*",
	}, function(body, status)
		local mainname = body and body:match('adtcore:name="([^"]*)"')

		if not mainname then
			cb(source_uri, source_uri)
			return
		end

		-- SAP exige 40 chars para el padre y 40 para el hijo
		local function pad40(x)
			return (x:upper() .. string.rep(" ", 40)):sub(1, 40)
		end
		local combined = pad40(mainname) .. pad40(name)

		-- Esta URI lleva el Main Program incrustado, evitando el error "is initial"
		local vit = "/sap/bc/adt/vit/wb/object_type/"
			.. urlenc("PROGI  "):lower()
			.. "/object_name/"
			.. urlenc(combined)

		log("bp", "💡 Include detectado: " .. name:upper() .. " (Main: " .. mainname .. ")")

		-- 🔥 LA FÓRMULA MÁGICA:
		-- 1. Pasamos 'vit' para que SAP sepa el Main Program.
		-- 2. Pasamos 'nil' para que el scope sea "full" y SAP no llore por restricciones.
		cb(vit, nil)
	end)
end

local function clean_bp_uri(uri)
	return (uri or ""):gsub("#.*$", ""):gsub("%?.*$", "")
end

-- Detecta el caso "ubicación no válida": SAP no permite un breakpoint en esa línea
-- porque no hay sentencia ejecutable (línea en blanco, declaración, comentario…).
local function is_unavailable_location(text)
	local t = tostring(text or ""):lower()
	return t:find("unavailable location", 1, true) ~= nil
		or t:find("no executable", 1, true) ~= nil
		or t:find("not executable", 1, true) ~= nil
		or t:find("executable statement", 1, true) ~= nil
		or t:find("invalid line", 1, true) ~= nil
		or t:find("invalidlocation", 1, true) ~= nil
		or t:find("kein ausführbare", 1, true) ~= nil
end

function M.set_breakpoint(bp_uri, line, cb, sync_scope, opts)
	opts = opts or {}
	local s = M.session
	if not s then
		fail("bp", "sin sesión.")
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
		'<dbg:breakpoints scope="external" debuggingMode="user" requestUser="'
			.. s.user
			.. '" terminalId="'
			.. s.terminalId
			.. '" ideId="'
			.. s.ideId
			.. '" systemDebugging="false" deactivated="false" xmlns:dbg="http://www.sap.com/adt/debugger">',
		"  " .. scope_xml,
		'  <breakpoint xmlns:adtcore="http://www.sap.com/adt/core" kind="line" clientId="sapnvim" skipCount="0" adtcore:uri="'
			.. uri
			.. '"/>',
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
		local exc_msg, subtype = parse_exception(resp)
		local id = resp and resp:match('<breakpoint[^>]-%sid="([^"]*)"')
		if exc_msg or (errmsg and errmsg ~= "") then
			local raw = errmsg or exc_msg or "rechazado"
			-- A6: si SAP indica que la ubicación no es válida (no hay sentencia
			-- ejecutable en esa línea), devolvemos un mensaje accionable en español.
			local unavailable = is_unavailable_location(raw)
				or is_unavailable_location(resp)
				or is_unavailable_location(subtype)
			local friendly = raw
			if unavailable then
				friendly = "La línea " .. line .. " no es ejecutable; mueve el breakpoint a una sentencia."
			end
			fail("bp", "L" .. line .. " rechazado: " .. friendly)
			if cb then
				cb(false, {
					errorMessage = friendly,
					raw = raw,
					line = line,
					uri = uri,
					unavailableLocation = unavailable,
				})
			end
			return
		end
		s.breakpoints[#s.breakpoints + 1] =
			{ id = id, uri = uri, line = line, source_uri = clean_bp_uri(opts.source_uri or bp_uri) }
		if cb then
			cb(true, { id = id, uri = uri })
		end
	end)
end

local function clear_breakpoints(match, cb)
	local s = M.session
	if not s then
		if cb then
			cb({ deleted = 0, failed = 0, matched = 0, reason = "no-session" })
		end
		return
	end

	local targets = {}
	for idx, bp in ipairs(s.breakpoints or {}) do
		if bp.id and match(bp) then
			targets[#targets + 1] = { idx = idx, bp = bp }
		end
	end

	if #targets == 0 then
		if cb then
			cb({ deleted = 0, failed = 0, matched = 0 })
		end
		return
	end

	local deleted, failed, i = 0, 0, 0
	local function next_target()
		i = i + 1
		local target = targets[i]
		if not target then
			local keep = {}
			for _, bp in ipairs(s.breakpoints or {}) do
				if not bp.__sap_nvim_deleted then
					keep[#keep + 1] = bp
				end
			end
			s.breakpoints = keep
			if cb then
				cb({ deleted = deleted, failed = failed, matched = #targets })
			end
			return
		end

		curl({
			method = "DELETE",
			path = "/sap/bc/adt/debugger/breakpoints/" .. urlenc(target.bp.id),
			accept = "application/xml",
		}, function(body, status)
			local ok = tostring(status):match("^2") ~= nil and not parse_exception(body)
			if ok then
				target.bp.__sap_nvim_deleted = true
				deleted = deleted + 1
			else
				failed = failed + 1
			end
			next_target()
		end)
	end
	next_target()
end

function M.clear_breakpoints_by_ids(ids, cb)
	local wanted = {}
	for _, id in ipairs(ids or {}) do
		wanted[tostring(id)] = true
	end
	clear_breakpoints(function(bp)
		return wanted[tostring(bp.id)]
	end, cb)
end

function M.clear_breakpoints_for_sources(sources, cb)
	local wanted = {}
	for _, uri in ipairs(sources or {}) do
		uri = clean_bp_uri(uri)
		if uri ~= "" then
			wanted[uri] = true
			wanted[uri:gsub("/source/main$", "")] = true
		end
	end
	clear_breakpoints(function(bp)
		local uri = clean_bp_uri(bp.source_uri or bp.uri)
		return wanted[uri] or wanted[uri:gsub("/source/main$", "")] or false
	end, cb)
end

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
			fail("attach", "rechazado")
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
		if cb then
			cb(true, info)
		end
	end)
end

function M.listen(cb)
	local s = M.session
	if not s then
		fail("listen", "sin sesión.")
		return
	end
	if s.listener_job then
		pcall(vim.fn.jobstop, s.listener_job)
		s.listener_job = nil
	end
	s.listener_job = curl({
		method = "POST",
		path = "/sap/bc/adt/debugger/listeners",
		no_timeout = true,
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
		if M.session ~= s or s.stopping then
			log("listen", "listener cerrado.")
			return
		end
		if not body or body == "" then
			s.listener_retries = (s.listener_retries or 0) + 1
			local delay = math.min(5000, 500 * s.listener_retries)
			log("listen", "respuesta vacía (HTTP " .. tostring(status) .. "); reintentando...")
			vim.defer_fn(function()
				if M.session == s and not s.stopping then
					M.listen(cb)
				end
			end, delay)
			return
		end
		if body:find("conflictText", 1, true) then
			fail("listen", "conflicto: debugger ADT en uso.")
			return
		end
		local debuggee = body:match("<DEBUGGEE_ID>([^<]+)</DEBUGGEE_ID>") or body:match('debuggeeId="([^"]+)"')
		if not debuggee then
			fail("listen", "sin DEBUGGEE_ID.")
			return
		end

		M.attach(debuggee, function(ok, info)
			if not ok then
				return
			end
			s.listener_retries = 0
			if info.isPostMortem then
				log("listen", "DUMP (post-mortem). Ignorando...")
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

function M.get_stack(cb)
	curl({
		method = "GET",
		path = "/sap/bc/adt/debugger/stack",
		query = { method = "getStack", emode = "_", semanticURIs = "true" },
		accept = "application/xml",
	}, function(body, status)
		if parse_exception(body) or not (body or ""):find("stackEntry", 1, true) then
			if cb then
				cb({})
			end
			return
		end
		local frames = {}
		for attrs in body:gmatch("<[%w_:]*stackEntry%s(.-)/?>") do
			local uri = attrs:match('adtcore:uri="([^"]*)"') or attrs:match('%suri="([^"]*)"')
			local stack_uri = attrs:match('stackUri="([^"]*)"') or uri
			local line = tonumber(attrs:match('line="([^"]*)"'))
			if not line and uri then
				line = tonumber(uri:match("#start=(%d+)"))
			end
			frames[#frames + 1] = {
				program = attrs:match('programName="([^"]*)"') or attrs:match('program="([^"]*)"'),
				include = attrs:match('includeName="([^"]*)"') or attrs:match('include="([^"]*)"'),
				line = line or 1,
				position = tonumber(attrs:match('stackPosition="([^"]*)"')),
				stackUri = stack_uri and unxml(stack_uri) or nil,
				stackType = attrs:match('stackType="([^"]*)"'),
				eventName = attrs:match('eventName="([^"]*)"'),
				systemProgram = attrs:match('systemProgram="true"') ~= nil,
				uri = uri and unxml(uri) or nil,
			}
		end
		if cb then
			cb(frames)
		end
	end)
end

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

function M.get_variables(scope, cb)
	local parents = type(scope) == "table" and scope or { scope or "@ROOT" }
	local h = {}
	for _, p in ipairs(parents) do
		h[#h + 1] = "<STPDA_ADT_VARIABLE_HIERARCHY><PARENT_ID>" .. xmlesc(p) .. "</PARENT_ID></STPDA_ADT_VARIABLE_HIERARCHY>"
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
			if cb then
				cb({}, {})
			end
			return
		end
		resp = resp or ""
		local vars = {}
		for v in resp:gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
			if #vars >= M.MAX_CHILDREN then
				break
			end
			local table_lines = tonumber(v:match("<TABLE_LINES>([^<]*)</TABLE_LINES>")) or 0
			local meta = norm_meta(v:match("<META_TYPE>([^<]*)</META_TYPE>"), table_lines)
			vars[#vars + 1] = {
				id = v:match("<ID>([^<]*)</ID>"),
				name = v:match("<NAME>([^<]*)</NAME>"),
				value = unxml((v:match("<VALUE>(.-)</VALUE>") or "")),
				type = v:match("<DECLARED_TYPE_NAME>([^<]*)</DECLARED_TYPE_NAME>"),
				meta = meta,
				table_lines = table_lines,
				expandable = (meta ~= "simple" and meta ~= "string"),
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
		if cb then
			cb(vars, scopes)
		end
	end)
end

function M.get_vars_by_id(ids, cb)
	ids = type(ids) == "table" and ids or { ids }
	local b = {}
	for _, id in ipairs(ids) do
		b[#b + 1] = "<STPDA_ADT_VARIABLE><ID>" .. xmlesc(id) .. "</ID></STPDA_ADT_VARIABLE>"
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
			if cb then
				cb({})
			end
			return
		end
		local vars = {}
		for v in (resp or ""):gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
			if #vars >= M.MAX_CHILDREN then
				break
			end
			local table_lines = tonumber(v:match("<TABLE_LINES>([^<]*)</TABLE_LINES>")) or 0
			local meta = norm_meta(v:match("<META_TYPE>([^<]*)</META_TYPE>"), table_lines)
			vars[#vars + 1] = {
				id = v:match("<ID>([^<]*)</ID>"),
				name = v:match("<NAME>([^<]*)</NAME>"),
				value = unxml((v:match("<VALUE>(.-)</VALUE>") or "")),
				type = v:match("<DECLARED_TYPE_NAME>([^<]*)</DECLARED_TYPE_NAME>"),
				meta = meta,
				table_lines = table_lines,
				expandable = (meta ~= "simple" and meta ~= "string"),
			}
		end
		if cb then
			cb(vars)
		end
	end)
end

-- Genera los IDs de fila de una tabla para un rango [offset+1 .. offset+limit].
-- offset (0-based) y limit (tamaño de página) permiten paginar tablas grandes en
-- lugar de truncar siempre desde la primera fila. Por defecto: offset=0, limit=MAX_CHILDREN.
function M.table_row_ids(id, lines, offset, limit)
	lines = lines or 0
	offset = tonumber(offset) or 0
	if offset < 0 then
		offset = 0
	end
	limit = tonumber(limit) or M.MAX_CHILDREN
	local first = offset + 1
	local last = math.min(lines, offset + limit)
	local ids = {}
	for k = first, last do
		ids[#ids + 1] = (id:gsub("%[%]$", "")) .. "[" .. k .. "]"
	end
	return ids
end

-- Propaga offset/limit para pedir SOLO la página solicitada de la tabla.
function M.get_table_rows(id, lines, cb, offset, limit)
	local row_ids = M.table_row_ids(id, lines, offset, limit)
	if #row_ids == 0 then
		cb({})
		return
	end
	M.get_vars_by_id(row_ids, function(rows)
		if rows and #rows > 0 then
			cb(rows)
			return
		end
		-- Algunos backends ADT no aceptan IDs fabricados ID[1]. En ese caso tratamos
		-- la tabla como nodo padre y dejamos que SAP devuelva sus hijos reales.
		M.get_variables(id, function(child_rows)
			cb(child_rows or {})
		end)
	end)
end

function M.step(action, cb)
	curl(
		{ method = "POST", path = "/sap/bc/adt/debugger", query = { method = action }, accept = "application/xml" },
		function(body, status)
			local msg, subtype = parse_exception(body)
			if subtype == "debuggeeEnded" or (body and body:find("debuggeeEnded", 1, true)) then
				if cb then
					cb({ ended = true })
				end
				return
			end
			if msg then
				if cb then
					cb({ ended = false, error = msg })
				end
				return
			end
			if cb then
				cb({ ended = false })
			end
		end
	)
end

function M.can_set_variable()
	local ok_cfg, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	return ok_cfg and type(cfg) == "table" and cfg.allow_debug_set_variable == true
end

function M.set_variable(variableName, value, cb)
	if not M.can_set_variable() then
		if cb then
			cb(false, "setVariable desactivado por seguridad (productive.allow_debug_set_variable=false)")
		end
		return
	end
	if not M.session then
		if cb then
			cb(false, "no hay sesión de debug activa")
		end
		return
	end
	variableName = vim.trim(tostring(variableName or ""))
	if variableName == "" then
		if cb then
			cb(false, "variable vacía")
		end
		return
	end
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "setVariableValue", variableName = variableName },
		body = tostring(value or ""),
		content_type = "text/plain",
		accept = "application/xml",
	}, function(body, status)
		local msg = parse_exception(body)
		if msg or not tostring(status):match("^2") then
			if cb then
				cb(false, msg or ("ADT no soporta setVariableValue o lo rechazó (HTTP " .. tostring(status) .. ")"))
			end
			return
		end
		if cb then
			cb(true)
		end
	end)
end

function M.jump(uri, cb)
	curl({
		method = "POST",
		path = "/sap/bc/adt/debugger",
		query = { method = "stepJumpToLine", uri = uri },
		accept = "application/xml",
	}, function(body, status)
		local msg = parse_exception(body)
		if msg then
			if cb then
				cb({ error = msg })
			end
			return
		end
		if cb then
			cb({ ended = false })
		end
	end)
end

function M.stop(cb)
	local s = M.session
	if not s then
		if cb then
			cb()
		end
		return
	end
	s.stopping = true
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
		pcall(os.remove, s.jar)
		M.session = nil
		if cb then
			cb()
		end
	end)
end

-- 🔥 RESTAURADO: Función para matar todas las sesiones huérfanas
function M.terminate_all(cb)
	local function purge(s)
		s.stopping = true
		if s.listener_job then
			pcall(vim.fn.jobstop, s.listener_job)
			s.listener_job = nil
		end
		local variants = { s.ideId, "" }
		local left = #variants
		for _, idev in ipairs(variants) do
			curl({
				method = "DELETE",
				path = "/sap/bc/adt/debugger/listeners",
				query = {
					debuggingMode = "user",
					requestUser = s.user,
					terminalId = s.terminalId,
					ideId = idev,
					checkConflict = "false",
					notifyConflict = "true",
				},
			}, function(_, status)
				left = left - 1
				if left <= 0 then
					pcall(os.remove, s.jar)
					M.session = nil
					vim.schedule(function()
						vim.notify("[sap-nvim] Sesiones de debug cerradas y limpiadas.", vim.log.levels.INFO)
					end)
					if cb then
						cb()
					end
				end
			end)
		end
	end

	local function run()
		if M.session then
			purge(M.session)
		else
			M.init_session(function(ok)
				if ok then
					purge(M.session)
				elseif cb then
					cb()
				end
			end)
		end
	end

	local ok_cfg, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	if ok_cfg and cfg.confirm_destructive ~= false then
		vim.ui.input({ prompt = "Cerrar sesiones/listeners de debug. Escribe DEBUG para confirmar: " }, function(input)
			if vim.trim(input or "") ~= "DEBUG" then
				if cb then cb() end
				return
			end
			run()
		end)
		return
	end
	run()
end

function M.setup()
	vim.api.nvim_create_user_command("SapDebugKillAll", function()
		M.terminate_all()
	end, { desc = "sap-nvim: Cerrar TODAS las sesiones de debug del usuario" })
	vim.keymap.set("n", "<leader>dX", function()
		M.terminate_all()
	end, { desc = "Debug: Cerrar sesiones SAP" })
end

return M
