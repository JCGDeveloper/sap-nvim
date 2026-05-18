-- sap-nvim.core.keymaps
-- Atajos básicos para ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Ayuda
  vim.keymap.set("n", "<leader>ah", function()
    vim.notify([[
sap-nvim atajos:
  <leader>ah   Ayuda
  <leader>asg  Abrir SAP GUI
  <leader>aso  Abrir objeto en SAP GUI
  <leader>aF   Formatear con abaplint (F mayúscula)

Comandos:
  :SapConnectionsHelp  Ayuda detallada

Instalación:
  npm install -g @abaplint/cli  → LSP ABAP
  :TSInstall abap               → Syntax highlighting
    ]], "info", { title = "sap-nvim" })
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
end

return M
