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
    vim.schedule(function() vim.notify(line, vim.log.levels.INFO) end)
  end
end
local function fail(tag, msg)
  local line = "[dbg] " .. tag .. " FALLO: " .. msg
  print(line)
  vim.schedule(function() vim.notify(line, vim.log.levels.ERROR) end)
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
  return (tostring(s):gsub("[^%w%-_.!~*'()]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Extrae el mensaje de una <exc:exception> de ADT (o nil) + el subType (p.ej. debuggeeEnded).
local function parse_exception(body)
  if not body or not body:find("exception", 1, true) then return nil end
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
  if not c or not s then if cb then cb(nil, "no-session") end; return end

  local url = c.base .. opts.path
  url = url .. (opts.path:find("?") and "&" or "?") .. "sap-client=" .. c.client
  if opts.query then
    for k, v in pairs(opts.query) do url = url .. "&" .. k .. "=" .. urlenc(v) end
  end

  local hdrfile = vim.fn.tempname()
  local args = { "curl", "-sk", "-u", c.user .. ":" .. c.pass, "-b", s.jar, "-c", s.jar, "-D", hdrfile,
    "-H", "X-sap-adt-sessiontype: stateful" }
  vim.list_extend(args, { "-X", opts.method or "GET" })
  if opts.csrf_fetch then vim.list_extend(args, { "-H", "X-CSRF-Token: Fetch" })
  elseif s.csrf then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. s.csrf }) end
  if opts.accept then vim.list_extend(args, { "-H", "Accept: " .. opts.accept }) end
  if opts.content_type then vim.list_extend(args, { "-H", "Content-Type: " .. opts.content_type }) end

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
    on_stdout = function(_, d) for _, l in ipairs(d) do out[#out + 1] = l end end,
    on_exit = function(_, exit_code)
      local headers = ""
      pcall(function() headers = table.concat(vim.fn.readfile(hdrfile), "\n") end)
      if bodyfile then pcall(os.remove, bodyfile) end
      pcall(os.remove, hdrfile)
      local status
      for st in headers:gmatch("HTTP/[%d%.]+%s+(%d+)") do status = tonumber(st) end
      status = status or ("curl-exit-" .. exit_code)
      if cb then vim.schedule(function() cb(table.concat(out, "\n"), status, headers) end) end
    end,
  })
end

-- ── 1) init_session: cookie jar + CSRF ───────────────────────────────────────

function M.init_session(cb)
  if not adt_http.is_available() then fail("init", "ADT no disponible (config.yml/curl)."); if cb then cb(false) end; return end
  local c = adt_http.creds()
  local jar = vim.fn.stdpath("cache") .. "/sap-nvim/debug_" .. os.time() .. ".cookies"
  vim.fn.mkdir(vim.fn.fnamemodify(jar, ":h"), "p")
  pcall(os.remove, jar)

  local terminalId, ideId = stable_ids()
  M.session = {
    jar = jar, csrf = nil, terminalId = terminalId, ideId = ideId,
    user = c.user:upper(), listener_job = nil, debugSessionId = nil, breakpoints = {},
  }
  log("init", "sesión nueva user=" .. M.session.user)

  curl({ method = "GET", path = "/sap/bc/adt/core/discovery", csrf_fetch = true }, function(_, status, headers)
    local token = headers and headers:match("[Xx]%-[Cc][Ss][Rr][Ff]%-[Tt]oken:%s*(%S+)")
    if not token then fail("init", "sin token CSRF (HTTP " .. tostring(status) .. ")"); if cb then cb(false) end; return end
    M.session.csrf = token
    log("init", "CSRF OK, sesión stateful lista.")
    if cb then cb(true) end
  end)
end

