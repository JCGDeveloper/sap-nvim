-- sap-nvim.adapters.oil
-- Adaptador para navegación remota SAP con oil.nvim

local M = {}

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

      local handle = io.popen("sapcli search " .. package .. " 2>/dev/null")
      if not handle then
        return {}, "sapcli no encontrado"
      end

      local entries = {}
      for line in handle:lines() do
        table.insert(entries, {
          name = line,
          type = "file",
        })
      end
      handle:close()
      return entries
    end,

    --- Leer objeto remoto
    read = function(_, url)
      local object = url.path:match("^/(.+)$") or ""
      local handle = io.popen("sapcli cat " .. object .. " 2>/dev/null")
      if not handle then
        return "", "Error leyendo " .. object
      end
      local content = handle:read("*a")
      handle:close()
      return content
    end,

    --- Escribir objeto remoto
    write = function(_, url, data)
      local object = url.path:match("^/(.+)$") or ""
      local tmpfile = os.tmpname()
      local f = io.open(tmpfile, "w")
      if f then
        f:write(data)
        f:close()
      end
      os.execute("sapcli put " .. object .. " " .. tmpfile .. " 2>/dev/null")
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
