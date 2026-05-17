-- sap-nvim.adapters.terminal
-- Comandos de terminal para ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Comando de ayuda
  vim.api.nvim_create_user_command("SapConnectionsHelp", function()
    vim.notify([[
sap-nvim - Comandos (requieren sapcli + conexión SAP):

  :SapActivate [obj]  Activar objeto ABAP
  :SapSearch <query>  Buscar objetos

Instalación:
  pip install sapcli (en ~/.sap-nvim-venv/)
  ~/.sap-nvim-venv/bin/sapcli --help

Configura conexión en:
  ~/Desktop/sap-nvim/config/sap-connections.json
    ]], "info", { title = "sap-nvim" })
  end, { desc = "Ayuda de comandos sap-nvim" })
end

return M