-- ── 2) set_breakpoint ─────────────────────────────────────────────────────────
-- source_uri: ej. "/sap/bc/adt/programs/programs/znvim/source/main". line: número.
-- cb(verified, info) — info = { id, errorMessage, uri }.
function M.set_breakpoint(source_uri, line, cb)
  local s = M.session
  if not s then fail("bp", "sin sesión (init_session primero)."); if cb then cb(false, {}) end; return end
  local uri = source_uri .. "#start=" .. line
  local body = table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<dbg:breakpoints scope="external" debuggingMode="user" requestUser="' .. s.user .. '"',
    '  terminalId="' .. s.terminalId .. '" ideId="' .. s.ideId .. '" systemDebugging="false" deactivated="false"',
    '  xmlns:dbg="http://www.sap.com/adt/debugger">',
    '  <syncScope mode="full"></syncScope>',
    '  <breakpoint xmlns:adtcore="http://www.sap.com/adt/core" kind="line" clientId="sapnvim"',
    '    skipCount="0" adtcore:uri="' .. uri .. '"/>',
    '</dbg:breakpoints>',
  }, "\n")

  curl({
    method = "POST", path = "/sap/bc/adt/debugger/breakpoints",
    body = body, content_type = "application/xml", accept = "application/xml",
  }, function(resp, status)
    local errmsg = resp and resp:match('errorMessage="([^"]+)"')
    local id = resp and resp:match('<breakpoint[^>]-%sid="([^"]*)"')
    if parse_exception(resp) or (errmsg and errmsg ~= "") then
      fail("bp", "L" .. line .. " rechazado (HTTP " .. tostring(status) .. "): " .. (errmsg or "ver SAP"))
      if cb then cb(false, { errorMessage = errmsg or "rechazado", uri = uri }) end
      return
    end
    s.breakpoints[#s.breakpoints + 1] = { id = id, uri = uri, line = line }
    log("bp", "L" .. line .. " creado (id=" .. (id and id:sub(1, 40) or "?") .. "…)")
    if cb then cb(true, { id = id, uri = uri }) end
  end)
end

-- ── 4) attach ─────────────────────────────────────────────────────────────────
-- cb(ok, info) — info = { isPostMortem, debugSessionId, processId }.
function M.attach(debuggeeId, cb)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger",
    query = { method = "attach", debuggeeId = debuggeeId, debuggingMode = "user",
              requestUser = M.session.user, dynproDebugging = "true" },
    accept = "application/xml",
  }, function(body, status)
    if parse_exception(body) then
      fail("attach", "rechazado (HTTP " .. tostring(status) .. ")"); if cb then cb(false, {}) end; return
    end
    local info = {
      isPostMortem = (body and body:match('isPostMortem="true"')) ~= nil,
      debugSessionId = body and body:match('debugSessionId="([^"]*)"'),
      processId = body and body:match('processId="([^"]*)"'),
    }
    M.session.debugSessionId = info.debugSessionId
    log("attach", "OK sessionId=" .. (info.debugSessionId or "?") .. " postMortem=" .. tostring(info.isPostMortem))
    if cb then cb(true, info) end
  end)
end

-- ── 3) listen (long-poll) — ignora post-mortem, re-escucha hasta un live ─────
-- cb(debuggeeId, attach_info) cuando hay una parada EN VIVO.
function M.listen(cb)
  local s = M.session
  if not s then fail("listen", "sin sesión."); return end
  log("listen", "long-poll /listeners… (ejecuta el objeto para parar en el breakpoint)")
  s.listener_job = curl({
    method = "POST", path = "/sap/bc/adt/debugger/listeners",
    query = { debuggingMode = "user", requestUser = s.user, terminalId = s.terminalId,
              ideId = s.ideId, checkConflict = "true", isNotifiedOnConflict = "true" },
  }, function(body, status)
    s.listener_job = nil
    if not body or body == "" then fail("listen", "respuesta vacía (HTTP " .. tostring(status) .. ")"); return end
    if body:find("conflictText", 1, true) then
      fail("listen", "conflicto: ya hay un debugger ADT/Eclipse escuchando con este usuario."); return
    end
    local debuggee = body:match("<DEBUGGEE_ID>([^<]+)</DEBUGGEE_ID>") or body:match('debuggeeId="([^"]+)"')
    if not debuggee then fail("listen", "sin DEBUGGEE_ID."); return end
    log("listen", "debuggee capturado: " .. debuggee:sub(1, 20) .. "…")

    -- Atachar para saber si es post-mortem; si lo es, terminarlo y volver a escuchar.
    M.attach(debuggee, function(ok, info)
      if not ok then return end
      if info.isPostMortem then
        log("listen", "⚠️ era un DUMP (post-mortem). Lo ignoro (terminateDebuggee) y vuelvo a escuchar. Limpia ST22.")
        M.step("terminateDebuggee", function() M.listen(cb) end)
        return
      end
      if cb then cb(debuggee, info) end
    end)
  end)
