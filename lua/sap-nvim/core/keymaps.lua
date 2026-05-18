-- sap-nvim.core.keymaps
-- Atajos básicos para ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- TDD: Ejecutar tests unitarios ABAP vía sapcli
  vim.keymap.set("n", "<leader>aT", function()
    local obj = vim.fn.expand("%:t:r")
    if obj == "" then
      vim.notify("sap-nvim: Guardá el archivo primero", vim.log.levels.WARN)
      return
    end
    vim.cmd("write")
    vim.notify("[sap-nvim] Ejecutando tests de " .. obj .. "...")
    local aunit_lines = {}
    vim.fn.jobstart({ "sapcli", "aunit", "run", "class", obj }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(aunit_lines, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if #aunit_lines > 0 then
            vim.notify("[sap-nvim] AUnit:\n" .. table.concat(aunit_lines, "\n"))
          end
          if code == 0 then
            vim.notify("[sap-nvim] Tests OK", vim.log.levels.INFO)
          else
            vim.notify("[sap-nvim] Tests fallaron (code " .. code .. ")", vim.log.levels.WARN)
          end
        end)
      end,
    })
  end, { desc = "ABAP: Ejecutar tests unitarios" })

  -- ATC: Ejecutar ABAP Test Cockpit
  vim.keymap.set("n", "<leader>aK", function()
    local obj = vim.fn.expand("%:t:r")
    if obj == "" then
      vim.notify("sap-nvim: Guardá el archivo primero", vim.log.levels.WARN)
      return
    end
    vim.notify("[sap-nvim] Ejecutando ATC sobre " .. obj .. "...")
    local atc_lines = {}
    vim.fn.jobstart({ "sapcli", "atc", "run", "object", obj }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(atc_lines, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if #atc_lines > 0 then
            vim.notify("[sap-nvim] ATC:\n" .. table.concat(atc_lines, "\n"))
          end
          if code == 0 then
            vim.notify("[sap-nvim] ATC OK", vim.log.levels.INFO)
          else
            vim.notify("[sap-nvim] ATC encontro issues", vim.log.levels.WARN)
          end
        end)
      end,
    })
  end, { desc = "ABAP: Ejecutar ATC" })

  -- Help actualizada
  vim.keymap.set("n", "<leader>ah", function()
    vim.notify([[
sap-nvim atajos:
  <leader>ah   Ayuda
  <leader>aF   Formatear (uppercase + indent)
  <leader>ad   Debuggear ABAP (vsp)
  <leader>aT   Ejecutar tests unitarios
  <leader>aK   Ejecutar ATC (quality check)

  OBJETOS:
  <leader>an   Nuevo objeto ABAP (con pickers de paquete/transporte)
  <leader>afs  Buscar objeto en el sistema SAP (:SapSearch)
  <leader>afb  Explorar contenido de un paquete (:SapBrowse)

  TRANSPORTES:
  <leader>atl  Listar ordenes de transporte (:SapTransports)
  <leader>atc  Crear orden de transporte (:SapTransportCreate)
  <leader>atr  Liberar orden de transporte (:SapTransportRelease)

  SISTEMA:
  <leader>asg  Abrir SAP GUI
  <leader>aso  Objeto en SAP GUI
  <leader>asc  Configurar conexiones SAP
  <leader>asi  Info de conexion activa (:SapStatus)
  <leader>aD   Diff buffer local vs SAP sistema (:SapDiff)
    ]], vim.log.levels.INFO)
  end, { desc = "ABAP: Ayuda" })

  -- Formatear ABAP con formateador nativo (uppercase + indentación)
  vim.keymap.set("n", "<leader>aF", function()
    if vim.bo.filetype ~= "abap" then return end
    require("sap-nvim.core.formatter").format_file()
  end, { desc = "ABAP: Formatear (uppercase + indentación)" })

  -- SAP GUI integration
  local function find_sapgui()
    local paths = {
      "/Applications/SAP GUI.app",
      "/Applications/SAPGUI.app",
    }
    for _, p in ipairs(paths) do
      local f = io.open(p .. "/Contents/Info.plist", "r")
      if f then
        f:close()
        return p
      end
    end
    return nil
  end

  vim.keymap.set("n", "<leader>asg", function()
    local app = find_sapgui()
    if app then
      vim.fn.jobstart({ "open", app })
      vim.notify("sap-nvim: Abriendo SAP GUI...")
    else
      vim.notify("sap-nvim: SAP GUI no encontrado", vim.log.levels.ERROR)
    end
  end, { desc = "ABAP: Abrir SAP GUI" })

  vim.keymap.set("n", "<leader>aso", function()
    local app = find_sapgui()
    if app then
      local obj = vim.fn.expand("%:t:r")
      local tx = "SE80"
      vim.fn.jobstart({ "open", app })
      vim.notify(string.format("sap-nvim: SAP GUI abierto. Busca %s en %s", obj, tx))
    else
      vim.notify("sap-nvim: SAP GUI no encontrado", vim.log.levels.ERROR)
    end
  end, { desc = "ABAP: Abrir objeto en SAP GUI" })

  -- Debug: Iniciar depurador ABAP interactivo (vsp)
  vim.keymap.set("n", "<leader>ad", function()
    require("sap-nvim.core.debugger").debug_current()
  end, { desc = "ABAP: Debuggear" })
end

return M
