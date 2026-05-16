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

-- Abrir SAP GUI (aplicación de escritorio)
function M.open_gui(connection_name)
  local sapgui_path = "/Applications/SAP GUI.app"

  -- Intentar rutas alternativas de SAP GUI
  local possible_paths = {
    "/Applications/SAP GUI.app",
    "/Applications/SAPGUI.app",
    "/Applications/SAP GUI 7.60.app",
    "/Applications/SAP GUI 7.70.app",
    "/Applications/SAPGUI/SAP GUI.app",
  }

  local app_path = nil
  for _, path in ipairs(possible_paths) do
    local f = io.open(path .. "/Contents/Info.plist", "r")
    if f then
      f:close()
      app_path = path
      break
    end
  end

  if not app_path then
    vim.notify("sap-nvim: SAP GUI no encontrado. Verifica la ruta de instalación.", vim.log.levels.ERROR)
    return
  end

  -- Determinar el objeto actual
  local object_name = vim.fn.expand("%:t:r")
  local file_ext = vim.fn.expand("%:e")
  local transaction = M._get_transaction_for_extension(file_ext)

  -- Elegir conexión
  local conn = nil
  if connection_name and M.connections[connection_name] then
    conn = M.connections[connection_name]
  elseif M.current then
    conn = M.current
  end

  if object_name ~= "" and object_name ~= "[No Name]" and transaction then
    -- Opción 2: Abrir SAP GUI con el objeto específico
    -- Usamos sapgui URL scheme si está disponible
    local sid = conn and conn.system_id or ""
    local cmd = string.format(
      "open '%s' --args -saprouter= -conn=%s -object=%s -transaction=%s",
      app_path, sid, object_name, transaction
    )
    vim.fn.jobstart({ "open", app_path })
    vim.notify(string.format(
      "sap-nvim: Abriendo %s en %s...",
      object_name, transaction
    ))
  else
    -- Opción 1: Solo abrir SAP GUI
    vim.fn.jobstart({ "open", app_path })
    vim.notify("sap-nvim: Abriendo SAP GUI...")
  end
end

-- Mapear extensión de archivo a transacción SAP
function M._get_transaction_for_extension(ext)
  local map = {
    abap = "SE80",          -- Object Navigator
    cls = "SE24",           -- Class Builder
    prog = "SE38",          -- ABAP Editor
    func = "SE37",          -- Function Builder
    ddl = "SE80",           -- CDS View (via SE80)
    dcl = "SE80",           -- CDS Access Control
    bdef = "SE80",          -- CDS Behavior Definition
    dbrel = "SE80",         -- CDS Metadata Extension
    simple = "SE80",
    fugr = "SE37",
    cinclude = "SE80",
    ddls = "SE80",
    intf = "SE80",
    tabl = "SE11",          -- Data Dictionary
    stru = "SE11",
    dtel = "SE11",
    dome = "SE11",
  }
  return map[ext:lower()]
end

return M
