-- sap-nvim.integrations.adt_completion
-- Fuente blink.cmp que muestra AUTOMÁTICAMENTE (en un desplegable, como VSCode) los
-- métodos/atributos de la clase que llamas, vía ADT (core/intel.proposals_async).
--
-- Para no martillear SAP, solo consulta ADT tras un operador de acceso a miembro
-- (`=>`, `->`, `~`); blink filtra localmente según escribes (is_incomplete_forward=false),
-- así hay UNA llamada a ADT por `=>` en vez de una por tecla.
--
-- Registro en blink: ver ~/.config/nvim (provider "sap_adt"). El gate enabled() la limita
-- a buffers ABAP.

local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "abap"
end

-- Tras escribir estos caracteres, blink dispara la fuente.
function source:get_trigger_characters()
  return { ">", "~" }
end

local Kind = vim.lsp.protocol.CompletionItemKind

function source:get_completions(ctx, callback)
  -- Solo consultar ADT en contexto de acceso a miembro (cl_x=> , lo-> , if_x~).
  local col = ctx.cursor[2]
  local before = (ctx.line or ""):sub(1, col)
  if not (before:match("[=%-]>[%w_]*$") or before:match("~[%w_]*$")) then
    callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
    return function() end
  end

  local intel = require("sap-nvim.core.intel")
  local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
  local row = ctx.cursor[1]

  intel.proposals_async(bufnr, row, col, function(props)
    local items = {}
    for _, p in ipairs(props) do
      items[#items + 1] = {
        label = p.word,
        insertText = p.word,
        kind = Kind.Method,
        source_name = "SAP",
      }
    end
    vim.schedule(function()
      callback({
        items = items,
        -- Lista completa: blink filtra localmente mientras escribes (1 llamada ADT por `=>`).
        is_incomplete_backward = false,
        is_incomplete_forward = false,
      })
    end)
  end)

  return function() end -- (cancelación: no-op)
end

return source
