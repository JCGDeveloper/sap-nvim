-- sap-nvim.core.adt
-- Cliente ADT para conexión y operaciones con sistemas SAP remotos

local M = {
  connections = {},
  current = nil,
}

function M.setup(opts)
  opts = opts or {}
  M.connections = opts.connections or {}
end

-- Seleccionar conexión activa
function M.select_connection(name)
  if M.connections[name] then
    M.current = M.connections[name]
    vim.notify(("sap-nvim: Conexión '%s' seleccionada"):format(name))
  else
    vim.notify(("sap-nvim: Conexión '%s' no encontrada"):format(name), vim.log.levels.ERROR)
  end
end

-- Activar objeto ABAP actual vía sapcli
function M.activate_current()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local object_name = vim.fn.expand("%:t:r")

  if object_name == "" then
    vim.notify("sap-nvim: No hay un objeto ABAP para activar", vim.log.levels.WARN)
    return
  end

  vim.cmd("write")
  vim.fn.jobstart({ "sapcli", "activate", object_name }, {
    on_exit = function(_, exit_code)
      if exit_code == 0 then
        vim.notify(("sap-nvim: %s activado correctamente"):format(object_name))
      else
        vim.notify(("sap-nvim: Error activando %s"):format(object_name), vim.log.levels.ERROR)
      end
    end,
  })
end

-- Ejecutar ATC (ABAP Test Cockpit)
function M.run_atc()
  local object_name = vim.fn.expand("%:t:r")
  if object_name == "" then
    return
  end

  vim.cmd("!sapcli atc run object " .. object_name)
end

-- Ejecutar pruebas unitarias
function M.run_aunit()
  local object_name = vim.fn.expand("%:t:r")
  if object_name == "" then
    return
  end

  vim.cmd("!sapcli aunit run class " .. object_name .. " --output junit4")
end

-- Buscar objetos en SAP
function M.search(query)
  vim.fn.jobstart({ "sapcli", "search", query }, {
    on_stdout = function(_, data)
      if data then
        local results = vim.iter(data):filter(function(line) return line ~= "" end):totable()
        if #results > 0 then
          vim.notify(("sap-nvim: %d resultados para '%s'"):format(#results, query))
        end
      end
    end,
  })
end

return M
