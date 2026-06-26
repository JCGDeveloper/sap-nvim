-- sap-nvim.core.source
-- Edición de objetos ABAP remotos al estilo de la extensión `abap-remote-fs` de
-- VSCode/Eclipse, usando ADT directo para la edición de código:
--
--   abrir   -> GET  <obj>/source/main
--   push    -> POST <obj>?_action=LOCK, PUT <obj>/source/main, POST <obj>?_action=UNLOCK
--   activar -> ADT activation bulk/preaudit
--
-- El objeto se respalda en un archivo de caché real (~/.cache/sap-nvim/<contexto>/)
-- con nombre abapGit, para que treesitter/abaplint/LSP funcionen. `:w` solo guarda
-- en la caché; subir a SAP es la acción explícita `:SapPush`.

local M = {}
local adt = require("sap-nvim.core.adt")
local objtype = require("sap-nvim.core.objtype")

-- Transporte recordado por sesión (CORRNR o el sentinel LOCAL).
local LOCAL = "__LOCAL__"
local session_transport = nil

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function url_part(s)
  return tostring(s or ""):lower():gsub("([^%w_%-%.~])", function(c)
    return string.format("%%%02X", string.byte(c))
  end)
end

local ADT_OBJECT_PATH = {
  program = "/sap/bc/adt/programs/programs/%s",
  include = "/sap/bc/adt/programs/includes/%s",
  class = "/sap/bc/adt/oo/classes/%s",
  interface = "/sap/bc/adt/oo/interfaces/%s",
  functiongroup = "/sap/bc/adt/functions/groups/%s",
  table = "/sap/bc/adt/ddic/tables/%s",
  structure = "/sap/bc/adt/ddic/structures/%s",
  dataelement = "/sap/bc/adt/ddic/dataelements/%s",
  domain = "/sap/bc/adt/ddic/domains/%s",
  tabletype = "/sap/bc/adt/ddic/tabletypes/%s",
  ddl = "/sap/bc/adt/ddic/ddl/sources/%s",
  ddls = "/sap/bc/adt/ddic/ddl/sources/%s",
  ddlx = "/sap/bc/adt/ddic/ddlx/sources/%s",
  dcl = "/sap/bc/adt/acm/dcl/sources/%s",
  bdef = "/sap/bc/adt/bo/behaviordefinitions/%s",
  srvd = "/sap/bc/adt/ddic/srvd/sources/%s",
}

local function object_uri(obj_or_group, name, opts)
  opts = opts or {}
  if type(obj_or_group) == "table" then
    local obj = obj_or_group
    if obj.uri and obj.uri ~= "" then
      return obj.uri:gsub("/source/main$", "")
    end
    return object_uri(obj.group, obj.name, obj)
  end

  local group = obj_or_group
  if group == "functionmodule" then
    if not opts.fgroup or opts.fgroup == "" then
      return nil
    end
    return "/sap/bc/adt/functions/groups/"
      .. url_part(opts.fgroup)
      .. "/fmodules/"
      .. url_part(name)
  end

  local tmpl = ADT_OBJECT_PATH[group]
  if not tmpl or not name or name == "" then
    return nil
  end
  return tmpl:format(url_part(name))
end

local function source_uri(obj_or_group, name, opts)
  local uri = object_uri(obj_or_group, name, opts)
  return uri and (uri .. "/source/main") or nil
end

local function strip_cr(s)
  return (s or ""):gsub("\r", "")
end

local function adt_msg(body, code)
  local msg = body
    and (
      body:match("<shortText>%s*<txt[^>]*>(.-)</txt>%s*</shortText>")
      or body:match("<longText>%s*<txt[^>]*>(.-)</txt>%s*</longText>")
      or body:match('message="([^"]*)"')
      or body:match("<message[^>]*>(.-)</message>")
      or body:match("<title[^>]*>(.-)</title>")
    )
  msg = tostring(msg or ""):gsub("<[^>]+>", " ")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&amp;", "&")
    :gsub("%s+", " ")
  msg = vim.trim(msg)
  if msg ~= "" then return msg end
  return "HTTP " .. tostring(code or 0)
