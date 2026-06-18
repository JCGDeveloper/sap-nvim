-- sap-nvim.core.transport
-- CTS transport order management: list, create, release

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function extract_id(line)
  return line:match("%u%u%uK%d+") or line:match("^(%S+)")
end

-- Show picker of open transport orders; <cr> copies the ID to the clipboard.
function M.list_transports()
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes de transporte abiertas."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Órdenes de transporte abiertas (Enter = copiar ID):",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if id then
          vim.fn.setreg("+", id)
          notify("Copiado al portapapeles: " .. id)
        end
      end)
    end)
  end)
end

-- Create a new workbench transport order
function M.create_transport()
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({
    prompt = "Descripción de la orden de transporte: ",
  }, function(desc)
    if not desc or desc == "" then return end

    notify("Creando orden de transporte...")
    local stdout = {}
    local stderr = {}

    vim.fn.jobstart({ "sapcli", "cts", "create", "transport", desc }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stdout, line) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stderr, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 and #stdout > 0 then
            local id = extract_id(stdout[1]) or stdout[1]
            vim.fn.setreg("+", id)
            notify("Orden creada: " .. id .. " (copiada al portapapeles)")
          else
            local msg = #stderr > 0 and stderr[1] or ("Error creando transporte (code " .. code .. ")")
            notify(msg, vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end)
end

-- Release a transport order (shows picker first)
function M.release_transport()
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes abiertas para liberar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden a LIBERAR (irreversible):",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if not id then return end

        vim.ui.select({ "Cancelar", "Si, liberar " .. id }, {
          prompt = "Confirmar liberacion (irreversible):",
        }, function(confirm)
          if not confirm or not confirm:match("^Si") then return end

          notify("Liberando " .. id .. "...")
          vim.fn.jobstart({ "sapcli", "cts", "release", id }, {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  notify("Orden liberada: " .. id)
                else
                  notify("Error liberando " .. id, vim.log.levels.ERROR)
                end
              end)
            end,
          })
        end)
      end)
    end)
  end)
end

-- Borrar una orden de transporte (muestra selector y confirma; §7 destructivo)
function M.delete_transport()
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes abiertas para borrar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden a BORRAR (irreversible):",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if not id then return end

        vim.ui.select({ "No", "Sí, borrar " .. id }, {
          prompt = "Confirmar borrado (irreversible):",
        }, function(confirm)
          if not confirm or not confirm:match("^Sí") then return end

          notify("Borrando " .. id .. "...")
          vim.fn.jobstart({ "sapcli", "cts", "delete", "transport", id }, {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  notify("Orden borrada: " .. id)
                else
                  notify("Error borrando " .. id, vim.log.levels.ERROR)
                end
              end)
            end,
          })
        end)
      end)
    end)
  end)
end

-- Reasignar una orden de transporte a otro owner
function M.reassign_transport()
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes abiertas para reasignar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden a REASIGNAR:",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if not id then return end

        vim.ui.input({ prompt = "Nuevo owner para " .. id .. ": " }, function(owner)
          if not owner or vim.trim(owner) == "" then return end
          owner = vim.trim(owner)

          notify("Reasignando " .. id .. " a " .. owner .. "...")
          vim.fn.jobstart({ "sapcli", "cts", "reassign", "transport", id, owner }, {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  notify("Orden " .. id .. " reasignada a " .. owner)
                else
                  notify("Error reasignando " .. id, vim.log.levels.ERROR)
                end
              end)
            end,
          })
        end)
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapTransports", function()
    M.list_transports()
  end, { desc = "sap-nvim: Listar ordenes de transporte" })

  vim.api.nvim_create_user_command("SapTransportCreate", function()
    M.create_transport()
  end, { desc = "sap-nvim: Crear orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportRelease", function()
    M.release_transport()
  end, { desc = "sap-nvim: Liberar orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportDelete", function()
    M.delete_transport()
  end, { desc = "sap-nvim: Borrar orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportReassign", function()
    M.reassign_transport()
  end, { desc = "sap-nvim: Reasignar orden de transporte" })

  vim.keymap.set("n", "<leader>atl", M.list_transports,    { desc = "ABAP: Listar transportes" })
  vim.keymap.set("n", "<leader>atc", M.create_transport,   { desc = "ABAP: Crear transporte" })
  vim.keymap.set("n", "<leader>atr", M.release_transport,  { desc = "ABAP: Liberar transporte" })
  vim.keymap.set("n", "<leader>atd", M.delete_transport,   { desc = "ABAP: Borrar transporte" })
  vim.keymap.set("n", "<leader>ato", M.reassign_transport, { desc = "ABAP: Reasignar transporte (owner)" })
end

return M
