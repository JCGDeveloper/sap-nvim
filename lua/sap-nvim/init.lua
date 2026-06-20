-- sap-nvim: Entry Point
-- Carga los módulos del plugin con manejo de errores

local M = {}

-- Marcador de versión: para confirmar QUÉ código carga nvim (caché/clon viejo). Súbelo al editar.
M.VERSION = "2026-06-18-T2245-daemonpool-K-ctx-v3"

function M.setup(opts)
  opts = opts or {}

  -- :SapVersion -> versión + de DÓNDE carga el plugin (detecta clon/caché viejos).
  vim.api.nvim_create_user_command("SapVersion", function()
    local src = debug.getinfo(M.setup, "S").source:gsub("^@", "")
    local iok, intel = pcall(require, "sap-nvim.core.intel")
    local isrc = iok and intel.hover and debug.getinfo(intel.hover, "S").source:gsub("^@", "") or "?"
    vim.notify("sap-nvim " .. M.VERSION
      .. "\ninit.lua: " .. src
      .. "\nintel.lua: " .. isrc
      .. "\nK reasignado: " .. tostring(iok and intel.change_include ~= nil), vim.log.levels.INFO)
  end, { desc = "sap-nvim: versión y rutas cargadas (diagnóstico de caché/clon)" })

  local modules = {
    "sap-nvim.core.config",
    "sap-nvim.core.treesitter",
    "sap-nvim.core.formatter",
    "sap-nvim.core.lsp",
    "sap-nvim.core.type_resolver",
    "sap-nvim.core.keymaps",
    "sap-nvim.core.setup",
    "sap-nvim.core.doctor",
    "sap-nvim.core.new",
    "sap-nvim.core.debugger",
    "sap-nvim.core.transport",
    "sap-nvim.core.cts",
    "sap-nvim.core.transaction",
    "sap-nvim.core.gui",
    "sap-nvim.core.favorites",
    "sap-nvim.core.search",
    "sap-nvim.core.templates",
    "sap-nvim.core.include",
    "sap-nvim.core.preview",
    "sap-nvim.core.git",
    "sap-nvim.core.quickfix",
    "sap-nvim.core.source",
    "sap-nvim.core.navigate",
    "sap-nvim.core.intel",
    "sap-nvim.core.message",
    "sap-nvim.core.textsymbol",
    "sap-nvim.core.data",
    "sap-nvim.core.browser",
    "sap-nvim.core.statusline",
    "sap-nvim.core.diff",
    "sap-nvim.core.whereused",
    "sap-nvim.core.checkout",
    "sap-nvim.core.aunit",
    "sap-nvim.core.inactive",
    "sap-nvim.integrations.completion",
    "sap-nvim.integrations.copilot",
    "sap-nvim.integrations.dap",
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