end

local function lock_handle(body)
  return body and (
    body:match("<LOCK_HANDLE>([^<]*)</LOCK_HANDLE>")
    or body:match("<[^>]*LOCK_HANDLE[^>]*>([^<]*)</[^>]+>")
  ) or nil
end

local function read_source_adt(group, name, opts)
  local adt_http = require("sap-nvim.core.adt_http")
  local uri = source_uri(group, name, opts)
  if not uri then
    return nil, "Tipo ADT no soportado para lectura: " .. tostring(group)
  end
  local body, _, code = adt_http.raw({ method = "GET", path = uri, accept = "text/plain" })
  if code < 200 or code >= 300 or not body then
    return nil, adt_msg(body, code), code
  end
  return strip_cr(body), nil, code, uri:gsub("/source/main$", "")
end

local function unlock_object(adt_http, uri, handle)
  if not uri or not handle or handle == "" then
    return
  end
  pcall(adt_http.raw, {
    method = "POST",
    path = uri,
    query = { _action = "UNLOCK", lockHandle = handle },
    stateful = true,
  })
end

local function write_source_adt(obj, content, corrnr)
  local adt_http = require("sap-nvim.core.adt_http")
  local uri = object_uri(obj)
  if not uri then
    return false, "Tipo ADT no soportado para escritura: " .. tostring(obj.group)
  end

  local lock_body, _, lock_code = adt_http.raw({
    method = "POST",
    path = uri,
    query = { _action = "LOCK", accessMode = "MODIFY" },
    stateful = true,
    accept = table.concat({
      "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result;q=0.8",
      "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result2;q=0.9",
    }, ", "),
  })
  local handle = lock_handle(lock_body)
  if lock_code < 200 or lock_code >= 300 or not handle or handle == "" then
    return false, "No se pudo bloquear " .. obj.name .. ": " .. adt_msg(lock_body, lock_code)
  end

  local query = { lockHandle = handle }
  if corrnr then
    query.corrNr = corrnr
  end
  local put_body, _, put_code = adt_http.raw({
    method = "PUT",
    path = uri .. "/source/main",
    query = query,
    body = content:gsub("\n$", ""),
    content_type = "text/plain; charset=utf-8",
    accept = "text/plain, application/xml, application/*",
    stateful = true,
  })
  unlock_object(adt_http, uri, handle)

  if put_code < 200 or put_code >= 300 then
    return false, "No se pudo guardar " .. obj.name .. ": " .. adt_msg(put_body, put_code), put_code
  end
  return true, put_body, put_code
end

local function confirm_destructive(label, prompt, cb)
  local cfg = require("sap-nvim.core.config").productive()
  if not cfg.confirm_destructive then
    return vim.ui.select({ "No", "Sí" }, { prompt = prompt }, function(choice)
      cb(choice and choice:match("^Sí") ~= nil)
    end)
  end
  vim.ui.input({ prompt = prompt .. " Escribe '" .. label .. "' para confirmar: " }, function(input)
    cb(input and vim.trim(input):upper() == label:upper())
  end)
end

-- abaplint.json RELAJADO para la caché. Los objetos remotos se editan EN AISLADO (sin las
-- clases estándar de SAP ni el resto del proyecto), así que la regla `check_syntax` de
-- abaplint da FALSOS POSITIVOS ("Super class X not found", "redefinition", tipos
-- desconocidos). SAP ya hace el check real al activar; aquí solo queremos estilo. Por eso
-- desactivamos check_syntax y dejamos reglas que funcionan en aislado.
local CACHE_ABAPLINT = [[{
  "global": { "files": "/**/*.*" },
  "syntax": { "version": "v750", "errorNamespace": "." },
  "rules": {
    "check_syntax": false,
    "parser_error": true,
    "sequential_blank": { "lines": 4 },
    "contains_tab": true,
    "whitespace_end": true,
    "line_length": { "length": 255 }
  }
}
]]