end

-- ── 5) get_stack ──────────────────────────────────────────────────────────────
-- cb(frames) — frame = { program, include, line, position, stackUri, stackType,
--                        eventName, systemProgram, uri }.
function M.get_stack(cb)
  curl({
    method = "GET", path = "/sap/bc/adt/debugger/stack",
    query = { method = "getStack", emode = "_", semanticURIs = "true" },
    accept = "application/xml",
  }, function(body, status)
    if parse_exception(body) or not (body or ""):find("stackEntry", 1, true) then
      fail("stack", "sin stack (HTTP " .. tostring(status) .. ")"); if cb then cb({}) end; return
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
    if cb then cb(frames) end
  end)
end

-- Selecciona un frame del stack (para inspeccionar sus variables). stackUri viene de
-- get_stack (campo stackUri). PUT, sin body. cb(ok).
function M.goto_stack(stackUri, cb)
  if not stackUri then if cb then cb(false) end; return end
  curl({ method = "PUT", path = stackUri }, function(_, status)
    if cb then cb(tostring(status):match("^2") ~= nil) end
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
    .. table.concat(h) .. '</HIERARCHIES></DATA></asx:values></asx:abap>'

  curl({
    method = "POST", path = "/sap/bc/adt/debugger", query = { method = "getChildVariables" },
    accept = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.debugger.ChildVariables",
    content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.debugger.ChildVariables",
    body = body,
  }, function(resp, status)
    if parse_exception(resp) then fail("vars", "error (HTTP " .. tostring(status) .. ")"); if cb then cb({}, {}) end; return end
    resp = resp or ""
    local vars = {}
    local truncated = false
    for v in resp:gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
      if #vars >= M.MAX_CHILDREN then truncated = true; break end -- Pilar 3: tope anti-crash
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
      vars[#vars + 1] = { id = "", name = "…",
        value = "(>" .. M.MAX_CHILDREN .. " filas; paginación de tablas pendiente)",
        type = "", meta = "info", table_lines = 0, expandable = false }
    end
    local scopes = {}
    for hy in resp:gmatch("<STPDA_ADT_VARIABLE_HIERARCHY>(.-)</STPDA_ADT_VARIABLE_HIERARCHY>") do
      local cid = hy:match("<CHILD_ID>([^<]*)</CHILD_ID>")
      local cname = hy:match("<CHILD_NAME>([^<]*)</CHILD_NAME>")
      if cid then scopes[#scopes + 1] = { id = cid, name = (cname ~= "" and cname) or cid } end
    end
    log("vars", #vars .. " var(s), " .. #scopes .. " scope(s) bajo '" .. tostring(parents[1]) .. "'.")
    if cb then cb(vars, scopes) end
  end)
end

-- ── 7) step ───────────────────────────────────────────────────────────────────
-- action: stepInto | stepOver | stepReturn | stepContinue | stepRunToLine |
--         stepJumpToLine | terminateDebuggee.
-- cb(result) — result = { ended=bool, error=string|nil }. ended=true cuando el debuggee
--   terminó (HTTP 500 + subType=debuggeeEnded) → NO es un crash, es fin normal.
function M.step(action, cb)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger", query = { method = action },
    accept = "application/xml",
  }, function(body, status)
    local msg, subtype = parse_exception(body)
    if subtype == "debuggeeEnded" or (body and body:find("debuggeeEnded", 1, true)) then
      log("step", action .. " → debuggee TERMINADO (fin normal de ejecución).")
      if cb then cb({ ended = true }) end
      return
    end
    if msg then
      fail("step", action .. " error (HTTP " .. tostring(status) .. "): " .. msg)
      if cb then cb({ ended = false, error = msg }) end
      return
    end
    log("step", action .. " OK (HTTP " .. tostring(status) .. ").")
    if cb then cb({ ended = false }) end
  end)
end

