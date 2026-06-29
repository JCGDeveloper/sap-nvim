-- sap-nvim.core.test_debugger_spike
-- SPIKE (NO producción): valida EN VIVO el handshake del debugger ADT y el long-poll.
-- Ejecutar:  :lua require('sap-nvim.core.test_debugger_spike').run()
--            :lua require('sap-nvim.core.test_debugger_spike').run({ program='ZCAR_PRACFINAL_JCG', line=10 })
--            :lua require('sap-nvim.core.test_debugger_spike').cancel()   -- aborta el listener
--
-- Endpoints/payloads de abap-adt-api/src/api/debugger.ts. Sesión stateful por cookie jar
-- compartido + cabecera X-sap-adt-sessiontype: stateful (VALIDADO: se mantiene con curl
-- por llamada). NO usa adt_http.request_async (su fallback de 12s mataría el long-poll);
-- usa curl directo por jobstart SIN --max-time.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local config = require("sap-nvim.core.config")

local S = { jar = nil, csrf = nil, terminalId = nil, ideId = nil, user = nil, listener_job = nil }

-- ── util / logging muy verboso ───────────────────────────────────────────────

local function log(step, msg)
  local line = string.format("[spike] %s: %s", step, msg)
  print(line); vim.notify(line, vim.log.levels.INFO)
end
local function err(step, msg)
  local line = string.format("[spike] %s FALLO: %s", step, msg)
  print(line); vim.notify(line, vim.log.levels.ERROR)
end
local function raw_dump(title, body)
  print("[spike] ─────── RAW " .. title .. " ───────")
  print(body or "(vacío)")
  print("[spike] ─────── fin RAW " .. title .. " ───────")
end

math.randomseed(os.time())
local function uuid()
  return (("xxxxxxxx-xxxx-4xxx-yxxx-xxxxxxxxxxxx"):gsub("[xy]", function(c)
    local v = (c == "x") and math.random(0, 15) or math.random(8, 11)
    return string.format("%x", v)
  end)):upper()
end

local function curl_base_args(opts)
  opts = opts or {}
  local sec = config.security()
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
  if not opts.no_timeout then
    local request_timeout = tonumber(sec.request_timeout) or 45
    if request_timeout > 0 then
      vim.list_extend(args, { "--max-time", tostring(request_timeout) })
    end
  end
  return args
end

local function curl_cfg(c)
  return table.concat({
    "user = " .. string.format("%q", c.user .. ":" .. c.pass),
    "silent",
    "show-error",
  }, "\n") .. "\n"
end

-- curl directo por jobstart. cb(body, http_status, headers). PARCHE 2: http_status = el
-- ÚLTIMO `HTTP/x.x NNN` del header dump (no el exit code de bash); si curl falla, "curl-exit-N".
local function curl(opts, cb)
  local c = adt_http.creds()
  if not c then err("creds", "sin credenciales (config.yml)"); return end

  local url = c.base .. opts.path
  url = url .. (opts.path:find("?") and "&" or "?") .. "sap-client=" .. c.client
  if opts.query then for k, v in pairs(opts.query) do url = url .. "&" .. k .. "=" .. tostring(v) end end

  local hdrfile = vim.fn.tempname()
  local args = curl_base_args(opts)
  vim.list_extend(args, { "-K", "-", "-b", S.jar, "-c", S.jar, "-D", hdrfile })
  vim.list_extend(args, { "-X", opts.method or "GET" })
  if opts.stateful then vim.list_extend(args, { "-H", "X-sap-adt-sessiontype: stateful" }) end
  if opts.csrf_fetch then vim.list_extend(args, { "-H", "X-CSRF-Token: Fetch" })
  elseif S.csrf then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. S.csrf }) end
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
  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, d) for _, l in ipairs(d) do out[#out + 1] = l end end,
    on_exit = function(_, exit_code)
      local headers = ""
      pcall(function() headers = table.concat(vim.fn.readfile(hdrfile), "\n") end)
      if bodyfile then pcall(os.remove, bodyfile) end
      pcall(os.remove, hdrfile)
      local status
      for s in headers:gmatch("HTTP/[%d%.]+%s+(%d+)") do status = s end -- el último
      status = status or ("curl-exit-" .. exit_code)
      vim.schedule(function() cb(table.concat(out, "\n"), status, headers) end)
    end,
  })
  if job and job > 0 then
    pcall(vim.fn.chansend, job, curl_cfg(c))
    pcall(vim.fn.chanclose, job, "stdin")
  end
  return job
