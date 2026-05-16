-- sap-nvim.integrations.mcphub
-- Integración con servidores MCP para SAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  local ok, mcphub = pcall(require, "mcphub")
  if not ok then
    -- mcphub no instalado, intentar con avante
    return
  end

  mcphub.setup({
    servers = opts.servers or {
      -- ARC-1: Servidor MCP seguro para SAP ADT
      {
        name = "arc-1",
        cmd = { "node", opts.arc1_path or "~/arc-1/server.js" },
        env = opts.arc1_env or {},
      },
      -- mcp-abap-adt-api: Servidor MCP ligero
      {
        name = "abap-adt",
        cmd = { "node", opts.abap_adt_path or "~/mcp-abap-abap-adt-api/dist/index.js" },
        env = opts.abap_adt_env or {},
      },
    },
  })

  -- Atajo para mostrar herramientas MCP
  vim.keymap.set("n", "<leader>am", function()
    mcphub.show_servers()
  end, { desc = "MCP: Mostrar servidores" })

  -- Atajo para ejecutar herramienta MCP
  vim.keymap.set("n", "<leader>at", function()
    mcphub.show_tools()
  end, { desc = "MCP: Mostrar herramientas" })
end

return M