-- Cambia el valor de una variable escalar en runtime (Pilar 2). variableName = el ID ADT
-- de la variable (p.ej. "SY-SUBRC" o "@GLOBALS\LV_X"). cb(ok, msg).
function M.set_variable(variableName, value, cb)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger",
    query = { method = "setVariableValue", variableName = variableName },
    body = value, content_type = "text/plain", accept = "application/xml",
  }, function(body, status)
    local msg = parse_exception(body)
    if msg or not tostring(status):match("^2") then
      fail("setvar", variableName .. " = '" .. value .. "' (HTTP " .. tostring(status) .. "): " .. (msg or "rechazado"))
      if cb then cb(false, msg) end
      return
    end
    log("setvar", variableName .. " = '" .. value .. "' OK.")
    if cb then cb(true) end
  end)
end

-- Mueve el puntero de ejecución a una línea SIN ejecutar (Pilar 5, jump-to-line).
-- uri = source uri con #start=line. cb(result) — { ended, error }.
function M.jump(uri, cb)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger",
    query = { method = "stepJumpToLine", uri = uri }, accept = "application/xml",
  }, function(body, status)
    local msg = parse_exception(body)
    if msg then
      fail("jump", "(HTTP " .. tostring(status) .. "): " .. msg)
      if cb then cb({ error = msg }) end
      return
    end
    log("jump", "saltado a " .. uri)
    if cb then cb({ ended = false }) end
  end)
end

-- ── stop / cleanup ─────────────────────────────────────────────────────────────

function M.stop(cb)
  local s = M.session
  if not s then if cb then cb() end; return end
  if s.listener_job then pcall(vim.fn.jobstop, s.listener_job); s.listener_job = nil end
  curl({
    method = "DELETE", path = "/sap/bc/adt/debugger/listeners",
    query = { debuggingMode = "user", requestUser = s.user, terminalId = s.terminalId,
              ideId = s.ideId, checkConflict = "false", notifyConflict = "true" },
  }, function(_, status)
    log("stop", "listener eliminado (HTTP " .. tostring(status) .. "). Sesión cerrada.")
    pcall(os.remove, s.jar)
    M.session = nil
    if cb then cb() end
  end)
end

-- Cierra TODAS las sesiones/listeners de debug del usuario (panic clean). Borra el listener
-- bajo el terminalId/ideId ESTABLE en sus dos variantes (ideId puesto y vacío). Útil cuando
-- quedan listeners huérfanos que dan "conflicto" al volver a depurar.
function M.terminate_all(cb)
  local function purge(s)
    if s.listener_job then pcall(vim.fn.jobstop, s.listener_job); s.listener_job = nil end
    local variants = { s.ideId, "" }
    local left = #variants
    for _, idev in ipairs(variants) do
      curl({
        method = "DELETE", path = "/sap/bc/adt/debugger/listeners",
        query = { debuggingMode = "user", requestUser = s.user, terminalId = s.terminalId,
                  ideId = idev, checkConflict = "false", notifyConflict = "true" },
      }, function(_, status)
        log("killall", "listener borrado (ideId=" .. (idev == "" and "∅" or "set") .. ") HTTP " .. tostring(status))
        left = left - 1
        if left <= 0 then
          pcall(os.remove, s.jar)
          M.session = nil
          log("killall", "Sesiones de debug del usuario " .. s.user .. " cerradas.")
          if cb then cb() end
        end
      end)
    end
  end
  if M.session then purge(M.session)
  else M.init_session(function(ok) if ok then purge(M.session) elseif cb then cb() end end) end
end

-- El control del debugger es 100% vía nvim-dap (integrations/dap.lua): <leader>db breakpoint,
-- <leader>dc arrancar, <leader>di/do/dO step, <leader>dt terminar. Aquí solo exponemos la
-- limpieza de sesiones huérfanas (no compite con dap por la sesión).
function M.setup()
  vim.api.nvim_create_user_command("SapDebugKillAll", function() M.terminate_all() end,
    { desc = "sap-nvim: Cerrar TODAS las sesiones/listeners de debug del usuario" })
  vim.keymap.set("n", "<leader>dX", function() M.terminate_all() end,
    { desc = "Debug: cerrar todas las sesiones del usuario" })
end

return M
