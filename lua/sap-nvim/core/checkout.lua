-- sap-nvim.core.checkout
-- Download a complete SAP package (with all its objects) to the local filesystem.
-- Wraps: sapcli checkout package <NAME> [dir] [--recursive]

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function do_checkout(pkg, dir, recursive)
  local args = { "sapcli", "checkout", "package", pkg, dir }
  if recursive then table.insert(args, "--recursive") end

  notify("Descargando " .. pkg .. (recursive and " (recursivo)..." or "..."))

  local count  = 0
  local stderr = {}

  vim.fn.jobstart(args, {
    cwd = vim.fn.getcwd(),
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then
          count = count + 1
          -- Show progress every 10 objects so the user knows it's running
          if count % 10 == 0 then
            vim.schedule(function()
              notify("Descargados " .. count .. " objetos...")
            end)
          end
        end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local msg = #stderr > 0 and stderr[1] or "Error en checkout (code " .. code .. ")"
          notify(msg, vim.log.levels.ERROR)
          return
        end

        notify("Paquete " .. pkg .. " descargado — " .. count .. " objetos. Abriendo directorio...")

        local target = vim.fn.getcwd() .. "/" .. dir
        -- oil.nvim if available, otherwise netrw/native directory browse
        local has_oil = pcall(require, "oil")
        if has_oil then
          require("oil").open(target)
        else
          vim.cmd("edit " .. vim.fn.fnameescape(target))
        end
      end)
    end,
  })
end

function M.checkout_package()
  if not adt.is_configured() then
    notify("No hay conexion SAP. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({
    prompt = "Paquete SAP a descargar (ej: ZMYPKG): ",
    default = "Z",
  }, function(pkg)
    if not pkg or pkg == "" then return end
    pkg = pkg:upper()

    vim.ui.input({
      prompt = "Directorio destino: ",
      default = pkg:lower(),
    }, function(dir)
      if not dir or dir == "" then dir = pkg:lower() end

      vim.ui.select(
        { "Solo el paquete raiz", "Recursivo — incluye subpaquetes" },
        { prompt = "Modo de descarga:" },
        function(mode)
          if not mode then return end
          do_checkout(pkg, dir, mode:match("Recursivo") ~= nil)
        end
      )
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapCheckout", function(args)
    if args.args ~= "" then
      -- :SapCheckout ZPKG  — direct invocation with package name
      local pkg = args.args:upper()
      do_checkout(pkg, pkg:lower(), false)
    else
      M.checkout_package()
    end
  end, { desc = "sap-nvim: Descargar paquete SAP completo", nargs = "?" })

  vim.keymap.set("n", "<leader>ack", M.checkout_package, { desc = "ABAP: Checkout paquete SAP" })
end

return M
