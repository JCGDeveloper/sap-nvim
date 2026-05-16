-- sap-nvim: Entry Point
-- Carga todos los módulos del plugin

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Configuración de conexión SAP
  local connections = opts.connections or {}
  vim.g.sap_nvim_connections = connections

  -- Cargar módulos
  require("sap-nvim.core.treesitter").setup(opts.treesitter)
  require("sap-nvim.core.lsp").setup(opts.lsp)
  require("sap-nvim.core.adt").setup({ connections = connections })
  require("sap-nvim.core.keymaps").setup(opts.keymaps)

  -- Adaptadores
  require("sap-nvim.adapters.oil").setup(opts.oil)
  require("sap-nvim.adapters.terminal").setup(opts.terminal)

  -- Integraciones
  require("sap-nvim.integrations.mcphub").setup(opts.mcphub)
  require("sap-nvim.integrations.avante").setup(opts.avante)

  -- Setup interactivo
  require("sap-nvim.core.setup").setup()
end

return M
