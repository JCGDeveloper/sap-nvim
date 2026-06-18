-- sap-nvim.integrations.abap_local
-- Fuente blink.cmp LOCAL e INSTANTÁNEA (sin red): keywords ABAP (da->DATA) + las plantillas/
-- snippets de core/snippets.lua. Es lo que hace que el completado se sienta INMEDIATO como en
-- VSCode: estas propuestas NO consultan al servidor, se devuelven en el acto y blink las filtra
-- localmente. La fuente `sap_adt` (ADT) sigue aportando, async, los métodos/atributos/clases
-- del sistema (eso sí necesita el servidor).
--
-- Registro en blink: provider "abap_local" (en la config del usuario), junto a "sap_adt".

local source = {}

function source.new(opts)
  return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
  return vim.bo.filetype == "abap"
end

local Kind = vim.lsp.protocol.CompletionItemKind
local Fmt = vim.lsp.protocol.InsertTextFormat

-- Los items son ESTÁTICOS (keywords + snippets) -> se construyen una vez y se cachean.
local cache

local function build_items()
  if cache then return cache end
  local items = {}

  -- 1) Keywords ABAP (en MAYÚSCULAS), reutilizando la lista del formateador.
  local seen = {}
  local ok, fmt = pcall(require, "sap-nvim.core.formatter")
  for _, kw in ipairs((ok and fmt.keywords) or {}) do
    local u = kw:upper()
    if not seen[u] then
      seen[u] = true
      items[#items + 1] = {
        label = u, insertText = u, kind = Kind.Keyword,
        labelDetails = { description = "keyword" }, source_name = "ABAP",
      }
    end
  end

  -- 2) Plantillas/snippets (se expanden con placeholders ${n}).
  local oks, snippets = pcall(require, "sap-nvim.core.snippets")
  if oks then
    for _, s in pairs(snippets) do
      if s.trig then
        items[#items + 1] = {
          label = s.trig,
          insertText = s.body:gsub("\\n", "\n"),
          insertTextFormat = Fmt.Snippet,
          kind = Kind.Snippet,
          labelDetails = { description = "snippet · " .. (s.name or "") },
          source_name = "ABAP",
        }
      end
    end
  end

  cache = items
  return items
end

-- Devuelve TODO el set al instante; blink lo filtra localmente (fuzzy) según escribes.
function source:get_completions(_ctx, callback)
  callback({ items = build_items(), is_incomplete_backward = false, is_incomplete_forward = false })
  return function() end
end

return source
