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

  -- Servidor MCP de ADT (fr0ster/mcp-abap-adt): CRUD completo + activar/testear/transportes.
  -- Instalado global (`npm i -g @mcp-abap-adt/core` -> binario `mcp-abap-adt` en el PATH) con la
  -- conexión en un .env (modo 600). El MISMO server que ya usa Claude Code.
  local env_path = vim.fn.expand(opts.abap_adt_env_path or "~/.config/mcp-abap-adt/.env")
  mcphub.setup({
    servers = opts.servers or {
      {
        name = "abap-adt",
        cmd = opts.abap_adt_cmd or { "mcp-abap-adt", "--env-path", env_path },
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
