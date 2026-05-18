-- sap-nvim.integrations.completion
-- Autocompletado ABAP con snippets inline
-- Funciona con cualquier engine de completion (blink, nvim-cmp, etc.)

local M = {}

-- Snippets ABAP para autocompletado
local snippets = require("sap-nvim.core.snippets")

-- Obtener snippets como items de completion
local function get_snippet_items()
  local items = {}
  for key, snip in pairs(snippets) do
    local trigger = snip.trig
    table.insert(items, {
      word = trigger,
      abbr = trigger,
      menu = "[ABAP] " .. snip.name,
      info = snip.body:gsub("\\n", "\n"),
      icase = 1,
      dup = 1,
      -- El cuerpo del snippet se expande al seleccionar
      snippet = snip.body:gsub("\\n", "\n"),
    })
  end
  return items
end

-- Comando para completar snippets ABAP
local function abap_complete()
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  -- Obtener la palabra antes del cursor
  local before = line:sub(1, col)
  local word = before:match("([%w_]+)$") or ""

  if #word < 2 then
    vim.notify("sap-nvim: Escribí al menos 2 caracteres y pulsá <C-x><C-u>", vim.log.levels.INFO)
    return
  end

  -- Filtrar snippets que empiecen con la palabra
  local items = get_snippet_items()
  local filtered = {}
  for _, item in ipairs(items) do
    if item.word:sub(1, #word) == word then
      table.insert(filtered, item)
    end
  end

  if #filtered == 0 then
    vim.notify("sap-nvim: No hay snippets para '" .. word .. "'", vim.log.levels.INFO)
    return
  end

  -- Usar compleción nativa de Vim
  vim.fn.complete(col + 1, filtered)
end

-- Expandir snippet seleccionado (insertar el cuerpo)
local function expand_snippet(snippet_body)
  if not snippet_body then return end
  -- Eliminar la palabra que disparó el snippet
  local line = vim.api.nvim_get_current_line()
  local col = vim.api.nvim_win_get_cursor(0)[2]
  local before = line:sub(1, col)
  local word = before:match("([%w_]+)$") or ""
  local start_col = col - #word
  local new_line = line:sub(1, start_col) .. line:sub(col + 1)
  vim.api.nvim_set_current_line(new_line)
  -- Insertar el cuerpo del snippet
  local lines = vim.split(snippet_body, "\n", true)
  vim.api.nvim_buf_set_lines(0, vim.fn.line(".") - 1, vim.fn.line("."), false, lines)
end

function M.setup(opts)
  opts = opts or {}

  -- Solo activar para ABAP
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      -- Atajo para completar snippets: Ctrl+Space o Ctrl+X Ctrl+U
      vim.keymap.set("i", "<C-x><C-u>", function()
        abap_complete()
      end, { buffer = true, desc = "ABAP: Completar snippet" })

      -- Tambien con Ctrl+Space
      vim.keymap.set("i", "<C-Space>", function()
        abap_complete()
      end, { buffer = true, desc = "ABAP: Completar snippet" })
    end,
  })
end

return M
