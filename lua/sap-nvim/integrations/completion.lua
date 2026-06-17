-- sap-nvim.integrations.completion
-- Autocompletado ABAP con snippets inline (camino nativo: <C-Space> / <C-x><C-u>).
-- Independiente del engine: si el usuario usa blink.cmp, blink consume core/snippets.lua
-- por su lado; esto da una vía nativa que SÍ expande el cuerpo (con tabstops) al elegir.

local M = {}

local snippets = require("sap-nvim.core.snippets")

-- trigger -> cuerpo en sintaxis LSP (`${1:...}`) con saltos de línea reales.
local snippet_bodies = {}

-- Solo expandimos tras NUESTRA compleción (muchos triggers —value/new/ref/data/const…—
-- coinciden con identificadores ABAP reales; sin este flag expandiríamos por error una
-- compleción de blink/omni). Se activa justo antes de vim.fn.complete y se consume en CompleteDone.
local pending = false

local function get_snippet_items()
  local items = {}
  for _, snip in pairs(snippets) do
    local body = snip.body:gsub("\\n", "\n")
    snippet_bodies[snip.trig] = body
    table.insert(items, {
      word = snip.trig,
      abbr = snip.trig,
      menu = "[ABAP] " .. snip.name,
      info = body,
      icase = 1,
      dup = 1,
    })
  end
  return items
end

-- Completa snippets ABAP cuya palabra empiece por lo tecleado (>=2 chars).
local function abap_complete()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local word = before:match("([%w_]+)$") or ""

  if #word < 2 then
    vim.notify("sap-nvim: Escribí al menos 2 caracteres antes de completar.", vim.log.levels.INFO)
    return
  end

  local filtered = {}
  for _, item in ipairs(get_snippet_items()) do
    if item.word:sub(1, #word):lower() == word:lower() then
      table.insert(filtered, item)
    end
  end

  if #filtered == 0 then
    vim.notify("sap-nvim: No hay snippets para '" .. word .. "'", vim.log.levels.INFO)
    return
  end

  pending = true
  -- startcol = inicio de la palabra (1-indexed), para que el trigger reemplace lo tecleado.
  vim.fn.complete(col - #word + 1, filtered)
end

-- Al cerrar la compleción nuestra: quita el trigger insertado y expande el cuerpo real.
local function on_complete_done()
  if not pending then return end
  pending = false
  local item = vim.v.completed_item
  local trig = item and item.word
  local body = trig and snippet_bodies[trig]
  if not body then return end

  -- El trigger acaba de insertarse antes del cursor; lo borramos y expandimos en su lugar.
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local w = before:match("([%w_]+)$") or ""
  if w ~= trig then return end
  local start = col - #w
  vim.api.nvim_set_current_line(line:sub(1, start) .. line:sub(col + 1))
  vim.api.nvim_win_set_cursor(0, { vim.fn.line("."), start })

  if vim.snippet and vim.snippet.expand then
    vim.snippet.expand(body) -- tabstops/placeholders nativos (Neovim 0.10+)
  else
    -- Fallback sin tabstops: inserta el cuerpo en crudo (quita los marcadores LSP).
    local plain = body:gsub("%${%d+:([^}]*)}", "%1"):gsub("%$%d+", "")
    local lines = vim.split(plain, "\n", { plain = true })
    vim.api.nvim_put(lines, "c", false, true)
  end
end

function M.setup(opts)
  opts = opts or {}

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function(ev)
      vim.keymap.set("i", "<C-x><C-u>", abap_complete, { buffer = ev.buf, desc = "ABAP: Completar snippet" })
      vim.keymap.set("i", "<C-Space>", abap_complete, { buffer = ev.buf, desc = "ABAP: Completar snippet" })
      vim.api.nvim_create_autocmd("CompleteDone", {
        buffer = ev.buf,
        callback = on_complete_done,
        desc = "ABAP: expandir snippet seleccionado",
      })
    end,
  })
end

return M
