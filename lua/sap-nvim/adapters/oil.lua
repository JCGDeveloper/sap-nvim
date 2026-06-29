-- sap-nvim.adapters.oil
-- Adaptador para navegación remota SAP con oil.nvim

local M = {}
local sapcli = require("sap-nvim.core.sapcli")

function M.setup(opts)
  opts = opts or {}

  -- Configurar oil.nvim para soportar protocolo sap://
  -- Ejemplo de uso: :Oil sap://ZCL_EJEMPLO
  local oil_ok, oil = pcall(require, "oil")
  if not oil_ok then
    return
  end

  -- Adaptador personalizado para SAP ADT
  -- Convierte operaciones de archivos en llamadas ADT API
  local adapter = {
    name = "sap",
    --- Listar objetos de un paquete SAP
    list = function(_, url)
      local package = url.host or url.path:match("^/(.+)$")
      if not package then
        return {}, "Especifica un paquete SAP (sap://Z_MI_PAQUETE)"
      end

      -- vim.fn.system con LISTA: invoca sapcli directamente (sin shell), así un nombre de
      -- paquete con metacaracteres no puede inyectar comandos.
      local out = sapcli.system({ "sapcli", "search", package })
      if vim.v.shell_error ~= 0 then
        return {}, "sapcli falló al buscar " .. package
      end

      local entries = {}
      for line in (out or ""):gmatch("[^\r\n]+") do
        if vim.trim(line) ~= "" then
          table.insert(entries, { name = line, type = "file" })
        end
      end
      return entries
    end,

    --- Leer objeto remoto
    read = function(_, url)
      local object = url.path:match("^/(.+)$") or ""
      local content = sapcli.system({ "sapcli", "cat", object })
      if vim.v.shell_error ~= 0 then
        return "", "Error leyendo " .. object
      end
      return content
    end,

    --- Escribir objeto remoto
    write = function(_, url, data)
      local ok_cfg, cfg = pcall(function()
        return require("sap-nvim.core.config").productive()
      end)
      if not (ok_cfg and cfg.allow_oil_write == true) then
        return false, "sap:// oil es solo lectura por seguridad. Usa :SapPush/:SapPushActivate."
      end
      local object = url.path:match("^/(.+)$") or ""
      local tmpfile = os.tmpname()
      local f = io.open(tmpfile, "w")
      if f then
        f:write(data)
        f:close()
      end
      sapcli.system({ "sapcli", "put", object, tmpfile })
      os.remove(tmpfile)
      return true
    end,
  }

  -- Registrar adaptador (si oil lo soporta)
  if oil.register_adapter then
    oil.register_adapter("sap", adapter)
  end
end

return M
