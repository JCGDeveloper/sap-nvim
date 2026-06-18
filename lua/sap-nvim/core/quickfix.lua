-- sap-nvim.core.quickfix
-- Quick fixes / code actions (los 💡 de VSCode). Replica abap-adt-api:
--   1) fixProposals: POST /sap/bc/adt/quickfixes/evaluation (uri#start, body=source) -> propuestas.
--   2) fixEdits: POST a la `adtcore:uri` de la propuesta elegida -> deltas (rango + contenido).
--   3) Aplica los deltas al buffer (en orden inverso para no desplazar posiciones).
-- Seguro: si algo no encaja (sin propuestas / sin deltas), NO toca el buffer.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function enc(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end
local function dec(s)
  return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- Parsea las propuestas: bloques <adtcore:objectReference .../> con adtcore:uri/name/description
-- y (si está) userContent. Devuelve { {adt_uri, name, desc, user} ... }.
local function parse_proposals(body)
  local out = {}
  if not body then return out end
  for tag in body:gmatch("<adtcore:objectReference[^>]->") do
    local adt_uri = tag:match('adtcore:uri="([^"]*)"')
    local name = tag:match('adtcore:name="([^"]*)"')
    local desc = tag:match('adtcore:description="([^"]*)"')
    if adt_uri and adt_uri ~= "" then
      out[#out + 1] = { adt_uri = dec(adt_uri), name = name or "", desc = dec(desc or (name or "fix")) }
    end
  end
  return out
end

-- Parsea los deltas de fixEdits: <unit> con <adtcore:objectReference adtcore:uri="..#start=l,c;end=l,c">
-- y <content>. Devuelve { {srow,scol,erow,ecol, content} ... }.
local function parse_deltas(body)
  local out = {}
  if not body then return out end
  for unit in body:gmatch("<unit>(.-)</unit>") do
    local ref = unit:match('adtcore:uri="([^"]*)"') or ""
    local sl, sc, el, ec = ref:match("start=(%d+),(%d+);end=(%d+),(%d+)")
    local content = unit:match("<content>(.-)</content>")
    if sl and content then
      out[#out + 1] = {
        srow = tonumber(sl), scol = tonumber(sc), erow = tonumber(el), ecol = tonumber(ec),
        content = dec(content),
      }
    end
  end
  return out
end

-- Aplica los deltas al buffer (orden inverso: de abajo a arriba, para no invalidar rangos).
local function apply_deltas(bufnr, deltas)
  table.sort(deltas, function(a, b)
    if a.srow ~= b.srow then return a.srow > b.srow end
    return a.scol > b.scol
  end)
  for _, d in ipairs(deltas) do
    -- ADT: línea 1-based, col 0-based -> nvim_buf_set_text usa 0-based en ambos.
    local ok = pcall(vim.api.nvim_buf_set_text, bufnr,
      math.max(0, d.srow - 1), d.scol, math.max(0, d.erow - 1), d.ecol,
      vim.split(d.content, "\n", { plain = true }))
    if not ok then notify("No se pudo aplicar un delta (rango fuera de sitio).", vim.log.levels.WARN) end
  end
end

function M.quickfix()
  if not adt_http.is_available() then notify("ADT no disponible.", vim.log.levels.WARN); return end
  local intel = require("sap-nvim.core.intel")
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = intel.object_uri(bufnr)
  if not uri then notify("No es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN); return end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  notify("Buscando quick fixes...")

  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/quickfixes/evaluation",
    query = { uri = uri .. "%23start=" .. row .. "," .. col },
    content_type = "application/*",
    accept = "application/*",
    body = src,
  })
  local proposals = parse_proposals(body)
  if #proposals == 0 then notify("Sin quick fixes aquí."); return end

  vim.ui.select(proposals, {
    prompt = "Quick fixes (" .. #proposals .. "):",
    format_item = function(p) return p.desc ~= "" and p.desc or p.name end,
  }, function(choice)
    if not choice then return end
    -- fixEdits: POST a la uri de la propuesta, body proposalRequest (igual que abap-adt-api).
    local req = '<?xml version="1.0" encoding="UTF-8"?>'
      .. '<quickfixes:proposalRequest xmlns:quickfixes="http://www.sap.com/adt/quickfixes" '
      .. 'xmlns:adtcore="http://www.sap.com/adt/core"><input><content>' .. enc(src) .. '</content>'
      .. '<adtcore:objectReference adtcore:uri="' .. uri .. '#start=' .. row .. ',' .. col .. '"/>'
      .. '</input><userContent>' .. enc(choice.user or "") .. '</userContent></quickfixes:proposalRequest>'
    -- adt_http.request añade sap-client; la path es la adtcore:uri de la propuesta (puede traer ?query).
    local res = adt_http.request({
      method = "POST", path = choice.adt_uri,
      content_type = "application/*", accept = "application/*", body = req,
    })
    local deltas = parse_deltas(res)
    if #deltas == 0 then notify("El quick fix no devolvió cambios aplicables.", vim.log.levels.WARN); return end
    apply_deltas(bufnr, deltas)
    notify("Quick fix aplicado (" .. #deltas .. " cambio(s)). Revisa y guarda con :SapPush. (u para deshacer)")
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapQuickfix", function() M.quickfix() end,
    { desc = "sap-nvim: Quick fixes / code actions (ADT) bajo el cursor" })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_quickfix", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>aq", function() M.quickfix() end,
        { buffer = ev.buf, desc = "ABAP: Quick fixes / code actions" })
    end,
  })
end

return M
