-- sap-nvim.core.intel
-- "Inteligencia" tipo VSCode sobre el cliente ADT (core/adt_http): code completion que
-- conoce los métodos/atributos de las clases que llamas. Primer pilar del clon de la
-- extensión de VSCode; siguientes (hover/elementinfo, go-to-def del sistema, referencias)
-- usarán el mismo cliente.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local objtype = require("sap-nvim.core.objtype")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- group de sapcli -> plantilla de URI ADT del source. (nombre en minúsculas)
local ADT_URI = {
  class          = "/sap/bc/adt/oo/classes/%s/source/main",
  interface      = "/sap/bc/adt/oo/interfaces/%s/source/main",
  program        = "/sap/bc/adt/programs/programs/%s/source/main",
  include        = "/sap/bc/adt/programs/includes/%s/source/main",
  functiongroup  = "/sap/bc/adt/functions/groups/%s/source/main",
}

-- URI ADT del objeto del buffer (usa vim.b.sap_obj si existe; si no, deduce del nombre).
local function object_uri(bufnr)
  local meta = vim.b[bufnr].sap_obj
  local group = meta and meta.group or objtype.group(vim.api.nvim_buf_get_name(bufnr))
  local name = meta and meta.name or objtype.name(vim.api.nvim_buf_get_name(bufnr))
  local tmpl = group and ADT_URI[group]
  if not tmpl or not name or name == "" then return nil end
  return tmpl:format(name:lower())
end

-- Programa principal (master program) de un INCLUDE. ADT lo necesita como
-- ?context=<uri> para resolver símbolos cross-include (variables del TOP, FORMs de otro
-- include, etc.) — igual que la extensión de VSCode: findDefinition(..., mainProgram) ->
-- uri = `${url}?context=${encodeURIComponent(mainProgram)}#start=...`.
-- Caché por include (nombre en minúsculas) -> uri del programa, o false si no hay/uno solo.
local mainprog_cache = {}

-- Lista los programas principales de un include (GET .../mainprograms). Devuelve {uris...}.
function M.main_programs(incname)
  local body = adt_http.request({
    method = "GET",
    path = "/sap/bc/adt/programs/includes/" .. incname:lower() .. "/mainprograms",
    accept = "application/*",
  })
  local uris = {}
  for u in (body or ""):gmatch('adtcore:uri="([^"]*)"') do uris[#uris + 1] = u end
  return uris
end

-- Sufijo ?context= para el buffer si es un include con programa principal conocido (lo
-- resuelve y cachea la 1ª vez). encodeURIComponent ~= codificar las '/' como %2F.
local function context_suffix(bufnr)
  local meta = vim.b[bufnr].sap_obj
  if not meta or meta.group ~= "include" then return "" end
  local key = meta.name:lower()
  if mainprog_cache[key] == nil then
    local uris = M.main_programs(meta.name)
    mainprog_cache[key] = uris[1] or false  -- el 1º por defecto (changeInclude permite cambiarlo)
  end
  local uri = mainprog_cache[key]
  if not uri then return "" end
  return "?context=" .. (uri:gsub("/", "%%2F"))
end

-- Fija/cambia el programa principal del include actual (replica abapfs.changeInclude):
-- si hay varios, deja elegir; afecta a gd/hover/jerarquía cross-include.
function M.change_include()
  local bufnr = vim.api.nvim_get_current_buf()
  local meta = vim.b[bufnr].sap_obj
  if not meta or meta.group ~= "include" then
    notify("El buffer actual no es un include.", vim.log.levels.WARN); return
  end
  local uris = M.main_programs(meta.name)
  if #uris == 0 then notify("El include no tiene programa principal asignado.", vim.log.levels.WARN); return end
  if #uris == 1 then
    mainprog_cache[meta.name:lower()] = uris[1]
    notify("Programa principal: " .. uris[1]:match("([^/]+)$")); return
  end
  vim.ui.select(uris, { prompt = "Programa principal del include:",
    format_item = function(u) return u:match("([^/]+)$") end }, function(choice)
    if choice then mainprog_cache[meta.name:lower()] = choice
      notify("Programa principal: " .. choice:match("([^/]+)$")) end
  end)
end

-- Llama a ADT code completion en la posición (line 1-based, col 0-based) sobre el
-- contenido actual del buffer. Devuelve lista de propuestas {word, kind}.
function M.proposals(bufnr, line, col)
  if not adt_http.is_available() then return {} end
  local uri = object_uri(bufnr)
  if not uri then return {} end

  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/abapsource/codecompletion/proposal",
    query = {
      uri = uri .. "%23start=" .. line .. "," .. col,
      signalCompleteness = "true",
    },
    body = src,
  })
  -- Si no hay propuestas (token CSRF caducado/primer arranque, 403, etc.), reintentar una
  -- vez tras invalidar el token.
  if not body or not body:find("SCC_COMPLETION") then
    adt_http.reset_token()
    body = adt_http.request({
      method = "POST",
      path = "/sap/bc/adt/abapsource/codecompletion/proposal",
      query = { uri = uri .. "%23start=" .. line .. "," .. col, signalCompleteness = "true" },
      body = src,
    }) or ""
  end

  return M.parse(body)
