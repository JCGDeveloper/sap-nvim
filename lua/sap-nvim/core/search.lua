-- sap-nvim.core.search
-- Búsqueda de objetos EN VIVO (as-you-type), como la "Unified Object Search" de VSCode:
-- a cada tecla consulta el sistema y muestra los resultados. Usa fzf-lua en modo live
-- ejecutando `sapcli abap find <query>` (fzf hace debounce). Si no hay fzf-lua, cae al
-- buscador de una pasada (browser.search_objects).

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Tipo de `abap find` (col 1) -> group de sapcli para abrir el objeto.
local TYPE_GROUP = {
  ["CLAS/OC"] = "class", ["INTF/OI"] = "interface",
  ["PROG/P"] = "program", ["PROG/I"] = "include", ["FUGR/F"] = "functiongroup",
}

-- Parsea una fila de `sapcli abap find`: "CLAS/OC | ZCL_X | desc" -> typ, name (o nil).
local function parse_row(line)
  return line:match("^%s*([%u%d_]+/[%u%d_]+)%s*|%s*([%w_/]+)")
end

function M.live()
  local ok, fzf = pcall(require, "fzf-lua")
  if not ok then
    -- Sin fzf-lua: buscador de una pasada existente.
    require("sap-nvim.core.browser").search_objects()
    return
  end

  local launched = pcall(function()
    fzf.fzf_live(
      -- fzf-lua pasa la query escrita; devolvemos el comando que produce los resultados.
      function(query)
        if not query or #query < 2 then return "true" end -- <2 chars: sin resultados
        return "sapcli abap find " .. vim.fn.shellescape(query)
      end,
      {
        prompt = "Buscar SAP> ",
        -- Mostrar solo filas de datos, formateadas "TIPO  NOMBRE".
        fn_transform = function(line)
          local typ, name = parse_row(line)
          if not name then return nil end
          return string.format("%-10s %s", typ, name)
        end,
        actions = {
          ["default"] = function(selected)
            local sel = selected and selected[1]
            if not sel then return end
            local typ, name = sel:match("^(%S+)%s+(%S+)")
            local group = TYPE_GROUP[typ]
            if group then
              require("sap-nvim.core.source").open(name, group)
            else
              notify("Tipo " .. tostring(typ) .. " (" .. tostring(name) .. ") no abrible directamente.")
            end
          end,
        },
      }
    )
  end)
  if not launched then
    notify("fzf-lua live no disponible; usando búsqueda de una pasada.", vim.log.levels.WARN)
    require("sap-nvim.core.browser").search_objects()
  end
end

function M.setup()
  vim.api.nvim_create_user_command("SapSearchLive", function() M.live() end,
    { desc = "sap-nvim: Búsqueda de objetos EN VIVO (as-you-type, como VSCode)" })
  vim.keymap.set("n", "<leader>aS", function() M.live() end,
    { desc = "ABAP: Buscar objeto EN VIVO" })
end

return M
