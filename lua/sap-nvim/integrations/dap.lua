-- sap-nvim.integrations.dap  (F18 fase 2)
-- Adaptador nvim-dap para el debugger ABAP. Levanta un servidor DAP TCP in-process (Lua puro,
-- vim.loop) que habla el protocolo DAP (framing Content-Length + JSON) y traduce cada request
-- a core/debugger.lua (cliente ADT validado). nvim-dap se conecta como type="server".
--
-- v1: flujo attach -> breakpoints -> stopped -> stackTrace/scopes/variables -> step -> terminate.
-- Limitaciones conocidas (TODO): variables siempre del frame actual (sin goToStack por frame),
-- breakpoints verificados de forma optimista. Necesita prueba en vivo con nvim-dap + SAP.

local M = {}
local dbg = require("sap-nvim.core.debugger")

local DEBUG = true
local function log(msg)
	if DEBUG then
		print("[dap] " .. msg)
	end
end

-- Estado de la sesión DAP (una a la vez).
local state = nil
-- { sock, seq, server, source_uri, pending_bps, frames, varrefs, varctr }

-- ── Mapeo fichero <-> ADT uri ────────────────────────────────────────────────

local ADT_URI = {
	program = "/sap/bc/adt/programs/programs/%s/source/main",
	class = "/sap/bc/adt/oo/classes/%s/source/main",
	interface = "/sap/bc/adt/oo/interfaces/%s/source/main",
	include = "/sap/bc/adt/programs/includes/%s/source/main",
	functiongroup = "/sap/bc/adt/functions/groups/%s/source/main",
}

-- path local de caché -> uri ADT de source/main (para setBreakpoints).
local function file_to_uri(path)
	-- 1. Buscamos el buffer de Neovim que contiene este archivo para sacar su URI oficial
	for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
		local bufname = vim.api.nvim_buf_get_name(bufnr)
		-- Normalizamos por si hay líos de barras Windows/Linux
		local norm_path = path:gsub("\\", "/")
		local norm_buf = bufname:gsub("\\", "/")

		-- Si el buffer es el archivo que nvim-dap está pidiendo...
		if norm_buf == norm_path or norm_buf:match(norm_path:gsub("([%-%^%$%(%)%%%.%[%]%*%+%-%?])", "%%%1") .. "$") then
			local sap_obj = vim.b[bufnr].sap_obj
			if sap_obj and sap_obj.uri then
				-- Devolvemos la URI exacta, limpiando el ?version=active si lo tuviera
				return sap_obj.uri:gsub("%?.*$", "")
			end
		end
	end

	-- 2. Fallback (si el archivo no está abierto, adivinamos como antes)
	local ok, objtype = pcall(require, "sap-nvim.core.objtype")
	if not ok then
		return nil
	end
	local group = objtype.group(path)
	local name = objtype.name(path)
	local tmpl = group and ADT_URI[group]
	if not tmpl or not name or name == "" then
		return nil
	end
	return tmpl:format(name:lower())
end

-- frame ADT -> path de caché local (para source en stackTrace). Usa la adtcore:uri del frame.
local URI_GROUP = {
	{ "/sap/bc/adt/programs/programs/([^/]+)", "program" },
	{ "/sap/bc/adt/oo/classes/([^/]+)", "class" },
	{ "/sap/bc/adt/oo/interfaces/([^/]+)", "interface" },
	{ "/sap/bc/adt/programs/includes/([^/]+)", "include" },
	{ "/sap/bc/adt/functions/groups/([^/]+)", "functiongroup" },
}

local function materialize_source(uri, group, name)
	local oks, source = pcall(require, "sap-nvim.core.source")
	local oko, objtype = pcall(require, "sap-nvim.core.objtype")
	local okh, adt_http = pcall(require, "sap-nvim.core.adt_http")
	if not (oks and oko and okh and uri and group and name) then
		return nil
	end
	local path = source.cache_dir() .. "/" .. objtype.gitfile(group, name)
	if vim.fn.filereadable(path) == 1 then
		return path
	end
	local source_uri = uri:gsub("#.*$", "")
	if not source_uri:match("/source/main$") then
		source_uri = source_uri .. "/source/main"
	end
	local body, _, code = adt_http.raw({ method = "GET", path = source_uri, accept = "text/plain" })
	if code >= 200 and code < 300 and body and body ~= "" and not adt_http.is_auth_error(body) then
		pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
		pcall(vim.fn.writefile, vim.split(body:gsub("\r", ""), "\n", { plain = true }), path)
		return path
	end
	return nil
