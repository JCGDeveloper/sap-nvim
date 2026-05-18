-- sap-nvim.core.lsp
-- Configuración para ABAP
-- abaplint no tiene modo LSP, se usa como CLI vía :make y <leader>aF

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Verificar abaplint
  local has_abaplint = vim.fn.executable("abaplint") == 1

  -- Configurar makeprg para ABAP (funciona con :make)
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      if has_abaplint then
        vim.bo.makeprg = "abaplint --format json %"
        vim.bo.errorformat = "%-P%f,%E%>%m,%Z%m"
      end
    end,
  })

  if has_abaplint then
    vim.notify("sap-nvim: abaplint listo. <leader>aF para indentar, :make para lint", vim.log.levels.INFO)
  end
end

return M
