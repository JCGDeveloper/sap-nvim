-- sap-nvim.core.browser
-- SAP object search and package browser (like Ctrl+Shift+A in Eclipse)

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Known ABAP file extensions for local lookup
local EXTENSIONS = { "abap", "cls", "intf", "func", "fugr", "tabl", "stru", "dtel", "dome", "ddls", "bdef", "dcl" }

-- Try to open an object locally; if not found, offer checkout.
local function open_or_checkout(obj_name)
  local cwd = vim.fn.getcwd()
  for _, ext in ipairs(EXTENSIONS) do
    local path = cwd .. "/" .. obj_name:lower() .. "." .. ext
    local f = io.open(path, "r")
    if f then
      f:close()
      vim.cmd("edit " .. vim.fn.fnameescape(path))
      return
    end
  end

  vim.ui.select(
    { "Checkout desde el sistema SAP", "Cancelar" },
    { prompt = "'" .. obj_name .. "' no existe localmente:" },
    function(choice)
      if not choice or choice:match("Cancelar") then return end
      -- sapcli needs the object type for a single-object checkout:
      -- `sapcli checkout {class,program,interface,function_group} NAME`.
      vim.ui.select(
        { "class", "program", "interface", "function_group" },
        { prompt = "Tipo de objeto para checkout de " .. obj_name .. ":" },
        function(otype)
          if not otype then return end
          notify("Haciendo checkout de " .. obj_name .. " (" .. otype .. ")...")
          vim.fn.jobstart({ "sapcli", "checkout", otype, obj_name }, {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  notify("Checkout OK: " .. obj_name .. ". Abriendo...")
                  open_or_checkout(obj_name)
                else
                  notify("Checkout fallido para: " .. obj_name, vim.log.levels.ERROR)
                end
              end)
            end,
          })
        end
      )
    end
  )
end

-- Search SAP objects by name pattern (like Ctrl+Shift+A in Eclipse)
function M.search_objects(query)
  local function do_search(q)
    if not adt.is_configured() then
      notify("No hay conexión SAP. Usá :SapSetup primero.", vim.log.levels.WARN)
      return
    end

    notify("Buscando: " .. q)
    adt.fetch_objects(q, function(results, err)
      vim.schedule(function()
        if not results or #results == 0 then
          notify((err or "Sin resultados para: " .. q), vim.log.levels.WARN)
          return
        end

        vim.ui.select(results, {
          prompt = "Objetos SAP (" .. #results .. " resultados para '" .. q .. "'):",
          format_item = function(item) return item end,
        }, function(choice)
          if not choice then return end
          local obj = choice:match("^(%S+)")
          if obj and obj ~= "" then open_or_checkout(obj) end
        end)
      end)
    end)
  end

  if query and query ~= "" then
    do_search(query)
    return
  end

  vim.ui.input({
    prompt = "Buscar objeto SAP (ej: ZCL_*, ZMYCLASS): ",
  }, function(q)
    if q and q ~= "" then do_search(q) end
  end)
end

-- Browse a package's contents
function M.browse_package(pkg_name)
  local function do_browse(pkg)
    if not adt.is_configured() then
      notify("No hay conexión SAP. Usá :SapSetup primero.", vim.log.levels.WARN)
      return
    end

    notify("Explorando paquete: " .. pkg)
    local objects = {}
    local stderr = {}

    vim.fn.jobstart({ "sapcli", "package", "list", "-l", pkg }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          local t = vim.trim(line)
          if t ~= "" then table.insert(objects, t) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stderr, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 or #objects == 0 then
            local msg = #stderr > 0 and stderr[1] or "Paquete vacío o no encontrado: " .. pkg
            notify(msg, vim.log.levels.WARN)
            return
          end

          vim.ui.select(objects, {
            prompt = "Objetos en " .. pkg .. " (" .. #objects .. "):",
            format_item = function(item) return item end,
          }, function(choice)
            if not choice then return end
            local obj = choice:match("^(%S+)")
            if obj and obj ~= "" then open_or_checkout(obj) end
          end)
        end)
      end,
    })
  end

  if pkg_name and pkg_name ~= "" then
    do_browse(pkg_name:upper())
    return
  end

  vim.ui.input({
    prompt = "Nombre del paquete (ej: ZMYPKG): ",
    default = "Z",
  }, function(pkg)
    if pkg and pkg ~= "" then do_browse(pkg:upper()) end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapSearch", function(args)
    M.search_objects(args.args ~= "" and args.args or nil)
  end, { desc = "sap-nvim: Buscar objetos ABAP en el sistema", nargs = "?" })

  vim.api.nvim_create_user_command("SapBrowse", function(args)
    M.browse_package(args.args ~= "" and args.args or nil)
  end, { desc = "sap-nvim: Explorar contenido de un paquete SAP", nargs = "?" })

  vim.keymap.set("n", "<leader>afs", M.search_objects, { desc = "ABAP: Buscar objeto en sistema" })
  vim.keymap.set("n", "<leader>afb", M.browse_package, { desc = "ABAP: Explorar paquete" })
end

return M
