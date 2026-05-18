-- sap-nvim.integrations.blink
-- Integración con blink.cmp para snippets ABAP

local M = {}

local snippets = require("sap-nvim.core.snippets")

function M.setup(opts)
  opts = opts or {}

  local ok, blink = pcall(require, "blink.cmp")
  if not ok then return end

  -- Crear fuente de snippets ABAP para blink
  -- Se activa solo en archivos .abap
  local abap_snippets = {}

  for key, snip in pairs(snippets) do
    table.insert(abap_snippets, {
      trigger = snip.trig,
      body = snip.body,
      name = snip.name,
    })
  end

  -- Registrar snippets en blink
  -- Usa el provider de snippets de blink
  blink.setup({
    sources = {
      providers = {
        abap_snippets = {
          name = "abap_snippets",
          module = "blink.cmp.sources.snippets",
          enabled = function()
            return vim.bo.filetype == "abap"
          end,
          -- Registrar los snippets
          opts = {
            snippets = abap_snippets,
          },
        },
      },
    },
  })
end

return M
