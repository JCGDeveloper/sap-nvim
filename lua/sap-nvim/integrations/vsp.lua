-- sap-nvim.integrations.vsp
-- Integración del MCP server vsp para SAP ADT
-- Requiere: vsp compilado en ~/sap-mcp/vsp/

local M = {}

local VSP_PATH = vim.fn.expand("~/sap-mcp/vsp/vsp")

function M.setup(opts)
  opts = opts or {}

  -- Verificar que vsp existe
  local f = io.open(VSP_PATH, "r")
  if not f then return end
  f:close()

  -- Configurar vsp como MCP server para mcphub.nvim
  local ok, mcphub = pcall(require, "mcphub")
  if ok then
    mcphub.setup({
      servers = {
        {
          name = "vsp",
          cmd = { VSP_PATH },
          env = {
            SAP_URL = opts.url or "",
            SAP_USER = opts.user or "",
            SAP_PASSWORD = opts.password or "",
            SAP_CLIENT = opts.client or "100",
          },
        },
      },
    })
  end
end

-- Obtener estado de vsp
function M.status()
  local f = io.open(VSP_PATH, "r")
  if not f then
    return "❌ vsp no compilado. Ejecutá: cd ~/sap-mcp/vsp && go build -o vsp ./cmd/vsp"
  end
  f:close()
  return "✅ vsp listo en " .. VSP_PATH
end

return M
