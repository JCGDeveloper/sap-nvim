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

-- Parsea el XML de propuestas de ADT -> lista { {word}, ... }.
function M.parse(body)
  local items = {}
  if not body then return items end
  for block in body:gmatch("<SCC_COMPLETION>(.-)</SCC_COMPLETION>") do
    local id = block:match("<IDENTIFIER>([^<]*)</IDENTIFIER>")
    if id and id ~= "" and id ~= "@end" then
      items[#items + 1] = { word = id }
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
    query = { uri = uri .. "%23start=" .. row .. "," .. col },
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
  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/navigation/target",
    query = { uri = uri .. "%23start=" .. row .. "," .. col, filter = filter or "definition" },
    body = src,
  })
  if not body then return nil end
  local target = body:match('adtcore:uri="([^"]*)"')
  return target and uri_to_object(unxml(target)) or nil
end

-- Va a la definición (o al tipo, si type=true) del símbolo bajo el cursor, vía ADT.
-- Devuelve true si encontró y abrió algo.
function M.goto_definition(want_type)
  local bufnr = vim.api.nvim_get_current_buf()
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local obj = M.definition_target(bufnr, row, col, want_type and "typeDefinition" or "definition")
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
    query = { uri = uri .. "%23start=" .. row .. "," .. col },
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

function M.setup()
  vim.api.nvim_create_user_command("SapComplete", function() M.complete() end,
    { desc = "sap-nvim: Completado ADT (métodos/atributos del sistema)" })
  vim.api.nvim_create_user_command("SapHover", function() M.hover() end,
    { desc = "sap-nvim: Hover ADT (firma + documentación)" })
  vim.api.nvim_create_user_command("SapReferences", function() M.references() end,
    { desc = "sap-nvim: Referencias del símbolo (usageReferences)" })
  vim.api.nvim_create_user_command("SapGotoType", function() M.goto_definition(true) end,
    { desc = "sap-nvim: Ir al tipo del símbolo bajo el cursor" })

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
        if not M.goto_definition(true) then notify("Sin tipo para el símbolo.") end
      end, { buffer = b, desc = "ABAP: Ir al tipo del dato" })
    end,
  })
end

return M