-- ~/.cache/nvim/sap-nvim/<current-context>/ — se crea si no existe, con un abaplint.json
-- relajado (ver arriba) para que el linter (sap-nvim o el LSP del usuario, si respeta el
-- abaplint.json más cercano) no marque falsos "redefinition"/"class not found".
function M.cache_dir()
  local ctx = adt.get_current_context()
  local name = (ctx and ctx.name) or "default"
  local dir = vim.fn.stdpath("cache") .. "/sap-nvim/" .. name
  vim.fn.mkdir(dir, "p")
  local cfg = dir .. "/abaplint.json"
  if vim.fn.filereadable(cfg) == 0 then  -- no sobreescribir si el usuario lo personaliza
    pcall(vim.fn.writefile, vim.split(CACHE_ABAPLINT, "\n"), cfg)
  end
  return dir
end

-- Abre un objeto remoto: lo lee de SAP, lo cachea y lo muestra en un buffer.
-- opts.line / opts.col (opcional): salta a esa posición tras abrir (para go-to-definition).
local RAP_KINDS = { ddl = true, ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }

function M.open(name, group, opts)
  opts = opts or {}
  if not group then
    notify("Tipo de objeto desconocido para '" .. name .. "'", vim.log.levels.WARN)
    return
  end
  -- Objetos CDS/RAP: mantienen su abridor especializado, pero el guardado ya va por ADT
  -- porque core.cds deja vim.b.sap_obj.uri poblada.
  if RAP_KINDS[group] then
    return require("sap-nvim.core.cds").open_adt(group, name, opts)
  end
  if not adt.is_configured() then
    notify("No hay conexion SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end
  -- GUARDIÁN ANTI-BLOQUEO: sapcli lee la contraseña de SAP_PASSWORD (entorno) o config.yml.
  -- Si la conexión no está VALIDADA (recién arrancado, freno activo, password sin probar),
  -- NO lanzamos sapcli — enviaría un login (vacío o sin validar) que puede bloquear el usuario.
  -- Pedimos login (valida con 1 petición) y, si va bien, reintentamos la apertura.
  if not require("sap-nvim.core.adt_http").ready() then
    require("sap-nvim.core.connection").ensure(function(ok)
      if ok then M.open(name, group, opts) end
    end)
    return
  end

  -- Los módulos de función necesitan su grupo para construir la URI ADT:
  -- /functions/groups/<grupo>/fmodules/<modulo>/source/main.
  -- Si no nos lo pasaron, lo pedimos y reintentamos open con opts.fgroup puesto.
  local fgroup = opts.fgroup
  if group == "functionmodule" and (not fgroup or fgroup == "") then
    vim.ui.input({ prompt = "Grupo de funciones: " }, function(input)
      if not input or input == "" then return end
      opts.fgroup = vim.trim(input)
      M.open(name, group, opts)
    end)
    return
  end

  local function open_from_lines(lines, uri)
    local path = M.cache_dir() .. "/" .. objtype.gitfile(group, name)
    vim.fn.writefile(lines, path)
    pcall(function() require("sap-nvim.core.navigate").push_here() end)
    vim.cmd("noswapfile edit! " .. vim.fn.fnameescape(path))
    local bufnr = vim.api.nvim_get_current_buf()
    vim.bo[bufnr].swapfile = false
    vim.b[bufnr].sap_obj = { name = name:upper(), group = group, fgroup = fgroup, uri = uri }
    vim.bo[bufnr].filetype = "abap"
    pcall(function() require("sap-nvim.core.template_vars").prime(bufnr) end)
    if opts.line then
      pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, opts.col or 0 })
      vim.cmd("normal! zz")
    end
    notify(name:upper() .. " abierto (" .. group .. ") por ADT. :SapPush para guardar, :SapActivate para guardar+activar.")
    if group == "program" then
      M.prefetch_includes(lines)
    end
  end

  notify("Leyendo " .. name .. " (" .. group .. ") desde SAP por ADT...")
  local body, read_err, _, uri = read_source_adt(group, name, { fgroup = fgroup })
  if body then
    return open_from_lines(vim.split(body, "\n", { plain = true }), uri)
  end

  notify("ADT no pudo leer " .. name .. " (" .. read_err .. "). Probando fallback sapcli...", vim.log.levels.WARN)
  local read_args = (group == "functionmodule")
      and { "sapcli", "functionmodule", "read", fgroup, name }
      or { "sapcli", group, "read", name }

    local out, err = {}, {}
    vim.fn.jobstart(read_args, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do table.insert(out, l) end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(err, vim.trim(l)) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local msg = #err > 0 and err[1] or ("read fallido (code " .. code .. ")")
          notify("No se pudo leer " .. name .. ": " .. msg, vim.log.levels.ERROR)
          return
        end
        -- jobstart entrega un último elemento "" por el EOF: lo descartamos.
        if out[#out] == "" then table.remove(out) end
        open_from_lines(out, object_uri(group, name, { fgroup = fgroup }))
      end)
    end,
  })