end

local function looks_like_error(body)
  return body and (body:find("<exception", 1, true) or body:find("ExceptionResourceNotFound", 1, true))
end
local function snippet(body) return (body or ""):gsub("%s+", " "):sub(1, 400) end
-- nombre de objeto desde la adtcore:uri (.../<obj>/source/main#start=N)
local function obj_from_uri(uri)
  if not uri then return "?" end
  return uri:match("([^/]+)/source/main") or uri:match("([^/#]+)#") or "?"
end

-- ── pasos ────────────────────────────────────────────────────────────────────

local function step5_cleanup()
  curl({
    method = "DELETE", path = "/sap/bc/adt/debugger/listeners",
    query = { debuggingMode = "user", requestUser = S.user, terminalId = S.terminalId,
              ideId = S.ideId, checkConflict = "false", notifyConflict = "true" },
    stateful = true,
  }, function(_, status)
    log("6/6 cleanup", "listener eliminado (HTTP " .. status .. "). Spike terminado.")
  end)
end

local function step5_resume()
  log("5/6 resume", "POST stepContinue (libera el work process)...")
  curl({
    method = "POST", path = "/sap/bc/adt/debugger", query = { method = "stepContinue" },
    accept = "application/xml", stateful = true,
  }, function(rbody, status)
    log("5/6 resume", "stepContinue HTTP " .. status)
    if not tostring(status):match("^2") then raw_dump("stepContinue (ERROR " .. status .. ")", rbody) end
    step5_cleanup()
  end)
end

-- getChildVariables con DRILL: @ROOT devuelve los SCOPES (Globals/Locals); hay que bajar a
-- sus CHILD_ID para ver las variables reales (lv_texto, p_carrid, ...). Vuelca el raw y, si
-- encuentra scopes hijos, recurre un nivel más.
local function fetch_children(parents, label, after)
  local h = {}
  for _, p in ipairs(parents) do
    h[#h + 1] = "<STPDA_ADT_VARIABLE_HIERARCHY><PARENT_ID>" .. p .. "</PARENT_ID></STPDA_ADT_VARIABLE_HIERARCHY>"
  end
  local vbody = '<?xml version="1.0" encoding="UTF-8" ?><asx:abap version="1.0" xmlns:asx="http://www.sap.com/abapxml"><asx:values><DATA><HIERARCHIES>'
    .. table.concat(h) .. '</HIERARCHIES></DATA></asx:values></asx:abap>'
  curl({
    method = "POST", path = "/sap/bc/adt/debugger", query = { method = "getChildVariables" },
    accept = "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.debugger.ChildVariables",
    content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.debugger.ChildVariables",
    body = vbody, stateful = true,
  }, function(rb, status)
    log("4b/6 variables", "getChildVariables(" .. label .. ") HTTP " .. status)
    raw_dump("getChildVariables " .. label, rb)
    rb = rb or ""
    for v in rb:gmatch("<STPDA_ADT_VARIABLE>(.-)</STPDA_ADT_VARIABLE>") do
      local nm = v:match("<NAME>([^<]*)</NAME>")
      local val = v:match("<VALUE>([^<]*)</VALUE>")
      local mt = v:match("<META_TYPE>([^<]*)</META_TYPE>")
      print(string.format("    %-25s = %-30s [%s]", nm or "?", val or "", mt or ""))
    end
    local kids = {}
    for hy in rb:gmatch("<STPDA_ADT_VARIABLE_HIERARCHY>(.-)</STPDA_ADT_VARIABLE_HIERARCHY>") do
      local cid = hy:match("<CHILD_ID>([^<]*)</CHILD_ID>")
      local cname = hy:match("<CHILD_NAME>([^<]*)</CHILD_NAME>")
      if cid then kids[#kids + 1] = cid; print("    └─ scope: " .. cid .. " (" .. (cname or "") .. ")") end
    end
    after(kids)
  end)
end

local function step4b_variables()
  -- nivel 1: @ROOT -> scopes; nivel 2: drill a esos scopes -> variables reales con valor.
  fetch_children({ "@ROOT" }, "@ROOT", function(scopes)
    if #scopes > 0 then
      fetch_children(scopes, table.concat(scopes, ","), function() step5_resume() end)
    else
      step5_resume()
    end
  end)
end

-- PARCHE 3: stack desde el atributo uri (no `program=`).
local function step4_stack()
  log("4/6 stack", "GET getStack...")
  curl({
    method = "GET", path = "/sap/bc/adt/debugger/stack",
    query = { method = "getStack", emode = "_", semanticURIs = "true" },
    accept = "application/xml", stateful = true,
  }, function(body, status)
    if looks_like_error(body) or not (body or ""):find("stackEntry", 1, true) then
      err("4/6 stack", "sin stack (HTTP " .. status .. "). Body: " .. snippet(body))
      step5_resume(); return
    end
    log("4/6 stack", "OK (HTTP " .. status .. "). Frames:")
    for entry in body:gmatch("<stackEntry(.-)/?>") do
      local uri = entry:match('uri="([^"]*)"')
      local line = entry:match('line="([^"]*)"') or (uri and uri:match("start=(%d+)")) or "?"
      print(string.format("    %-32s line %s", obj_from_uri(uri), line))
    end
    raw_dump("getStack", body) -- blueprint exacto de <stackEntry>
    step4b_variables()
  end)
end

-- PARCHE 4: aviso enorme si es post-mortem (dump), no ejecución en vivo.
local function step3_attach(debuggee_id)
  log("3/6 attach", "POST attach debuggeeId=" .. debuggee_id)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger",
    query = { method = "attach", debuggeeId = debuggee_id, debuggingMode = "user",
              requestUser = S.user, dynproDebugging = "true" },
    accept = "application/xml", stateful = true,
  }, function(body, status)
    if looks_like_error(body) then
      err("3/6 attach", "rechazado (HTTP " .. status .. "). Body: " .. snippet(body))
      step5_cleanup(); return
    end
    log("3/6 attach", "OK (HTTP " .. status .. "). " .. snippet(body))
    if (body or ""):match('isPostMortem="true"') then
      err("3/6 attach", "════════════════════════════════════════════════════════")
      err("3/6 attach", "⚠️  ATACHADO A UN DUMP (post-mortem), NO a ejecución en vivo.")
      err("3/6 attach", "    El stack/variables será del dump. Limpia ST22 y reintenta")
      err("3/6 attach", "    con el breakpoint en una línea EJECUTABLE.")
      err("3/6 attach", "════════════════════════════════════════════════════════")
    else
      log("3/6 attach", "✅ Ejecución EN VIVO (isPostMortem=false). Blueprint válido.")
    end
    step4_stack()
  end)
end

local function step2_listen()
  log("2/6 listen", "POST /listeners (LONG-POLL, sin timeout). ───►  AHORA ejecuta " ..
    "el programa en WebGUI (<leader>aR).  cancel() para abortar.")
  S.listener_job = curl({
    method = "POST", path = "/sap/bc/adt/debugger/listeners",
    query = { debuggingMode = "user", requestUser = S.user, terminalId = S.terminalId,
              ideId = S.ideId, checkConflict = "true", isNotifiedOnConflict = "true" },
    stateful = true, no_timeout = true,
  }, function(body, status)
    S.listener_job = nil
    if not body or body == "" then
      err("2/6 listen", "respuesta vacía (HTTP " .. status .. "). ¿Timeout/desconexión?"); return
    end
    if body:find("conflictText", 1, true) then
      err("2/6 listen", "conflicto de sesión (ya hay un listener/debugger). Body: " .. snippet(body)); return
    end
    local debuggee = body:match("<DEBUGGEE_ID>([^<]+)</DEBUGGEE_ID>") or body:match('debuggeeId="([^"]+)"')
    if not debuggee then
      err("2/6 listen", "sin DEBUGGEE_ID. Body: " .. snippet(body)); return
    end
    log("2/6 listen", "¡Debuggee alcanzado! (HTTP " .. status .. ") debuggeeId=" .. debuggee)
    step3_attach(debuggee)
  end)
end

-- PARCHE 1: validación estricta del breakpoint (errorMessage => abortar).
local function step1_breakpoint(program, line)
  local uri = "/sap/bc/adt/programs/programs/" .. program:lower() .. "/source/main#start=" .. line
  local body = table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<dbg:breakpoints scope="external" debuggingMode="user" requestUser="' .. S.user .. '"',
    '  terminalId="' .. S.terminalId .. '" ideId="' .. S.ideId .. '" systemDebugging="false" deactivated="false"',
    '  xmlns:dbg="http://www.sap.com/adt/debugger">',
    '  <syncScope mode="full"></syncScope>',
    '  <breakpoint xmlns:adtcore="http://www.sap.com/adt/core" kind="line" clientId="spike1"',
    '    skipCount="0" adtcore:uri="' .. uri .. '"/>',
    '</dbg:breakpoints>',
  }, "\n")

  log("1/6 breakpoint", "POST /debugger/breakpoints (external) en " .. program .. ":" .. line)
  curl({
    method = "POST", path = "/sap/bc/adt/debugger/breakpoints",
    body = body, content_type = "application/xml", accept = "application/xml", stateful = true,
  }, function(resp, status)
    local bperr = resp and resp:match('errorMessage="([^"]+)"')
    if looks_like_error(resp) or (bperr and bperr ~= "") then
      err("1/6 breakpoint", "RECHAZADO (HTTP " .. status .. "): " .. (bperr or snippet(resp)))
      err("1/6 breakpoint", "→ El breakpoint debe ir en una SENTENCIA EJECUTABLE (no comentario/declaración/blanco). ABORTANDO.")
      return -- PARCHE 1: no seguimos al listener si el bp no se creó
    end
    log("1/6 breakpoint", "OK (HTTP " .. status .. "). " .. snippet(resp))
    step2_listen()
  end)
