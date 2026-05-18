-- sap-nvim.core.lsp
-- Servidores LSP para ABAP
-- Nota: abaplint v2 no tiene modo LSP nativo.
-- Se usa como linter/formateador vía :make y <leader>aF.
-- El diagnóstico LSP se hace con efm-langserver si está disponible.

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Configurar makeprg para ABAP
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      vim.bo.makeprg = "abaplint --format json %"
      vim.bo.errorformat = "%E%f:%l:%c: %m"
    end,
  })

  -- Verificar si abaplint está instalado
  local has_abaplint = vim.fn.executable("abaplint") == 1
  if not has_abaplint then
    vim.notify("sap-nvim: Instalá abaplint: npm install -g @abaplint/cli", vim.log.levels.WARN)
    return
  end

  -- Intentar configurar como LSP (Neovim >= 0.11)
  -- Usa efm-langserver como wrapper si está disponible
  local has_efm = vim.fn.executable("efm-langserver") == 1
  if has_efm then
    vim.lsp.config('abaplint', {
      cmd = {
        "efm-langserver",
        "-c", vim.fn.stdpath("config") .. "/efm-lsp.yaml"
      },
      filetypes = { "abap" },
      root_markers = { ".git" },
    })
    vim.lsp.enable('abaplint')
  end

  vim.notify("sap-nvim: abaplint listo para formatear con <leader>aF y :make", vim.log.levels.INFO)
end

return M
