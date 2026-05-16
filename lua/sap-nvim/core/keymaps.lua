-- sap-nvim.core.keymaps
-- Atajos de teclado para desarrollo ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  local adt = require("sap-nvim.core.adt")

  -- <leader>aa: Guardar y activar objeto ABAP remoto
  vim.keymap.set("n", "<leader>aa", function()
    adt.activate_current()
  end, { desc = "ABAP: Guardar y Activar" })

  -- <leader>ac: Ejecutar ATC (ABAP Test Cockpit)
  vim.keymap.set("n", "<leader>ac", function()
    adt.run_atc()
  end, { desc = "ABAP: Ejecutar ATC" })

  -- <leader>au: Ejecutar pruebas unitarias
  vim.keymap.set("n", "<leader>au", function()
    adt.run_aunit()
  end, { desc = "ABAP: Ejecutar AUnit" })

  -- <leader>as: Buscar objetos ABAP
  vim.keymap.set("n", "<leader>as", function()
    vim.ui.input({ prompt = "Buscar objeto ABAP: " }, function(query)
      if query and query ~= "" then
        adt.search(query)
      end
    end)
  end, { desc = "ABAP: Buscar objeto" })

  -- <leader>a1-5: Seleccionar conexión SAP
  if opts.connection_shortcuts ~= false then
    for i = 1, 5 do
      vim.keymap.set("n", ("<leader>a%s"):format(i), function()
        local names = vim.tbl_keys(vim.g.sap_nvim_connections or {})
        if names[i] then
          adt.select_connection(names[i])
        end
      end, { desc = ("ABAP: Conexión %d"):format(i) })
    end
  end

  -- <leader>ai: Abrir terminal con sapcli
  vim.keymap.set("n", "<leader>ai", function()
    vim.cmd("terminal")
    vim.cmd("startinsert")
  end, { desc = "ABAP: Terminal" })

  -- <leader>asg: Abrir SAP GUI (solo la app)
  vim.keymap.set("n", "<leader>asg", function()
    adt.open_gui()
  end, { desc = "ABAP: Abrir SAP GUI" })

  -- <leader>aso: Abrir SAP GUI con el objeto actual
  vim.keymap.set("n", "<leader>aso", function()
    adt.open_gui(nil)
  end, { desc = "ABAP: Abrir objeto en SAP GUI" })
end

return M
