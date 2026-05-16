-- sap-nvim.adapters.terminal
-- Integración con sapcli desde la terminal de Neovim

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Comandos personalizados para ABAP
  vim.api.nvim_create_user_command("SapActivate", function(cmd)
    local object = cmd.args ~= "" and cmd.args or vim.fn.expand("%:t:r")
    vim.fn.jobstart({ "sapcli", "activate", object }, {
      on_exit = function(_, code)
        if code == 0 then
          vim.notify(("✅ %s activado"):format(object))
        else
          vim.notify(("❌ Error activando %s"):format(object), vim.log.levels.ERROR)
        end
      end,
    })
  end, { nargs = "?", desc = "Activar objeto ABAP" })

  vim.api.nvim_create_user_command("SapSearch", function(cmd)
    if cmd.args == "" then
      vim.notify("Uso: SapSearch <query>", vim.log.levels.WARN)
      return
    end
    require("sap-nvim.core.adt").search(cmd.args)
  end, { nargs = 1, desc = "Buscar objetos ABAP" })

  vim.api.nvim_create_user_command("SapConnections", function()
    local connections = vim.g.sap_nvim_connections or {}
    if vim.tbl_isempty(connections) then
      vim.notify("No hay conexiones SAP configuradas")
      return
    end
    local items = vim.iter(connections):map(function(name, config)
      return ("  • %s (%s)"):format(name, config.system_id or "?")
    end):totable()
    vim.notify(table.concat(items, "\n"), "info", { title = "Conexiones SAP" })
  end, { desc = "Listar conexiones SAP" })

  -- Makeprg para ABAP
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      vim.bo.makeprg = "sapcli activate %:t:r"
      vim.bo.errorformat = "%-P%f,%E%>%m,%Z%m"
    end,
  })
end

return M
