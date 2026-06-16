-- sap-nvim.core.browser
-- SAP object search and package browser (like Ctrl+Shift+A in Eclipse)

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Known ABAP file extensions for local lookup
local EXTENSIONS = { "abap", "cls", "intf", "func", "fugr", "tabl", "stru", "dtel", "dome", "ddls", "bdef", "dcl" }

-- Parsing de filas de resultados.
-- `sapcli abap find` / `sapcli package list -l` devuelven una TABLA en columnas
-- separadas por "|":   Object type | Name | Description
-- con una fila de cabecera y una de guiones. El nombre real es la COLUMNA 2.
-- La columna 1 es el tipo ADT (p.ej. "PROG/I", "CLAS/OC", "PROG/P").

-- Tipos de checkout que sapcli soporta como objeto suelto.
local CHECKOUTABLE = { class = true, program = true, interface = true, function_group = true }

-- Prefijo de tipo ADT -> grupo de objeto de sapcli.
local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class",
  INTF = "interface",
  PROG = "program",
  FUGR = "function_group",
  FUGS = "function_group",
}

-- Divide "a | b | c" en columnas, con trim de cada una.
local function split_cols(line)
  local cols = {}
  for c in (line .. "|"):gmatch("%s*(.-)%s*|") do
    table.insert(cols, c)
  end
  return cols
end

-- Descarta cabecera ("Object type | Name | ...") y filas separadoras ("----").
local function is_data_row(line)
  if not line or line == "" then return false end
  if line:match("^%s*[-|%s]*$") then return false end
  if line:find("Object type") then return false end
  return true
end

-- Nombre del objeto a partir de una fila. Columna 2 si hay formato de tabla;
-- si no, el primer token que no sea un tipo ADT (con "/") ni un "|".
local function extract_name(line)
  if line:find("|") then
    local cols = split_cols(line)
    if cols[2] and cols[2] ~= "" and cols[2] ~= "Name" then return cols[2] end
  end
  for tok in line:gmatch("%S+") do
    if not tok:find("/") and tok ~= "|" then return tok end
  end
  return nil
end

-- Token de tipo ADT (columna 1) de una fila, p.ej. "PROG/I".
local function type_token(line)
  if line:find("|") then return (split_cols(line)[1] or "") end
  return line:match("^(%S+)") or ""
end

-- True si la fila es un include de programa (PROG/I): no se baja suelto.
local function is_include(line)
  return type_token(line):match("^PROG/I") ~= nil
end

-- Grupo de checkout implicito en el tipo ADT (o nil si no aplica / es include).
local function type_group(line)
  local prefix, sub = type_token(line):match("(%u+)/(%u+)")
  if not prefix then return nil end
  if prefix == "PROG" and sub == "I" then return nil end
  return TYPE_PREFIX_TO_GROUP[prefix]
end

-- Try to open an object locally; if not found, offer checkout.
local function open_or_checkout(obj_name, hint_group, include)
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

  if include then
    notify(
      "'" .. obj_name .. "' es un INCLUDE de programa: sapcli no lo baja suelto. "
        .. "Baja el programa padre (fila PROG/P) o usa :SapCheckout sobre el paquete.",
      vim.log.levels.WARN
    )
    return
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
      if hint_group and CHECKOUTABLE[hint_group] then
        do_checkout(hint_group)
        return
      end
      vim.ui.select(
        { "class", "program", "interface", "function_group" },
        { prompt = "Tipo de objeto para checkout de " .. obj_name .. ":" },
        do_checkout
      )
    end
  )
end

-- Resuelve la fila elegida en el picker y dispara open_or_checkout.
local function on_pick(choice)
  if not choice or not is_data_row(choice) then return end
  local obj = extract_name(choice)
  if obj and obj ~= "" then
    open_or_checkout(obj, type_group(choice), is_include(choice))
  end
end

-- Search SAP objects by name pattern (like Ctrl+Shift+A in Eclipse)
function M.search_objects(query)
  local function do_search(q)
    if not adt.is_configured() then
      notify("No hay conexion SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
      return
    end

    notify("Buscando: " .. q)
    adt.fetch_objects(q, function(results, err)
      vim.schedule(function()
        if not results or #results == 0 then
          notify((err or "Sin resultados para: " .. q), vim.log.levels.WARN)
          return
        end

        results = vim.tbl_filter(is_data_row, results)
        if #results == 0 then
          notify("Sin resultados para: " .. q, vim.log.levels.WARN)
          return
        end

        vim.ui.select(results, {
          prompt = "Objetos SAP (" .. #results .. " resultados para '" .. q .. "'):",
          format_item = function(item) return item end,
        }, on_pick)
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
      notify("No hay conexion SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
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
            local msg = #stderr > 0 and stderr[1] or "Paquete vacio o no encontrado: " .. pkg
            notify(msg, vim.log.levels.WARN)
            return
          end

          objects = vim.tbl_filter(is_data_row, objects)
          if #objects == 0 then
            notify("Paquete vacio: " .. pkg, vim.log.levels.WARN)
            return
          end

          vim.ui.select(objects, {
            prompt = "Objetos en " .. pkg .. " (" .. #objects .. "):",
            format_item = function(item) return item end,
          }, on_pick)
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
