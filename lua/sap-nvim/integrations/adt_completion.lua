-- sap-nvim.integrations.adt_completion
-- Fuente blink.cmp que muestra AUTOMÁTICAMENTE (desplegable, como VSCode) el completado
-- ABAP del sistema vía ADT (core/intel.proposals_async): tanto los métodos/atributos de la
-- clase que llamas (tras `=>`/`->`/`~`) como NOMBRES DE CLASE/tipos/variables al escribir un
-- identificador — igual que la extensión de VSCode.
--
-- Equilibrio para no martillear SAP:
--   * Tras acceso a miembro (`=>`/`->`/`~`): la lista de miembros es fija → UNA llamada y
--     blink filtra localmente (is_incomplete_forward=false).
--   * Identificador suelto (≥2 chars): el conjunto cambia con el prefijo → se re-consulta
--     según escribes (is_incomplete_forward=true), como VSCode. <2 chars: no consulta.
--
-- Registro en blink: provider "sap_adt" (en la config del usuario). enabled() la limita a ABAP.

local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "abap"
end

-- Tras escribir estos caracteres, blink dispara la fuente.
-- `(` y `,`: muestran los PARÁMETROS del método al abrir/continuar la llamada (signature
-- help, como VSCode). `>`/`~`: acceso a miembro.
function source:get_trigger_characters()
  return { ">", "~", "(", "," }
end

local Kind = vim.lsp.protocol.CompletionItemKind

function source:get_completions(ctx, callback)
  local col = ctx.cursor[2]
  local before = (ctx.line or ""):sub(1, col)

  -- Contexto: acceso a miembro (cl_x=> , lo-> , if_x~), llamada (tras `(` o `,` →
  -- parámetros), o identificador suelto.
  local member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil
  local call = before:match("[%(,]%s*$") ~= nil   -- justo tras abrir/continuar una llamada
  local word = before:match("[%w_/][%w_/]*$")

  -- No consultar si no hay acceso a miembro/llamada y el prefijo es <2 chars (no martillear SAP).
  if not member and not call and (not word or #word < 2) then
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
        is_incomplete_backward = not member,
        -- Miembro: lista fija (filtra local). Identificador suelto: re-consulta al crecer.
        is_incomplete_forward = not member,
      })
    end)
  end)

  return function() end -- (cancelación: no-op)
end

return source
