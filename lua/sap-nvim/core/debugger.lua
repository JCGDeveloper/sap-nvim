-- sap-nvim.core.debugger
-- Integración del depurador ABAP vía vsp
-- Requiere: vsp (MCP_SAP) compilado en ~/sap-mcp/vsp/

local M = {}

local VSP_PATH = vim.fn.expand("~/sap-mcp/vsp/vsp")

function M.check_vsp()
  local f = io.open(VSP_PATH, "r")
  if not f then return false end
  f:close()
  return true
end

-- Iniciar depurador interactivo en terminal de Neovim
function M.debug_terminal(opts)
  opts = opts or {}
  local program = opts.program or vim.fn.expand("%:t:r")
  local line = opts.line or "1"

  if not M.check_vsp() then
    vim.notify("sap-nvim: vsp no encontrado. Ejecutá: cd ~/sap-mcp/vsp && go build -o vsp ./cmd/vsp", vim.log.levels.ERROR)
    return
  end

  -- Abrir terminal de Neovim con vsp debug
  local cmd = string.format("%s debug --program %s --line %s", VSP_PATH, program, line)

  vim.cmd("25vnew")
  vim.bo.buftype = "terminal"
  vim.api.nvim_terminal_open(vim.fn.startjob({ "bash", "-c", cmd }), {})
  vim.cmd("startinsert")

  vim.notify(string.format("sap-nvim: Debugger iniciado en %s:%s", program, line))
end

-- Atajo rápido: debuggear programa actual
function M.debug_current()
  local prog = vim.fn.expand("%:t:r")
  if prog == "" then
    vim.notify("sap-nvim: Guardá el archivo primero", vim.log.levels.WARN)
    return
  end
  M.debug_terminal({ program = prog, line = "1" })
end

return M
