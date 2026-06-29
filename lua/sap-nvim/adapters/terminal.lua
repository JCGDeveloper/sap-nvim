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

Diagnóstico de instalación:
  :checkhealth sap-nvim

Instalación de dependencias:
  pipx install git+https://github.com/jfilak/sapcli.git
  npm install -g @abaplint/cli

Configurar conexión (fuente de verdad: ~/.sapcli/config.yml):
  sapcli config set-connection dev --ashost HOST --port 44300 --client 100 --ssl
  sapcli config set-user me --user SAPUSER
  sapcli config set-context dev --connection dev --user me
  sapcli config use-context dev
  :SapLogin
    ]], "info", { title = "sap-nvim" })
  end, { desc = "Ayuda de comandos sap-nvim" })
end

return M