end

-- sourceReference para fuentes remotas (VFS): mapea ref<->uri ADT, dedupe por uri.
local function source_ref(uri)
	if state.srcref_by_uri[uri] then
		return state.srcref_by_uri[uri]
	end
	local ref = state.srcctr
	state.srcctr = state.srcctr + 1
	state.srcrefs[ref] = uri
	state.srcref_by_uri[uri] = ref
	return ref
end

-- DAP source de un frame: si el objeto YA está en caché local -> path (alineado con el buffer
-- real, para breakpoints). Si no -> sourceReference + fetch on-demand (Pilar 1, VFS remoto).
local function frame_source(frame)
	local oks, source = pcall(require, "sap-nvim.core.source")
	local oko, objtype = pcall(require, "sap-nvim.core.objtype")
	local name, group
	for _, p in ipairs(URI_GROUP) do
		local n = frame.uri and frame.uri:match(p[1])
		if n then
			name = n:upper()
			group = p[2]
			break
		end
	end
	name = name or (frame.include or frame.program) or "ABAP"
	group = group or "program"

	if oks and oko then
		local path = materialize_source(frame.uri, group, name)
		if path then
			return { name = name, path = path }
		end
	end
	-- remoto: el cliente pedirá el contenido con un request `source` (handlers.source).
	local src_uri = frame.uri and frame.uri:gsub("#.*$", "")
	if src_uri and src_uri ~= "" then
		return { name = name, sourceReference = source_ref(src_uri) }
	end
	return nil
end

-- ── Wire DAP (framing Content-Length + JSON) ─────────────────────────────────

