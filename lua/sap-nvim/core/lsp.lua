-- sap-nvim.core.lsp
-- Servidores LSP para ABAP (abaplint) y CDS

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Verificar que abaplint existe
  local has_abaplint = vim.fn.executable("abaplint") == 1
  if not has_abaplint then
    vim.notify("sap-nvim: abaplint no instalado. npm install -g @abaplint/cli", vim.log.levels.WARN)
    return
  end

  -- Configurar abaplint como LSP (Neovim >= 0.11)
  local lsp_ok = pcall(function()
    vim.lsp.config('abaplint', {
      cmd = { 'abaplint', '--format', 'json' },
      filetypes = { 'abap' },
      root_markers = { 'abaplint.json', '.git' },
      settings = {},
    })
    vim.lsp.enable('abaplint')
  end)

  if lsp_ok then
    vim.notify("sap-nvim: abaplint LSP activado", vim.log.levels.INFO)
  else
    vim.notify("sap-nvim: No se pudo configurar abaplint LSP", vim.log.levels.WARN)
  end
end

return M
