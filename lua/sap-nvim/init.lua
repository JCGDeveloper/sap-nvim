-- sap-nvim: Entry Point
-- Carga los módulos del plugin con manejo de errores

local M = {}

function M.setup(opts)
  opts = opts or {}

  local modules = {
    "sap-nvim.core.treesitter",
    "sap-nvim.core.lsp",
    "sap-nvim.core.keymaps",
    "sap-nvim.adapters.terminal",
  }

  for _, mod in ipairs(modules) do
    local ok, err = pcall(function()
      require(mod).setup(opts)
    end)
    if not ok then
      vim.notify("sap-nvim: " .. mod .. " - " .. tostring(err), vim.log.levels.WARN)
    end
  end

  vim.notify("sap-nvim: Cargado. <leader>ah para ayuda.", vim.log.levels.INFO)
end

return M