local function send(msg)
	if not state or not state.sock then
		return
	end
	msg.seq = state.seq
	state.seq = state.seq + 1
	local json = vim.json.encode(msg)
	state.sock:write(("Content-Length: %d\r\n\r\n%s"):format(#json, json))
end

local function respond(req, body, success)
	send({
		type = "response",
		request_seq = req.seq,
		success = success ~= false,
		command = req.command,
		body = body or vim.empty_dict(),
	})
end

local function event(ev, body)
	send({ type = "event", event = ev, body = body or vim.empty_dict() })
end

-- ── varrefs (referencias de variables expandibles) ───────────────────────────

local function reset_varrefs()
	state.varrefs = {}
	state.varctr = 1
	state.varids = {} -- [ref] = { [name] = adt_id }  para setVariable
end
-- info = { id, meta, lines }. Guardamos meta/lines para saber si al expandir es una TABLA
-- (filas por getVariables) o una estructura/scope (campos por getChildVariables).
local function new_varref(info)
	if type(info) ~= "table" then
		info = { id = info }
	end
	local ref = state.varctr
	state.varctr = state.varctr + 1
	state.varrefs[ref] = info
	return ref
end

-- ── stopped / terminated ─────────────────────────────────────────────────────

local function close_dapui()
	local ok, dapui = pcall(require, "dapui")
	if ok and dapui.close then
		pcall(dapui.close)
	end
end

local function emit_stopped(reason)
	reset_varrefs()
	state.current_frame = nil -- tras parar, el cursor del debugger está en el frame top
	close_dapui()
	event("invalidated", { areas = { "variables" }, threadId = 1 })
	local preserve_focus = state and state.preserve_focus_next_stop == true
	if state then
		state.preserve_focus_next_stop = false
	end
	event("stopped", {
		reason = reason or "breakpoint",
		threadId = 1,
		allThreadsStopped = true,
		preserveFocusHint = preserve_focus or nil,
	})
	pcall(function()
		local preview = require("sap-nvim.core.preview")
		local focus = not (preview.should_preserve_focus and preview.should_preserve_focus())
		preview.open_cockpit({ focus = focus, preserve_cursor = true })
		preview.refresh_active()
	end)
end

local function emit_terminated()
	close_dapui()
	event("terminated")
	log("terminated")
	-- A5: al terminar la depuración cerramos la sesión ADT stateful (cookies + listener)
	-- en lugar de dejarla viva hasta :SapDebugKillAll. Guard idempotente para no
	-- duplicar el cierre si `teardown` ya lo lanzó.
	if dbg.session and not (state and state.__teardown_done) then
		if state then
			state.__teardown_done = true
		end
		dbg.stop(function() end)
	end
end

-- ── Handlers por comando DAP ─────────────────────────────────────────────────

local handlers = {}

function handlers.initialize(req)
	respond(req, {
		supportsConfigurationDoneRequest = true,
		supportsTerminateRequest = true,
		supportsSetVariable = dbg.can_set_variable and dbg.can_set_variable() or false,
		supportsGotoTargetsRequest = true,
		supportsStepInTargetsRequest = false,
		supportsEvaluateForHovers = true, -- 🔥 ESTO ESTABA EN FALSE
		supportsCompletionsRequest = true,
		completionTriggerCharacters = { "-", "[", "]" },
		supportsInvalidatedEvent = true,
	})
	event("initialized")
end

function handlers.attach(req)
	-- No arrancamos la sesión aquí: esperamos a configurationDone (tras setBreakpoints).
	state.config = req.arguments or {}
	respond(req)
end
handlers.launch = handlers.attach

function handlers.setBreakpoints(req)
	local args = req.arguments or {}
	local path = args.source and args.source.path
	local uri = path and file_to_uri(path)
	local bps = args.breakpoints or {}
	local resp_bps = {}
	if uri and #bps == 0 then
		local kept = {}
		for _, bp in ipairs(state.pending_bps or {}) do
			if bp.uri ~= uri and bp.path ~= path then
				kept[#kept + 1] = bp
			end
		end
		state.pending_bps = kept
		if dbg.session then
			dbg.clear_breakpoints_for_sources({ uri }, function()
				respond(req, { breakpoints = {} })
			end)
		else
			respond(req, { breakpoints = {} })
		end
		return
	end
	for _, b in ipairs(bps) do
		state.bpctr = (state.bpctr or 0) + 1
		local id = state.bpctr
		table.insert(state.pending_bps, { uri = uri, path = path, line = b.line, id = id })
		-- verificación optimista; la real (verified=false si SAP rechaza) se corrige en
		-- configurationDone con un evento `breakpoint`.
		table.insert(resp_bps, { id = id, verified = uri ~= nil, line = b.line })
	end
	if uri then
		state.source_uri = uri
	end
	respond(req, { breakpoints = resp_bps })
end

function handlers.configurationDone(req)
	respond(req)
	-- Ahora sí: sesión ADT -> breakpoints -> listen.
	dbg.init_session(function(ok)
		if not ok then
			emit_terminated()
			return
		end
		-- setear todos los breakpoints pendientes en SAP
		local pending = state.pending_bps
		local i = 0
		local function next_bp()
			i = i + 1
			local bp = pending[i]
			if not bp then
				-- todos puestos: escuchar
				event("output", {
					category = "console",
					output = "[ABAP] Esperando ejecución (external breakpoints). Ejecuta el objeto…\n",
				})
				dbg.listen(function()
					emit_stopped("breakpoint")
				end)
				return
			end
			if bp.uri then
				-- Resolver la URI real: para INCLUDES (forms) es la URI VIT con el programa
				-- principal; para program/class es la source/main. Reutiliza objtype para el tipo.
				local ok_ot, objtype = pcall(require, "sap-nvim.core.objtype")
				local group = ok_ot and bp.path and objtype.group(bp.path) or nil
				local name = ok_ot and bp.path and objtype.name(bp.path) or nil
				dbg.resolve_bp_uri(group, name, bp.uri, function(bp_uri, sync_scope)
				dbg.set_breakpoint(bp_uri, bp.line, function(verified, info)
					if not verified then
						local why = (info and info.errorMessage) or "SAP rechazó el breakpoint"
						-- Marca el breakpoint como NO verificado en dap-ui (hueco) con el motivo.
						if bp.id then
							event("breakpoint", {
								reason = "changed",
								breakpoint = { id = bp.id, verified = false, line = bp.line, message = why },
							})
						end
						event("output", {
							category = "stderr",
							output = "[ABAP] Breakpoint L"
								.. bp.line
								.. " rechazado: "
								.. why
								.. " (¿línea ejecutable? ¿buffer = versión activa en SAP?)\n",
						})
					end
					next_bp()
				end, sync_scope, { source_uri = bp.uri })
				end)
			else
				next_bp()
			end
		end
		next_bp()
	end)
end

function handlers.threads(req)
	respond(req, { threads = { { id = 1, name = "ABAP" } } })
end

function handlers.stackTrace(req)
	dbg.get_stack(function(frames)
		state.frames = {}
		local out = {}
		for idx, f in ipairs(frames) do
			state.frames[idx] = f
			out[#out + 1] = {
				id = idx,
				name = (f.program or "?") .. (f.eventName and (" · " .. f.eventName) or ""),
				line = f.line or 1,
				column = 1,
				source = frame_source(f),
				presentationHint = f.systemProgram and "subtle" or "normal",
			}
		end
		respond(req, { stackFrames = out, totalFrames = #out })
	end)
end

function handlers.scopes(req)
	local frameId = req.arguments and req.arguments.frameId
	local frame = frameId and state.frames[frameId]

	local function fetch_scopes()
		dbg.get_variables("@ROOT", function(_, scopes)
			local out = {}
			for _, sc in ipairs(scopes) do
				out[#out + 1] = { name = sc.name, variablesReference = new_varref(sc.id), expensive = false }
			end
			-- si @ROOT no devolvió scopes nombrados, ofrecer Globals por defecto
			if #out == 0 then
				out[1] = { name = "Globals", variablesReference = new_varref("@GLOBALS"), expensive = false }
			end
			respond(req, { scopes = out })
		end)
	end

	-- Pilar 1 — variables POR FRAME: si el frame pedido no es el actual, posicionamos el
	-- cursor del debugger en él (goToStack) ANTES de leer sus scopes/variables.
	if frame and frame.stackUri and state.current_frame ~= frameId then
		dbg.goto_stack(frame.stackUri, function()
			state.current_frame = frameId
			reset_varrefs() -- las refs anteriores eran de otro frame
			fetch_scopes()
		end)
	else
		fetch_scopes()
	end
end

-- Mapea una variable del debugger -> Variable DAP. Tablas/estructuras quedan expandibles.
local function to_dap(ref, name, v)
	state.varids[ref] = state.varids[ref] or {}
	state.varids[ref][name] = v.id -- para setVariable
	local value = (v.value and v.value ~= "" and v.value)
		or (v.meta == "table" and ("Standard Table [" .. (v.table_lines or 0) .. " filas]"))
		or (v.meta == "structure" and "{ … }")
		or "''"
	return {
		name = name,
		value = value,
		type = v.type or v.meta,
		variablesReference = v.expandable and new_varref({ id = v.id, meta = v.meta, lines = v.table_lines }) or 0,
		indexedVariables = v.meta == "table" and (v.table_lines or 0) or nil,
	}
end

function handlers.variables(req)
	local ref = req.arguments and req.arguments.variablesReference
	local info = ref and state.varrefs[ref]
	if not info then
		respond(req, { variables = {} })
		return
	end

	if info.meta == "table" then
		-- A2: respetar la paginación que pide el cliente DAP. Cuando llegan `start`
		-- (0-based) y `count`, pedimos SOLO ese rango de filas; si no, mantenemos el
		-- comportamiento previo (primera página de MAX_CHILDREN filas).
		local args = req.arguments or {}
		local total = info.lines or 0
		local count = tonumber(args.count)
		local paged = count ~= nil and count > 0
		local offset = paged and (tonumber(args.start) or 0) or nil
		local limit = paged and count or nil
		dbg.get_table_rows(info.id, total, function(rows)
			local base = offset or 0
			local out = {}
			for i, v in ipairs(rows) do
				-- el índice mostrado refleja la fila real dentro de la tabla
				out[#out + 1] = to_dap(ref, "[" .. (base + i) .. "]", v)
			end
			respond(req, { variables = out })
		end, offset, limit)
	else
		-- Estructura / scope: campos por getChildVariables.
		dbg.get_variables(info.id, function(vars)
			local out = {}
			for _, v in ipairs(vars) do
				out[#out + 1] = to_dap(ref, v.name or "?", v)
			end
			respond(req, { variables = out })
		end)
	end
end

-- Pilar 5 — jump-to-line: el cliente pide targets para una línea y luego salta a uno.
function handlers.gotoTargets(req)
	local a = req.arguments or {}
	local path = a.source and a.source.path
	local line = a.line
	local uri = path and file_to_uri(path)
	if not uri or not line then
		respond(req, { targets = {} })
		return
	end
	local id = state.gotoctr
	state.gotoctr = state.gotoctr + 1
	state.goto_targets[id] = uri .. "#start=" .. line
	respond(req, { targets = { { id = id, label = "→ línea " .. line, line = line } } })
end

handlers["goto"] = function(req)
	local a = req.arguments or {}
	local uri = a.targetId and state.goto_targets[a.targetId]
	if not uri then
		respond(req, nil, false)
		return
	end
	respond(req)
	dbg.jump(uri, function(r)
		if r.error then
			event("output", { category = "stderr", output = "[ABAP] jump: " .. r.error .. "\n" })
		else
			emit_stopped("goto")
		end
	end)
end

-- Pilar 2 — setVariable: mutar un escalar en runtime. El id ADT se resuelve por (ref, name).
function handlers.setVariable(req)
	local a = req.arguments or {}
	local ref, name, value = a.variablesReference, a.name, a.value
	local id = (ref and state.varids[ref] and state.varids[ref][name]) or name
	dbg.set_variable(id, value, function(ok, err)
		if ok then
			respond(req, { value = value })
		else
			respond(req, {
				error = {
					id = 1,
					format = "No se pudo cambiar '"
						.. tostring(name)
						.. "': "
						.. tostring(err or "¿escalar/autorización?"),
				},
			}, false)
		end
	end)
end

-- Nuevo Pilar: Evaluate (Hover y panel de Expressions)
function handlers.evaluate(req)
	local a = req.arguments or {}
	local expr = a.expression
	if not expr or expr == "" then
		respond(req, { error = { id = 1, format = "Expresión vacía" } }, false)
		return
	end

	-- ADT evalúa una variable/expresión si la pasas como ID (en mayúsculas: ABAP es
	-- case-insensitive y los IDs del debugger van en mayúsculas). Vale para nombres
	-- simples, campos de estructura (LS_X-CAMPO) y filas de tabla (LT_X[1]-CAMPO).
	local adt_id = vim.trim(expr):upper()

	-- CLAVE: getVariables (get_vars_by_id), NO getChildVariables (get_variables).
	-- getChildVariables devuelve los HIJOS de un nodo (vacío para un escalar);
	-- getVariables evalúa el ID y devuelve su <VALUE>.
	dbg.get_vars_by_id({ adt_id }, function(vars)
		if not vars or #vars == 0 then
			respond(req, { error = { id = 2, format = "No evaluable o fuera de scope: " .. adt_id } }, false)
			return
		end

		local v = vars[1]
		local result_val = (v.value and v.value ~= "" and v.value)
			or (v.meta == "table" and ("Standard Table [" .. (v.table_lines or 0) .. " filas]"))
			or (v.meta == "structure" and "{ … }")
			or "''"

		respond(req, {
			result = result_val,
			type = v.type or v.meta,
			-- Tabla/estructura: referencia con {id,meta,lines} para que handlers.variables
			-- sepa despachar (filas por getVariables vs campos por getChildVariables) al expandir.
			variablesReference = v.expandable and new_varref({ id = v.id, meta = v.meta, lines = v.table_lines })
				or 0,
		})
	end)
end

local function completion_prefix(text, column)
	local upto = tostring(text or ""):sub(1, math.max(0, (column or 1) - 1))
	local owner, field_prefix = upto:match("([%w_<>/]+)%-([%w_]*)$")
	if owner then
		return upto, owner:upper(), field_prefix:upper()
	end
	local prefix = upto:match("([%w_<>/]+)$") or ""
	return upto, nil, prefix:upper()
end

function handlers.completions(req)
	local a = req.arguments or {}
	local _, owner, prefix = completion_prefix(a.text or "", a.column or 1)

	local function finish(vars)
		local targets = {}
		local seen = {}
		for _, v in ipairs(vars or {}) do
			local name = (v.name or ""):upper()
			if name ~= "" and not seen[name] and (prefix == "" or name:sub(1, #prefix) == prefix) then
				seen[name] = true
				targets[#targets + 1] = {
					label = v.name,
					text = v.name,
					type = v.meta == "table" and "variable" or (v.meta == "structure" and "field" or "value"),
				}
			end
		end
		table.sort(targets, function(x, y) return x.label < y.label end)
		respond(req, { targets = targets })
	end

	if owner then
		dbg.get_vars_by_id(owner, function(found)
			local v = found and found[1]
			if not v or not v.expandable then
				return respond(req, { targets = {} })
			end
			dbg.get_variables(v.id, function(fields)
				finish(fields)
			end)
		end)
		return
	end

	dbg.get_variables({ "@LOCALS", "@GLOBALS" }, function(vars)
		finish(vars)
	end)
end
-- Pilar 1 (VFS remoto): el cliente pide el contenido de una fuente remota por sourceReference.
function handlers.source(req)
	local args = req.arguments or {}
	local ref = args.sourceReference or (args.source and args.source.sourceReference)
	local uri = ref and state.srcrefs[ref]
	if not uri then
		respond(req, { content = "" })
		return
	end
	local adt_http = require("sap-nvim.core.adt_http")
	adt_http.request_async({ method = "GET", path = uri, accept = "text/plain" }, function(body)
		vim.schedule(function()
			respond(req, { content = (body and body:gsub("\r", "")) or "* (no se pudo cargar la fuente remota)" })
		end)
	end)
end

-- continue/next/stepIn/stepOut: respondemos ya y el step (que bloquea hasta la próxima
-- parada o el fin) dispara stopped/terminated después.
local function do_step(req, action, body)
	respond(req, body)
	dbg.step(action, function(r)
		if r.ended then
			emit_terminated()
		elseif not r.error then
			emit_stopped("step")
		else
			event("output", { category = "stderr", output = "[ABAP] " .. r.error .. "\n" })
		end
	end)
end
function handlers.continue(req)
	do_step(req, "stepContinue", { allThreadsContinued = true })
end
function handlers.next(req)
	do_step(req, "stepOver")
end
function handlers.stepIn(req)
	do_step(req, "stepInto")
end
function handlers.stepOut(req)
	do_step(req, "stepReturn")
end

local function teardown(req)
	if state then
		state.__teardown_done = true
	end
	dbg.stop(function()
		respond(req)
	end)
	if state and state.server then
		pcall(function()
			state.server:close()
		end)
	end
end
handlers.disconnect = teardown
handlers.terminate = teardown

-- ── Limpieza de breakpoints ABAP/DAP ────────────────────────────────────────

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function bp_source_uri(bufnr)
	local path = vim.api.nvim_buf_get_name(bufnr)
	local uri = path ~= "" and file_to_uri(path) or nil
	if uri then
		return uri:gsub("%?.*$", "")
	end
	local ok, intel = pcall(require, "sap-nvim.core.intel")
	if ok and intel.object_uri then
		uri = intel.object_uri(bufnr)
		return uri and uri:gsub("%?.*$", "") or nil
	end
	return nil
end

local function add_buf(set, out, bufnr)
	if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not set[bufnr] then
		set[bufnr] = true
		out[#out + 1] = bufnr
	end
end

local function related_breakpoint_buffers(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local set, out = {}, {}
	add_buf(set, out, bufnr)

	local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
	if not ok_adt or not adt.related_object_names then
		return out
	end

	local names = adt.related_object_names(bufnr)
	local ok_bp, breakpoints = pcall(require, "dap.breakpoints")
	if ok_bp then
		for b, _ in pairs(breakpoints.get()) do
			if vim.api.nvim_buf_is_valid(b) then
				local meta = vim.b[b].sap_obj
				local name = meta and meta.name or nil
				if not name or name == "" then
					local ok_objtype, objtype = pcall(require, "sap-nvim.core.objtype")
					name = ok_objtype and objtype.name(vim.api.nvim_buf_get_name(b)) or nil
				end
				if name and names[name:upper()] then
					add_buf(set, out, b)
				end
			end
		end
	end
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		local meta = vim.b[b].sap_obj
		if meta and meta.name and names[meta.name:upper()] then
			add_buf(set, out, b)
		end
	end
	return out
end

local function clear_breakpoints(bufnrs, label)
	local ok_bp, breakpoints = pcall(require, "dap.breakpoints")
	if not ok_bp then
		notify("nvim-dap no está disponible.", vim.log.levels.WARN)
		return
	end

	local ids, sources = {}, {}
	local local_count = 0
	for _, bufnr in ipairs(bufnrs) do
		local uri = bp_source_uri(bufnr)
		if uri then
			sources[#sources + 1] = uri
		end
		local bps = breakpoints.get(bufnr)[bufnr] or {}
		for _, bp in ipairs(bps) do
			if bp.state and bp.state.id then
				ids[#ids + 1] = bp.state.id
			end
			if breakpoints.remove(bufnr, bp.line) then
				local_count = local_count + 1
			end
		end
	end

	local function finish(remote)
		pcall(function()
			require("dapui.elements.breakpoints").render()
		end)
		local deleted = (remote and remote.deleted) or 0
		local failed = (remote and remote.failed) or 0
		local msg = ("%s: %d local(es), %d SAP"):format(label, local_count, deleted)
		if failed > 0 then
			msg = msg .. (", " .. failed .. " fallo(s)")
		end
		notify(msg, failed > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
	end

	local combined = { deleted = 0, failed = 0 }
	dbg.clear_breakpoints_by_ids(ids, function(by_id)
		combined.deleted = combined.deleted + ((by_id and by_id.deleted) or 0)
		combined.failed = combined.failed + ((by_id and by_id.failed) or 0)
		dbg.clear_breakpoints_for_sources(sources, function(by_source)
			combined.deleted = combined.deleted + ((by_source and by_source.deleted) or 0)
			combined.failed = combined.failed + ((by_source and by_source.failed) or 0)
			finish(combined)
		end)
	end)
end

function M.clear_breakpoints_current()
	clear_breakpoints({ vim.api.nvim_get_current_buf() }, "Breakpoints del buffer limpiados")
end

function M.clear_breakpoints_related()
	clear_breakpoints(related_breakpoint_buffers(vim.api.nvim_get_current_buf()), "Breakpoints raíz + includes limpiados")
end

function M.step_from_preview(action)
	local ok, dap = pcall(require, "dap")
	if not ok then
		notify("nvim-dap no está disponible.", vim.log.levels.WARN)
		return
	end
	if state then
		state.preserve_focus_next_stop = true
	end
	local fn = ({
		continue = "continue",
		step_over = "step_over",
		step_into = "step_into",
		step_out = "step_out",
	})[action]
	if fn and dap[fn] then
		dap[fn]()
	end
end

local function mark_preserve_focus_if_preview()
	local ok_preview, preview = pcall(require, "sap-nvim.core.preview")
	if ok_preview and preview.should_preserve_focus and preview.should_preserve_focus() then
		if state then
			state.preserve_focus_next_stop = true
		end
	end
end

local function preview_aware_switchbuf(bufnr, line, column)
	local ok_preview, preview = pcall(require, "sap-nvim.core.preview")
	if ok_preview and preview.should_preserve_focus and preview.should_preserve_focus() then
		if preview.focus_source_in_cockpit and preview.focus_source_in_cockpit(bufnr, line, column) then
			return
		end
		return
	end

	local target_win
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_get_buf(win) == bufnr then
			target_win = win
			break
		end
	end
	if not target_win then
		target_win = vim.fn.win_getid(vim.fn.winnr("#"))
	end
	if target_win and target_win ~= 0 and vim.api.nvim_win_is_valid(target_win) then
		pcall(vim.api.nvim_set_current_win, target_win)
		pcall(vim.api.nvim_win_set_buf, target_win, bufnr)
		pcall(vim.api.nvim_win_set_cursor, target_win, { line, math.max((column or 1) - 1, 0) })
	end
end

-- ── Servidor TCP + parser de framing ─────────────────────────────────────────

local function on_message(msg)
	if msg.type ~= "request" then
		return
	end
	local h = handlers[msg.command]
	if h then
		local ok, err = pcall(h, msg)
		if not ok then
			log("handler " .. msg.command .. " error: " .. tostring(err))
			respond(msg, { error = { id = 1, format = tostring(err) } }, false)
		end
	else
		log("comando DAP no soportado: " .. tostring(msg.command))
		respond(msg, nil, true) -- responder vacío para no colgar al cliente
	end
end

local function start_server(callback)
	local server = vim.loop.new_tcp()
	server:bind("127.0.0.1", 0)
	local port = server:getsockname().port
	server:listen(128, function(err)
		if err then
			log("listen err: " .. err)
			return
		end
		local sock = vim.loop.new_tcp()
		server:accept(sock)
		state = {
			sock = sock,
			seq = 1,
			server = server,
			source_uri = nil,
			pending_bps = {},
			frames = {},
			varrefs = {},
			varctr = 1,
			config = {},
			current_frame = nil,
			srcrefs = {},
			srcref_by_uri = {},
			srcctr = 5000,
			varids = {},
			goto_targets = {},
			gotoctr = 9000,
		}
		local buf = ""
		sock:read_start(function(rerr, chunk)
			if rerr or not chunk then
				pcall(function()
					sock:close()
				end)
				return
			end
			buf = buf .. chunk
			while true do
				local _, he = buf:find("\r\n\r\n", 1, true)
				if not he then
					break
				end
				local len = tonumber(buf:sub(1, he):match("Content%-Length:%s*(%d+)"))
				if not len then
					buf = buf:sub(he + 1)
					break
				end
				if #buf < he + len then
					break
				end
				local body = buf:sub(he + 1, he + len)
				buf = buf:sub(he + len + 1)
				local ok, decoded = pcall(vim.json.decode, body)
				if ok then
					vim.schedule(function()
						on_message(decoded)
					end)
				end
			end
		end)
	end)
	callback({ type = "server", host = "127.0.0.1", port = port })
end

-- ── Registro en nvim-dap ─────────────────────────────────────────────────────

function M.setup()
	local ok, dap = pcall(require, "dap")
	if not ok then
		return
	end -- nvim-dap no instalado

	dap.adapters.abap = function(callback, _config)
		start_server(callback)
	end

	dap.configurations.abap = {
		{
			type = "abap",
			request = "attach",
			name = "ABAP: Adjuntar debugger (external breakpoints)",
		},
	}
	pcall(function()
		require("sap-nvim.core.preview").install_dap_focus_guard()
	end)
	for _, command in ipairs({ "continue", "next", "stepIn", "stepOut" }) do
		dap.listeners.before[command]["sap_nvim_preview_preserve_focus"] = mark_preserve_focus_if_preview
	end
	dap.defaults.abap.switchbuf = preview_aware_switchbuf

	vim.api.nvim_create_user_command("SapDap", function()
		close_dapui()
		pcall(function()
			require("sap-nvim.core.preview").open_cockpit()
		end)
		require("dap").continue()
		vim.defer_fn(function()
			close_dapui()
			pcall(function()
				require("sap-nvim.core.preview").open_cockpit()
			end)
		end, 250)
	end, { desc = "sap-nvim: Lanzar el debugger ABAP (nvim-dap)" })

	vim.api.nvim_create_user_command("SapDapClearBreakpoints", function()
		M.clear_breakpoints_current()
	end, { desc = "sap-nvim: Limpiar breakpoints del objeto/buffer actual" })

	vim.api.nvim_create_user_command("SapDapClearBreakpointsRecursive", function()
		M.clear_breakpoints_related()
	end, { desc = "sap-nvim: Limpiar breakpoints de raíz + includes relacionados" })

	-- 🔥 1. Configuración de la UI (Paneles anchos estilo SAP GUI)
	local ok_dapui, dapui = pcall(require, "dapui")
	if ok_dapui then
		dapui.setup({
			layouts = {
				{
					-- Panel Izquierdo: Ancho y con aspecto de explorador principal
					elements = {
						{ id = "scopes", size = 0.65 }, -- 65% del alto para variables
						{ id = "watches", size = 0.20 }, -- 20% para "Expressions"
						{ id = "stacks", size = 0.15 }, -- 15% para Call Stack
					},
					size = 75, -- Hacemos el panel casi el doble de ancho (defecto 40)
					position = "left",
				},
				{
					-- Panel Inferior: Consola
					elements = {
						{ id = "console", size = 1.0 },
					},
					size = 12,
					position = "bottom",
				},
			},
		})
	end

	-- 🔥 2. Atajo de teclado para la vista ALV
	vim.keymap.set("n", "<leader>dT", function()
		local ok_preview, preview = pcall(require, "sap-nvim.core.preview")
		if ok_preview then
			preview.show_alv()
		else
			vim.notify("Falta el archivo lua/sap-nvim/core/preview.lua", vim.log.levels.ERROR)
		end
	end, { desc = "DAP: ALV Table Preview" })

	vim.keymap.set("n", "<leader>db", function()
		M.clear_breakpoints_current()
	end, { desc = "DAP: Limpiar breakpoints del buffer" })

	vim.keymap.set("n", "<leader>dB", function()
		M.clear_breakpoints_related()
	end, { desc = "DAP: Limpiar breakpoints raíz + includes" })
end

return M