end

-- ── orquestación ─────────────────────────────────────────────────────────────

function M.cancel()
  if S.listener_job then
    pcall(vim.fn.jobstop, S.listener_job); S.listener_job = nil
    log("cancel", "listener abortado.")
  else
    log("cancel", "no hay listener activo.")
  end
end

function M.run(opts)
  opts = opts or {}
  local program = (opts.program or "ZCAR_PRACFINAL_JCG"):upper()
  local line = opts.line or 10

  if not adt_http.is_available() then err("init", "ADT no disponible (config.yml/curl)."); return end
  local c = adt_http.creds()
  S.jar = vim.fn.stdpath("cache") .. "/sap-nvim/debug_spike_cookies.txt"
  vim.fn.mkdir(vim.fn.fnamemodify(S.jar, ":h"), "p")
  pcall(os.remove, S.jar)
  S.terminalId = uuid(); S.ideId = uuid(); S.user = c.user:upper(); S.csrf = nil

  log("init", "user=" .. S.user .. " programa=" .. program .. ":" .. line .. " (línea EJECUTABLE, ST22 limpio)")

  curl({ method = "GET", path = "/sap/bc/adt/core/discovery", csrf_fetch = true, stateful = true },
    function(_, status, headers)
      S.csrf = headers and headers:match("[Xx]%-[Cc][Ss][Rr][Ff]%-[Tt]oken:%s*(%S+)")
      if not S.csrf then
        err("0 csrf", "no se obtuvo token CSRF (HTTP " .. status .. "). Headers: " .. snippet(headers)); return
      end
      log("0 csrf", "token CSRF obtenido. Sesión stateful iniciada.")
      step1_breakpoint(program, line)
    end)
end

return M