end

-- Descarga a la caché (silenciosamente) los includes referenciados que aún no estén,
-- para alimentar el go-to-definition cross-include.
function M.prefetch_includes(lines)
  local dir = M.cache_dir()
  for _, raw in ipairs(lines or {}) do
    local inc = raw:lower():match("^%s*include%s+([%w_/]+)")
    if inc then
      local p = dir .. "/" .. objtype.gitfile("include", inc)
      if vim.fn.filereadable(p) == 0 then
        local body = read_source_adt("include", inc)
        if body and body ~= "" then
          pcall(vim.fn.writefile, vim.split(body, "\n", { plain = true }), p)
        end
      end
    end
  end
end

-- Obtiene las órdenes para el picker: primero las ASIGNABLES al objeto actual (ADT
-- transportchecks → incluye compartidas/accesibles, no solo las propias); si no hay objeto
-- o falla, cae al listado por owner (sapcli). done(list).
local function fetch_transports(done)
  local bufnr = vim.api.nvim_get_current_buf()
  local meta = vim.b[bufnr].sap_obj
  local source_uri
  local ok, intel = pcall(require, "sap-nvim.core.intel")
  if ok and intel.object_uri then source_uri = intel.object_uri(bufnr) end
  local devclass = (meta and meta.package) or ""
  if source_uri and source_uri ~= "" then
    adt.fetch_object_transports(source_uri, devclass, function(list, _)
      if list and #list > 0 then
        done(list)
      else
        adt.fetch_transport_orders(function(t) done(t or {}) end)
      end
    end)
  else
    adt.fetch_transport_orders(function(t) done(t or {}) end)
  end
end

