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
  if DEBUG then print("[dap] " .. msg) end
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
  local ok, objtype = pcall(require, "sap-nvim.core.objtype")
  if not ok then return nil end
  local group = objtype.group(path)
  local name = objtype.name(path)
  local tmpl = group and ADT_URI[group]
  if not tmpl or not name or name == "" then return nil end
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
-- sourceReference para fuentes remotas (VFS): mapea ref<->uri ADT, dedupe por uri.
local function source_ref(uri)
  if state.srcref_by_uri[uri] then return state.srcref_by_uri[uri] end
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
    if n then name = n:upper(); group = p[2]; break end
  end
  name = name or (frame.include or frame.program) or "ABAP"
  group = group or "program"

  if oks and oko then
    local path = source.cache_dir() .. "/" .. objtype.gitfile(group, name)
    if vim.fn.filereadable(path) == 1 then
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
  if not state or not state.sock then return end
  msg.seq = state.seq
  state.seq = state.seq + 1
  local json = vim.json.encode(msg)
  state.sock:write(("Content-Length: %d\r\n\r\n%s"):format(#json, json))
end

local function respond(req, body, success)
  send({ type = "response", request_seq = req.seq, success = success ~= false,
    command = req.command, body = body or vim.empty_dict() })
end

local function event(ev, body)
  send({ type = "event", event = ev, body = body or vim.empty_dict() })
end

-- ── varrefs (referencias de variables expandibles) ───────────────────────────

local function reset_varrefs()
  state.varrefs = {}
  state.varctr = 1
end
local function new_varref(adt_id)
  local ref = state.varctr
  state.varctr = state.varctr + 1
  state.varrefs[ref] = adt_id
  return ref
end

-- ── stopped / terminated ─────────────────────────────────────────────────────

local function emit_stopped(reason)
  reset_varrefs()
  state.current_frame = nil -- tras parar, el cursor del debugger está en el frame top
  event("stopped", { reason = reason or "breakpoint", threadId = 1, allThreadsStopped = true })
end

local function emit_terminated()
  event("terminated")
  log("terminated")
end

-- ── Handlers por comando DAP ─────────────────────────────────────────────────

local handlers = {}

function handlers.initialize(req)
  respond(req, {
    supportsConfigurationDoneRequest = true,
    supportsTerminateRequest = true,
    supportsStepInTargetsRequest = false,
    supportsEvaluateForHovers = false,
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
  for _, b in ipairs(bps) do
    table.insert(state.pending_bps, { uri = uri, line = b.line })
    -- verificación optimista; la real ocurre al setear en SAP (configurationDone).
    table.insert(resp_bps, { verified = uri ~= nil, line = b.line })
  end
  if uri then state.source_uri = uri end
  respond(req, { breakpoints = resp_bps })
end

function handlers.configurationDone(req)
  respond(req)
  -- Ahora sí: sesión ADT -> breakpoints -> listen.
  dbg.init_session(function(ok)
    if not ok then emit_terminated(); return end
    -- setear todos los breakpoints pendientes en SAP
    local pending = state.pending_bps
    local i = 0
    local function next_bp()
      i = i + 1
      local bp = pending[i]
      if not bp then
        -- todos puestos: escuchar
        event("output", { category = "console", output = "[ABAP] Esperando ejecución (external breakpoints). Ejecuta el objeto…\n" })
        dbg.listen(function()
          emit_stopped("breakpoint")
        end)
        return
      end
      if bp.uri then
        dbg.set_breakpoint(bp.uri, bp.line, function(verified)
          if not verified then
            event("output", { category = "stderr", output = "[ABAP] Breakpoint L" .. bp.line .. " rechazado (línea no ejecutable).\n" })
          end
          next_bp()
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

function handlers.variables(req)
  local ref = req.arguments and req.arguments.variablesReference
  local adt_id = ref and state.varrefs[ref]
  if not adt_id then respond(req, { variables = {} }); return end
  dbg.get_variables(adt_id, function(vars)
    local out = {}
    for _, v in ipairs(vars) do
      out[#out + 1] = {
        name = v.name or "?",
        value = (v.value ~= "" and v.value) or (v.meta == "table" and ("table[" .. v.table_lines .. "]") or "''"),
        type = v.type or v.meta,
        variablesReference = v.expandable and new_varref(v.id) or 0,
      }
    end
    respond(req, { variables = out })
  end)
end

-- Pilar 1 (VFS remoto): el cliente pide el contenido de una fuente remota por sourceReference.
function handlers.source(req)
  local args = req.arguments or {}
  local ref = args.sourceReference or (args.source and args.source.sourceReference)
  local uri = ref and state.srcrefs[ref]
  if not uri then respond(req, { content = "" }); return end
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
    if r.ended then emit_terminated()
    elseif not r.error then emit_stopped("step")
    else event("output", { category = "stderr", output = "[ABAP] " .. r.error .. "\n" }) end
  end)
end
function handlers.continue(req) do_step(req, "stepContinue", { allThreadsContinued = true }) end
function handlers.next(req) do_step(req, "stepOver") end
function handlers.stepIn(req) do_step(req, "stepInto") end
function handlers.stepOut(req) do_step(req, "stepReturn") end

local function teardown(req)
  dbg.stop(function() respond(req) end)
  if state and state.server then pcall(function() state.server:close() end) end
end
handlers.disconnect = teardown
handlers.terminate = teardown

-- ── Servidor TCP + parser de framing ─────────────────────────────────────────

local function on_message(msg)
  if msg.type ~= "request" then return end
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
    if err then log("listen err: " .. err); return end
    local sock = vim.loop.new_tcp()
    server:accept(sock)
    state = { sock = sock, seq = 1, server = server, source_uri = nil,
      pending_bps = {}, frames = {}, varrefs = {}, varctr = 1, config = {},
      current_frame = nil, srcrefs = {}, srcref_by_uri = {}, srcctr = 5000 }
    local buf = ""
    sock:read_start(function(rerr, chunk)
      if rerr or not chunk then pcall(function() sock:close() end); return end
      buf = buf .. chunk
      while true do
        local _, he = buf:find("\r\n\r\n", 1, true)
        if not he then break end
        local len = tonumber(buf:sub(1, he):match("Content%-Length:%s*(%d+)"))
        if not len then buf = buf:sub(he + 1) break end
        if #buf < he + len then break end
        local body = buf:sub(he + 1, he + len)
        buf = buf:sub(he + len + 1)
        local ok, decoded = pcall(vim.json.decode, body)
        if ok then vim.schedule(function() on_message(decoded) end) end
      end
    end)
  end)
  callback({ type = "server", host = "127.0.0.1", port = port })
end

-- ── Registro en nvim-dap ─────────────────────────────────────────────────────

function M.setup()
  local ok, dap = pcall(require, "dap")
  if not ok then return end -- nvim-dap no instalado

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

  vim.api.nvim_create_user_command("SapDap", function() require("dap").continue() end,
    { desc = "sap-nvim: Lanzar el debugger ABAP (nvim-dap)" })
end

return M
