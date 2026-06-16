-- sap-nvim.core.browser
-- SAP object search and package browser (like Ctrl+Shift+A in Eclipse)

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Known ABAP file extensions for local lookup
local EXTENSIONS = { "abap", "cls", "intf", "func", "fugr", "tabl", "stru", "dtel", "dome", "ddls", "bdef", "dcl" }

-- ── Parsing de filas de resultados ──────────────────────────────────────────
-- `sapcli abap find` y `sapcli package list -l` devuelven filas que EMPIEZAN
-- por el tipo ADT (p.ej. "PROG/I", "CLAS/OC", "INTF/OI"). El nombre real es el
-- primer token SIN "/" (ni los tipos ADT ni las URIs son nombres válidos).

-- Tipos de checkout que sapcli soporta como objeto suelto.
local CHECKOUTABLE = { class = true, program = true, interface = true, function_group = true }

-- Prefijo de tipo ADT → grupo de objeto de sapcli.
local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class",
  INTF = "interface",
  PROG = "program",
  FUGR = "function_group",
  FUGS = "function_group",
}

-- Nombre del objeto a partir de una fila de resultados.
local function extract_name(line)
  for tok in line:gmatch("%S+") do
    if not tok:find("/") then return tok end
  end
  return line:match("^(%S+)")
end

-- Grupo de checkout implícito en el token de tipo ADT (o nil si no aplica).
-- Los includes (PROG/I) NO se pueden bajar sueltos → devuelve nil.
local function type_group(line)
  local prefix, sub = line:match("^(%u+)/(%u+)")
  if not prefix then return nil end
  if prefix == "PROG" and sub == "I" then return nil end -- include
  return TYPE_PREFIX_TO_GROUP[prefix]
end

-- Try to open an object locally; if not found, offer checkout.
-- `hint_group` (opcional) es el grupo de checkout ya derivado del tipo ADT.
local function open_or_checkout(obj_name, hint_group)
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

  local function do_checkout(otype)
    if not otype then return end
    notify("Haciendo checkout de " .. obj_name .. " (" .. otype .. ")...")
    vim.fn.jobstart({ "sapcli", "checkout", otype, obj_name }, {
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then
            notify("Checkout OK: " .. obj_name .. ". Abriendo...")
            open_or_checkout(obj_name)
          else
            notify("Checkout fallido para: " .. obj_name .. " (" .. otype .. ")", vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end

  vim.ui.select(
    { "Checkout desde el sistema SAP", "Cancelar" },
    { prompt = "'" .. obj_name .. "' no existe localmente:" },
    function(choice)
      if not choice or choice:match("Cancelar") then return end
      -- Si ya sabemos el tipo (derivado del token ADT) y es checkout-able,
      -- lo usamos directamente y nos saltamos el menú manual.
      if hint_group and CHECKOUTABLE[hint_group] then
        do_checkout(hint_group)
        return
      end
      -- Si no, pedimos el tipo (incluye el caso de includes/tipos no soportados).
      vim.ui.select(
        { "class", "program", "interface", "function_group" },
        { prompt = "Tipo de objeto para checkout de " .. obj_name .. ":" },
        do_checkout
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
          local obj = extract_name(choice)
          if obj and obj ~= "" then open_or_checkout(obj, type_group(choice)) end
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
            local obj = extract_name(choice)
            if obj and obj ~= "" then open_or_checkout(obj, type_group(choice)) end
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