end

-- Parsea el XML de propuestas de ADT -> lista { {word, kind}, ... }.
-- kind = nº ADT (1 dato/var/param, 2 clase/tipo, 3 método, 52 keyword...).
function M.parse(body)
  local items = {}
  if not body then return items end
  for block in body:gmatch("<SCC_COMPLETION>(.-)</SCC_COMPLETION>") do
    local id = block:match("<IDENTIFIER>([^<]*)</IDENTIFIER>")
    local kind = block:match("<KIND>([^<]*)</KIND>")
    if id and id ~= "" and id ~= "@end" then
      items[#items + 1] = { word = id, kind = kind }
    end
  end
  return items
end

-- Versión ASYNC para el completado automático (blink). cb(items).
function M.proposals_async(bufnr, line, col, cb)
  if not adt_http.is_available() then cb({}); return end
  local uri = object_uri(bufnr)
  if not uri then cb({}); return end
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  local q = { uri = uri .. "%23start=" .. line .. "," .. col, signalCompleteness = "true" }
  adt_http.request_async({
    method = "POST",
    path = "/sap/bc/adt/abapsource/codecompletion/proposal",
    query = q,
    body = src,
  }, function(body)
    if not body or not body:find("SCC_COMPLETION") then
      adt_http.reset_token()
      adt_http.request_async({
        method = "POST",
        path = "/sap/bc/adt/abapsource/codecompletion/proposal",
        query = q, body = src,
      }, function(body2) cb(M.parse(body2)) end)
    else
      cb(M.parse(body))
    end
  end)
end

-- omnifunc (Ctrl-X Ctrl-O): completado ADT en buffers ABAP.
function M.omnifunc(findstart, base)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))

  if findstart == 1 then
    -- inicio de la palabra/identificador actual (para reemplazar al insertar)
    local linetext = vim.api.nvim_get_current_line()
    local s = col
    while s > 0 and linetext:sub(s, s):match("[%w_]") do s = s - 1 end
    return s
  end

  local items = M.proposals(bufnr, row, col)
  local out = {}
  local needle = (base or ""):lower()
  for _, it in ipairs(items) do
    if needle == "" or it.word:lower():sub(1, #needle) == needle then
      out[#out + 1] = { word = it.word, menu = "[SAP]" }
    end
  end
  return out
end

-- :SapComplete — dispara el completado omni manualmente (útil para probar).
function M.complete()
  if not adt_http.is_available() then
    notify("ADT no disponible (revisa curl y la conexión SAP).", vim.log.levels.WARN)
    return
  end
  vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
end

-- Decodifica entidades XML básicas.
local function unxml(s)
  return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"')
    :gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- ── DOCUMENT HIGHLIGHTS: resalta las apariciones del símbolo bajo el cursor ───
local HL_NS = vim.api.nvim_create_namespace("sap_nvim_doc_highlight")

function M.clear_highlight(bufnr)
  vim.api.nvim_buf_clear_namespace(bufnr or vim.api.nvim_get_current_buf(), HL_NS, 0, -1)
end

function M.document_highlight()
  local bufnr = vim.api.nvim_get_current_buf()
  M.clear_highlight(bufnr)
  local word = vim.fn.expand("<cword>")
  if not word or #word < 3 then return end -- evita ruido con tokens cortos
  local needle = word:lower()
  local plain = needle:gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1")
  local pat = "%f[%w_]" .. plain .. "%f[^%w_]" -- palabra completa
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  for i, l in ipairs(lines) do
    local low, s = l:lower(), 1
    while true do
      local a, b = low:find(pat, s)
      if not a then break end
      pcall(vim.api.nvim_buf_set_extmark, bufnr, HL_NS, i - 1, a - 1,
        { end_col = b, hl_group = "LspReferenceText" })
      s = b + 1
    end
  end
end

-- ── HOVER (elementinfo): firma + documentación del símbolo bajo el cursor ─────
function M.hover()
  if not adt_http.is_available() then notify("ADT no disponible.", vim.log.levels.WARN); return end
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = object_uri(bufnr)
  if not uri then notify("No es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN); return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/abapsource/codecompletion/elementinfo",
    query = { uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col },
    body = src,
  })
  if not body or not body:find("elementInfo") then notify("Sin información aquí."); return end

  local name = body:match('adtcore:name="([^"]*)"')
  local typ = body:match('adtcore:type="([^"]*)"')
  local md = { "## " .. (name or "?") .. (typ and ("  `" .. typ .. "`") or "") }
  -- Propiedades SOLO del elemento principal (primer bloque <properties>), no de cada
  -- método/atributo anidado (que serían cientos).
  local first_props = body:match("<abapsource:properties>(.-)</abapsource:properties>")
  if first_props then
    local props = {}
    for k, v in first_props:gmatch('abapsource:key="([^"]*)"[^>]*>([^<]*)</abapsource:entry>') do
      props[#props + 1] = k .. ": " .. v
    end
    if #props > 0 then md[#md + 1] = "_" .. table.concat(props, " · ") .. "_" end
  end
  -- Documentación (1ª, sin tags HTML, sin duplicar).
  local seen = {}
  for doc in body:gmatch("<abapsource:documentation[^>]*>(.-)</abapsource:documentation>") do
    doc = vim.trim(unxml(doc):gsub("<[^>]->", "")) -- quita <p ...> etc.
    if doc ~= "" and not seen[doc] then
      seen[doc] = true
      md[#md + 1] = ""; md[#md + 1] = doc
    end
  end

  -- open_floating_preview con focus_id => 2ª pulsación de K entra en la ventana y se
  -- navega con hjkl (bloqueable, como VSCode).
  vim.lsp.util.open_floating_preview(md, "markdown", {
    focus_id = "sap_hover", border = "rounded", focusable = true, max_width = 90,
  })
end

-- ── GO-TO-DEFINITION / TYPE (navigation/target): abre la definición del símbolo ──
-- URI ADT -> { group, name, line, col }.
local URI_PATTERNS = {
  { "^/sap/bc/adt/oo/classes/([^/]+)", "class" },
  { "^/sap/bc/adt/oo/interfaces/([^/]+)", "interface" },
  { "^/sap/bc/adt/programs/includes/([^/]+)", "include" },
  { "^/sap/bc/adt/programs/programs/([^/]+)", "program" },
  { "^/sap/bc/adt/functions/groups/([^/]+)", "functiongroup" },
}
local function uri_to_object(uri)
  local path, frag = uri:match("^([^#]+)#?(.*)$")
  path = path or uri
  local line, col = (frag or ""):match("start=(%d+),(%d+)")
  for _, p in ipairs(URI_PATTERNS) do
    local name = path:match(p[1])
    if name then
      return { group = p[2], name = name:upper(), line = tonumber(line), col = tonumber(col) }
    end
  end
  return nil
end

-- Devuelve la URI+pos destino de la definición, o nil. `filter` = "definition"|"typeDefinition".
function M.definition_target(bufnr, row, col, filter)
  if not adt_http.is_available() then return nil end
  local uri = object_uri(bufnr)
  if not uri then return nil end
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  -- Rango de la PALABRA bajo el cursor (identificador ABAP: [%w_/]) -> col inicio/fin.
  -- Replica a VSCode/abap-adt-api, que envía `start=<line>,<colIni>;end=<line>,<colFin>`
  -- (el rango de la palabra), no solo la posición del cursor: el go-to es más fiable.
  local cstart, cend = col, col
  local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
  if line and #line > 0 then
    -- col es 0-based; trabajamos sobre índices 1-based de Lua (i = col+1).
    local cur = col + 1
    if cur <= #line and line:sub(cur, cur):match("[%w_/]") then
      local i = cur
      while i > 1 and line:sub(i - 1, i - 1):match("[%w_/]") do i = i - 1 end
      local j = cur
      while j < #line and line:sub(j + 1, j + 1):match("[%w_/]") do j = j + 1 end
      cstart = i - 1            -- offset 0-based del primer carácter
      cend = j - 1 + 1          -- offset 0-based tras el último (fin exclusivo, como VSCode)
    end
  end
  local ctx = context_suffix(bufnr) -- ?context=<programa principal> para includes (cross-include)
  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/navigation/target",
    query = { uri = uri .. ctx .. "%23start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend, filter = filter or "definition" },
    body = src,
  })
  if not body then return nil end
  local target = body:match('adtcore:uri="([^"]*)"')
  return target and uri_to_object(unxml(target)) or nil
end

-- Va a la definición / tipo / implementación del símbolo bajo el cursor, vía ADT.
-- filter: "definition" (default) | "typeDefinition" | "implementation".
-- Compat: true => "typeDefinition", false/nil => "definition".
-- Devuelve true si encontró y abrió algo.
function M.goto_definition(filter)
  if filter == true then filter = "typeDefinition"
  elseif not filter then filter = "definition" end
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local obj = M.definition_target(bufnr, row, col, filter)
  if not obj then return false end
  -- ¿Es el mismo objeto? entonces solo saltar la línea.
  local meta = vim.b[bufnr].sap_obj
  if meta and meta.name:upper() == obj.name and obj.line then
    pcall(vim.api.nvim_win_set_cursor, 0, { obj.line, obj.col or 0 })
    vim.cmd("normal! zz")
  else
    require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
  end
  return true
end

-- ── REFERENCES (usageReferences): usos del símbolo bajo el cursor en un picker ──
local USAGE_REQ = '<?xml version="1.0" encoding="UTF-8"?><usagereferences:usageReferenceRequest '
  .. 'xmlns:usagereferences="http://www.sap.com/adt/ris/usageReferences">'
  .. '<usagereferences:affectedObjects/></usagereferences:usageReferenceRequest>'

function M.references()
  if not adt_http.is_available() then notify("ADT no disponible.", vim.log.levels.WARN); return end
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = object_uri(bufnr)
  if not uri then notify("No es un objeto SAP.", vim.log.levels.WARN); return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  notify("Buscando referencias...")

  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/repository/informationsystem/usageReferences",
    query = { uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col },
    content_type = "application/vnd.sap.adt.repository.usagereferences.request.v1+xml",
    body = USAGE_REQ,
  })
  if not body or not body:find("referencedObject") then notify("Sin referencias."); return end

  local refs = {}
  for obj in body:gmatch("<usageReferences:adtObject(.-)</usageReferences:adtObject>") do
    local name = obj:match('adtcore:name="([^"]*)"')
    local typ = obj:match('adtcore:type="([^"]*)"')
    local desc = obj:match('adtcore:description="([^"]*)"')
    if name then
      refs[#refs + 1] = { name = name, typ = typ or "", desc = desc and unxml(desc) or "" }
    end
  end
  if #refs == 0 then notify("Sin referencias."); return end

  vim.ui.select(refs, {
    prompt = "Referencias (" .. #refs .. "):",
    format_item = function(r) return string.format("%-10s %-30s %s", r.typ, r.name, r.desc) end,
  }, function(choice)
    if not choice then return end
    -- abrir el objeto si es de un tipo que sabemos abrir
    local g = ({ ["CLAS/OC"] = "class", ["INTF/OI"] = "interface", ["PROG/P"] = "program",
      ["PROG/I"] = "include", ["FUGR/F"] = "functiongroup" })[choice.typ]
    if g then require("sap-nvim.core.source").open(choice.name, g)
    else notify("Tipo " .. choice.typ .. " (" .. choice.name .. ") no abrible directamente.") end
  end)
end

-- ── TYPE HIERARCHY: super/subtipos (clases e interfaces) del tipo bajo el cursor ──
-- Replica typeHierarchy de abap-adt-api:
--   POST /sap/bc/adt/abapsource/typehierarchy
--   query: uri=<uri>#start=<line>,<offset> , type = superTypes|subTypes
--   Content-Type text/plain, Accept application/*, body = source del objeto.
-- super=true => supertipos (clases/interfaces de las que hereda/implementa el tipo);
-- super=false/nil => subtipos (los que heredan/implementan este tipo).
function M.type_hierarchy(super)
  if not adt_http.is_available() then notify("ADT no disponible.", vim.log.levels.WARN); return end
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = object_uri(bufnr)
  if not uri then notify("No es un objeto SAP.", vim.log.levels.WARN); return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  notify((super and "Buscando supertipos" or "Buscando subtipos") .. "...")

  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/abapsource/typehierarchy",
    query = {
      uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col,
      type = super and "superTypes" or "subTypes",
    },
    content_type = "text/plain",
    accept = "application/*",
    body = src,
  })
  if not body then notify("Sin jerarquía de tipos aquí."); return end

  -- En un INCLUDE, ADT exige el programa principal (igual que en Eclipse): error
  -- `invalidMainProgram`. Avisamos para que se abra el programa, no el include.
  if body:find("invalidMainProgram") then
    notify("La jerarquía de tipos necesita el programa principal del include. "
      .. "Ábrelo desde el programa (o una clase global), no desde el include.", vim.log.levels.WARN)
    return
  end

  -- La respuesta real es <hierarchy:info>...<entries><entry adtcore:name=.. type=.. uri=..>.
  -- Parseamos SOLO los <entry> (el <package_ref> anidado también trae adtcore:name).
  -- Excluimos el tipo de ORIGEN (la propia clase consultada) para listar solo super/subtipos.
  local origin = body:match('<origin[^>]-typeName="([^"]*)"')
  local refs = {}
  local seen = {}
  for tag in body:gmatch("<entry%s[^>]->") do
    local name = tag:match('adtcore:name="([^"]*)"')
    local typ = tag:match('adtcore:type="([^"]*)"')
    local nav = tag:match('adtcore:uri="([^"]*)"')
    if name and name ~= "" and name ~= origin then
      local key = name .. "|" .. (typ or "")
      if not seen[key] then
        seen[key] = true
        refs[#refs + 1] = { name = name, typ = typ or "", uri = nav and unxml(nav) or nil }
      end
    end
  end
  if #refs == 0 then
    notify(super and "Sin supertipos para este tipo." or "Sin subtipos para este tipo."); return
  end

  vim.ui.select(refs, {
    prompt = (super and "Supertipos" or "Subtipos") .. " (" .. #refs .. "):",
    format_item = function(r) return string.format("%-10s %s", r.typ or "", r.name or "") end,
  }, function(choice)
    if not choice then return end
    -- Si la URI es navegable a un objeto que sabemos abrir, lo abrimos; si no, avisamos.
    local obj = choice.uri and uri_to_object(choice.uri) or nil
    if obj and obj.group then
      require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
    else
      notify((choice.typ ~= "" and (choice.typ .. " ") or "") .. (choice.name or "?")
        .. " no abrible directamente.")
    end
  end)
end

-- ── SYNTAX CHECK REAL de SAP (checkRun): diagnósticos con línea/col exactas ───
local CHECK_NS = vim.api.nvim_create_namespace("sap_nvim_adt_check")

local function b64(s)
  if vim.base64 and vim.base64.encode then return vim.base64.encode(s) end
  return vim.fn.system({ "base64", "-w0" }, s):gsub("%s+$", "")
end

-- URI base del objeto (sin /source/main) a partir de la URI del source.
local function base_uri(source_uri)
  return (source_uri:gsub("/source/main$", ""))
end

local check_timers = {}

-- Lanza el syntax check de SAP sobre el contenido del buffer y publica los diagnósticos
-- (con posiciones exactas). Async, no bloquea.
function M.check_syntax(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not adt_http.is_available() or not vim.api.nvim_buf_is_valid(bufnr) then return end
  local source_uri = object_uri(bufnr)
  if not source_uri then return end
  local obj_uri = base_uri(source_uri)
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local xml = '<?xml version="1.0" encoding="UTF-8"?>'
    .. '<chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" '
    .. 'xmlns:adtcore="http://www.sap.com/adt/core">'
    -- ?context=<programa principal> para includes: sin él, el check marca como errores las
    -- variables/FORMs declarados en el TOP (falsos positivos). Igual que syntaxCheck de VSCode.
    .. '<chkrun:checkObject adtcore:uri="' .. obj_uri .. context_suffix(bufnr) .. '" chkrun:version="inactive">'
    .. '<chkrun:artifacts><chkrun:artifact chkrun:contentType="text/plain; charset=utf-8" '
    .. 'chkrun:uri="' .. source_uri .. '"><chkrun:content>' .. b64(src)
    .. '</chkrun:content></chkrun:artifact></chkrun:artifacts>'
    .. '</chkrun:checkObject></chkrun:checkObjectList>'

  adt_http.request_async({
    method = "POST",
    path = "/sap/bc/adt/checkruns",
    query = { reporters = "abapCheckRun" },
    content_type = "application/vnd.sap.adt.checkobjects+xml",
    body = xml,
  }, function(body)
    if not body then return end
    local diags = {}
    for msg in body:gmatch("<chkrun:checkMessage([^>]*)>") do
      local uri = msg:match('chkrun:uri="([^"]*)"')
      local typ = msg:match('chkrun:type="([^"]*)"')
      local text = msg:match('chkrun:shortText="([^"]*)"')
      local line, col = (uri or ""):match("start=(%d+),(%d+)")
      -- Solo los mensajes del propio objeto (no de includes externos).
      if line and uri and uri:find(base_uri(source_uri), 1, true) then
        local sev = vim.diagnostic.severity.INFO
        if typ == "E" then sev = vim.diagnostic.severity.ERROR
        elseif typ == "W" then sev = vim.diagnostic.severity.WARN end
        diags[#diags + 1] = {
          lnum = math.max(0, tonumber(line) - 1),
          col = tonumber(col) or 0,
          message = unxml(text or "syntax"),
          severity = sev,
          source = "SAP",
        }
      end
    end
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.diagnostic.set(CHECK_NS, bufnr, diags)
      end
    end)
  end)
end

-- Debounce del check tras escribir.
local function schedule_check(bufnr)
  local t = check_timers[bufnr]
  if t then t:stop(); pcall(t.close, t) end
  local nt = vim.loop.new_timer()
  check_timers[bufnr] = nt
  nt:start(900, 0, vim.schedule_wrap(function()
    check_timers[bufnr] = nil
    M.check_syntax(bufnr)
  end))
end

-- :SapDiag — diagnóstico del completado en el buffer actual (¿por qué no salen propuestas?).
function M.diag()
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local meta = vim.b[bufnr].sap_obj
  local uri = object_uri(bufnr)
  local out = {
    "── sap-nvim diag (completado) ──",
    "filetype        : " .. vim.bo[bufnr].filetype .. (vim.bo[bufnr].filetype == "abap" and "  ✓" or "  ✗ (debe ser 'abap')"),
    "vim.b.sap_obj   : " .. (meta and ("name=" .. tostring(meta.name) .. " group=" .. tostring(meta.group)
      .. (meta.fgroup and (" fgroup=" .. meta.fgroup) or "")) or "NIL  ✗ (abre el objeto con :SapOpen/:SapBrowse)"),
    "URI ADT         : " .. (uri or "NIL  ✗ (sin objeto SAP resoluble -> ADT no tiene contexto)"),
    "ADT disponible  : " .. tostring(adt_http.is_available()) .. (adt_http.is_available() and "  ✓" or "  ✗ (curl/creds)"),
  }
  if uri and adt_http.is_available() then
    local n = #M.proposals(bufnr, row, col)
    out[#out + 1] = "Propuestas aquí : " .. n .. (n > 0 and "  ✓ (el motor funciona)" or "  ✗ (0 en esta posición)")
  end
  vim.notify(table.concat(out, "\n"), vim.log.levels.INFO)
end

-- :SapDaemonTest — prueba la conexión persistente (daemon) en TU nvim: una propuesta por el
-- daemon, reporta cuántas devuelve y en cuánto (frío vs caliente). Verificación en vivo.
function M.daemon_test()
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = object_uri(bufnr)
  if not uri then notify("Abre un objeto SAP (con sap_obj) para probar.", vim.log.levels.WARN); return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  notify("Probando el daemon (la 1ª vez calienta; espera unos segundos)...")
  adt_http.daemon_self_test({
    method = "POST",
    path = "/sap/bc/adt/abapsource/codecompletion/proposal",
    query = { uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col, signalCompleteness = "true" },
    content_type = "text/plain",
    body = src,
  }, function(body, info)
    if not body then notify("Daemon: SIN respuesta (" .. tostring(info) .. ")", vim.log.levels.WARN); return end
    local n = 0; for _ in body:gmatch("<SCC_COMPLETION>") do n = n + 1 end
    notify("Daemon: " .. n .. " propuestas en " .. tostring(info)
      .. (n > 0 and "  → repítelo: la 2ª debe ir MÁS rápida (caliente)" or "  (0 → avísame)"),
      n > 0 and vim.log.levels.INFO or vim.log.levels.WARN)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapDaemonTest", function() M.daemon_test() end,
    { desc = "sap-nvim: Probar la conexión persistente (daemon) — count + latencia" })
  vim.api.nvim_create_user_command("SapDiag", function() M.diag() end,
    { desc = "sap-nvim: Diagnóstico del completado (filetype/sap_obj/URI/ADT/propuestas)" })
  vim.api.nvim_create_user_command("SapSetMainProgram", function() M.change_include() end,
    { desc = "sap-nvim: Fijar el programa principal del include (gd/hover cross-include)" })
  vim.api.nvim_create_user_command("SapComplete", function() M.complete() end,
    { desc = "sap-nvim: Completado ADT (métodos/atributos del sistema)" })
  vim.api.nvim_create_user_command("SapCheck", function() M.check_syntax() end,
    { desc = "sap-nvim: Syntax check de SAP (diagnósticos con posición exacta)" })
  vim.api.nvim_create_user_command("SapHover", function() M.hover() end,
    { desc = "sap-nvim: Hover ADT (firma + documentación)" })
  vim.api.nvim_create_user_command("SapReferences", function() M.references() end,
    { desc = "sap-nvim: Referencias del símbolo (usageReferences)" })
  vim.api.nvim_create_user_command("SapGotoType", function() M.goto_definition("typeDefinition") end,
    { desc = "sap-nvim: Ir al tipo del símbolo bajo el cursor" })
  vim.api.nvim_create_user_command("SapGotoImpl", function()
    if not M.goto_definition("implementation") then notify("Sin implementación.") end
  end, { desc = "sap-nvim: Ir a la implementación del método/interfaz" })
  vim.api.nvim_create_user_command("SapTypeHierarchy", function() M.type_hierarchy(false) end,
    { desc = "sap-nvim: Subtipos del tipo bajo el cursor (jerarquía de tipos)" })
  vim.api.nvim_create_user_command("SapSuperTypes", function() M.type_hierarchy(true) end,
    { desc = "sap-nvim: Supertipos del tipo bajo el cursor (jerarquía de tipos)" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_intel", { clear = true }),
    callback = function(ev)
      local b = ev.buf
      vim.bo[b].omnifunc = "v:lua.require'sap-nvim.core.intel'.omnifunc"
      -- K (Shift-K): hover ADT (bloqueable: 2ª K entra a la ventana, hjkl para scroll).
      vim.keymap.set("n", "K", function() M.hover() end,
        { buffer = b, desc = "ABAP: Hover ADT (firma/doc)" })
      -- gr: referencias del símbolo (picker).
      vim.keymap.set("n", "gr", function() M.references() end,
        { buffer = b, desc = "ABAP: Referencias (usageReferences)" })
      -- gy: ir al tipo del dato bajo el cursor.
      vim.keymap.set("n", "gy", function()
        if not M.goto_definition("typeDefinition") then notify("Sin tipo para el símbolo.") end
      end, { buffer = b, desc = "ABAP: Ir al tipo del dato" })
      -- gI: ir a la implementación (de un método de interfaz, etc.).
      vim.keymap.set("n", "gI", function()
        if not M.goto_definition("implementation") then notify("Sin implementación.") end
      end, { buffer = b, desc = "ABAP: Ir a la implementación" })
      -- gh / gH: jerarquía de tipos (subtipos / supertipos).
      vim.keymap.set("n", "gh", function() M.type_hierarchy(false) end,
        { buffer = b, desc = "ABAP: Subtipos (type hierarchy)" })
      vim.keymap.set("n", "gH", function() M.type_hierarchy(true) end,
        { buffer = b, desc = "ABAP: Supertipos (type hierarchy)" })

      -- Document highlights: resaltar apariciones del símbolo al reposar el cursor.
      vim.api.nvim_create_autocmd("CursorHold", {
        buffer = b, callback = function() pcall(M.document_highlight) end,
      })
      vim.api.nvim_create_autocmd("CursorMoved", {
        buffer = b, callback = function() M.clear_highlight(b) end,
      })

      -- Calienta la conexión persistente (daemon) al abrir el objeto, para que el primer
      -- completado/hover ya vaya CALIENTE (instantáneo, como VSCode al abrir el FS remoto).
      if vim.b[b].sap_obj then pcall(function() adt_http.warmup() end) end

      -- Syntax check de SAP EN VIVO (como VSCode): al escribir (debounce) y al guardar.
      -- Solo para objetos remotos (sap_obj).
      if vim.b[b].sap_obj then M.check_syntax(b) end
      vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
        buffer = b,
        callback = function() if vim.b[b].sap_obj then schedule_check(b) end end,
      })
      vim.api.nvim_create_autocmd("BufWritePost", {
        buffer = b,
        callback = function() if vim.b[b].sap_obj then M.check_syntax(b) end end,
      })
    end,
  })
end

return M
