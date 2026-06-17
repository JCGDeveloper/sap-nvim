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

function M.setup()
  vim.api.nvim_create_user_command("SapComplete", function() M.complete() end,
    { desc = "sap-nvim: Completado ADT (métodos/atributos del sistema)" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_intel", { clear = true }),
    callback = function(ev)
      vim.bo[ev.buf].omnifunc = "v:lua.require'sap-nvim.core.intel'.omnifunc"
    end,
  })
end

return M