-- Resuelve el transporte a usar para el push y llama cb(corrnr_or_nil).
-- corrnr = nil  -> objeto local ($TMP), sin orden. Público para reusar (message.lua, etc.).
function M.resolve_transport(cb)
  if session_transport == LOCAL then return cb(nil) end
  if session_transport then return cb(session_transport) end

  local SENT_LOCAL = "(objeto local $TMP — sin orden)"
  local SENT_MINE = "🔎 Buscar entre TODAS mis órdenes…"
  local SENT_MANUAL = "✏️ Ingresar número de orden…"

  local function choose(corrnr)
    session_transport = corrnr -- la 1ª palabra de la fila CTS es el ID (p.ej. SIDK900123)
    cb(corrnr)
  end

  -- Picker reutilizable (se usa para las asignables y para "mis órdenes").
  local function pick(items, prompt)
    vim.ui.select(items, { prompt = prompt }, function(choice)
      if not choice then return end -- cancelado
      if choice == SENT_LOCAL then
        session_transport = LOCAL
        return cb(nil)
      elseif choice == SENT_MANUAL then
        vim.ui.input({ prompt = "Número de orden: " }, function(v)
          if v and v ~= "" then choose(v:upper()) end
        end)
      elseif choice == SENT_MINE then
        -- Lista por owner (sapcli) = TODAS mis órdenes, las use o no este objeto.
        adt.fetch_transport_orders(function(mine)
          vim.schedule(function()
            local list = {}
            for _, t in ipairs(mine or {}) do list[#list + 1] = t end
            list[#list + 1] = SENT_MANUAL
            pick(list, "Mis órdenes de transporte:")
          end)
        end)
      else
        choose(choice:match("^%s*(%S+)"))
      end
    end)
  end

  fetch_transports(function(transports)
    vim.schedule(function()
      local items = { SENT_LOCAL }
      for _, t in ipairs(transports or {}) do table.insert(items, t) end
      table.insert(items, SENT_MINE)
      table.insert(items, SENT_MANUAL)
      pick(items, "Orden de transporte (asignables al objeto):")
    end)
  end)
end

-- Olvida el transporte recordado para que el próximo push vuelva a preguntar.
function M.reset_transport()
  session_transport = nil
  notify("Transporte de sesion reiniciado; el proximo push preguntara de nuevo.")
end

-- Guarda el buffer actual en SAP por ADT. `activate` => guarda y activa por ADT.
function M.push(bufnr, activate, callback)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local obj = vim.b[bufnr].sap_obj
  if not obj then
    notify("Este buffer no es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN)
    return
  end
  -- Guardián anti-bloqueo (ver M.open): no escribir vía sapcli sin conexión validada.
  if not require("sap-nvim.core.adt_http").ready() then
    require("sap-nvim.core.connection").ensure(function(ok)
      if ok then M.push(bufnr, activate, callback) end
    end)
    return
  end

  pcall(vim.cmd, "write") -- vuelca la caché a disco
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  M.resolve_transport(function(corrnr)
    local verb = activate and "Guardando+activando " or "Guardando "
    notify(verb .. obj.name .. (corrnr and (" [" .. corrnr .. "]") or " [$TMP]") .. "...")

    local ok, res = write_source_adt(obj, table.concat(lines, "\n"), corrnr)
    if not ok then
      vim.fn.setqflist({}, "r", {
        items = { { filename = vim.api.nvim_buf_get_name(bufnr), lnum = 1, col = 1, text = res, type = "E" } },
        title = "SAP " .. obj.name .. ": error al guardar",
      })
      pcall(vim.cmd, "copen")
      notify(res, vim.log.levels.ERROR)
      if callback then callback(false, { res }, {}) end
      return
    end

    if not activate then
      vim.fn.setqflist({}, "r", { title = "SAP " .. obj.name .. ": OK" })
      notify(obj.name .. " guardado correctamente por ADT.")
      if callback then callback(true, {}, {}) end
      return
    end

    local uri = object_uri(obj)
    require("sap-nvim.core.adt").activate_bulk({
      {
        name = obj.name,
        group = obj.group,
        uri = uri,
        type = require("sap-nvim.core.adt").adt_type(obj.group),
      },
    }, function(resp, qf)
      local errors = vim.tbl_filter(function(e) return e.type == "E" end, qf or {})
      if resp and #errors == 0 then
        notify(obj.name .. " guardado y activado correctamente por ADT.")
        if callback then callback(true, {}, qf or {}) end
    else
        if callback then callback(false, {}, qf or {}) end
      end
    end)
  end)
end

-- Borra un objeto del sistema: `sapcli <group> delete NAME [--corrnr]`. Pide confirmación
-- y resuelve transporte (igual que el push). Tras borrar, limpia el buffer y la caché.
function M.delete(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local obj = vim.b[bufnr].sap_obj
  if not obj then
    notify("Este buffer no es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN)
    return
  end

  confirm_destructive(obj.name, "¿Borrar " .. obj.name .. " (" .. obj.group .. ") de SAP? Esto es irreversible.", function(ok)
      if not ok then return end

      M.resolve_transport(function(corrnr)
        local args = { "sapcli", obj.group, "delete", obj.name }
        if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end

        notify("Borrando " .. obj.name .. "...")
        local err = {}
        vim.fn.jobstart(args, {
          on_stderr = function(_, data)
            for _, l in ipairs(data) do if vim.trim(l) ~= "" then err[#err + 1] = l end end
          end,
          on_exit = function(_, code)
            vim.schedule(function()
              if code ~= 0 then
                notify("No se pudo borrar " .. obj.name .. ": " .. (err[1] or ("code " .. code)),
                  vim.log.levels.ERROR)
                return
              end
              local path = vim.api.nvim_buf_get_name(bufnr)
              pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
              if path ~= "" then pcall(os.remove, path) end
              notify(obj.name .. " borrado del sistema.")
            end)
          end,
        })
      end)
    end)
end

-- Activar. Para objetos remotos abiertos con sap-nvim, activar implica subir antes
-- (write + activate atómico, como hace la extensión de VSCode al guardar). Para
-- archivos sueltos en disco, cae al activate clásico que deduce group/name del nombre.
function M.activate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].sap_obj then
    M.push(bufnr, true)
  else
    adt.activate_current()
  end
end

function M.activate_recursive()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].sap_obj then
    M.push(bufnr, false, function(ok)
      if ok then
        require("sap-nvim.core.adt").activate_related_current(bufnr)
      end
    end)
  else
    require("sap-nvim.core.adt").activate_related_current(bufnr)
  end
end

function M.setup()
  vim.api.nvim_create_user_command("SapPush", function()
    M.push(nil, false)
  end, { desc = "sap-nvim: Guardar el objeto actual en SAP por ADT" })

  vim.api.nvim_create_user_command("SapPushActivate", function()
    M.push(nil, true)
  end, { desc = "sap-nvim: Subir y activar el objeto actual" })

  vim.api.nvim_create_user_command("SapActivate", function()
    M.activate()
  end, { desc = "sap-nvim: Activar el objeto actual (sube antes si es objeto remoto)" })

  vim.api.nvim_create_user_command("SapActivateRecursive", function()
    M.activate_recursive()
  end, { desc = "sap-nvim: Subir y activar raíz + includes relacionados" })

  vim.api.nvim_create_user_command("SapTransportReset", function()
    M.reset_transport()
  end, { desc = "sap-nvim: Olvidar la orden de transporte recordada" })

  vim.api.nvim_create_user_command("SapDelete", function()
    M.delete(nil)
  end, { desc = "sap-nvim: Borrar el objeto actual del sistema (con confirmación)" })

  vim.api.nvim_create_user_command("SapOpenFunction", function()
    -- Un módulo de función necesita GRUPO + NOMBRE: pedimos ambos y abrimos.
    vim.ui.input({ prompt = "Grupo de funciones: " }, function(grupo)
      if not grupo or grupo == "" then return end
      vim.ui.input({ prompt = "Módulo de función: " }, function(nombre)
        if not nombre or nombre == "" then return end
        M.open(vim.trim(nombre), "functionmodule", { fgroup = vim.trim(grupo) })
      end)
    end)
  end, { desc = "sap-nvim: Abrir un módulo de función (pide grupo y nombre)" })

  vim.keymap.set("n", "<leader>au", function() M.push(nil, false) end,
    { desc = "ABAP: Subir (push) objeto a SAP sin activar" })
  vim.keymap.set("n", "<leader>aA", function() M.activate_recursive() end,
    { desc = "ABAP: Activar raíz + includes relacionados" })
  vim.keymap.set("n", "<leader>aX", function() M.delete(nil) end,
    { desc = "ABAP: Borrar objeto del sistema" })
end

return M
