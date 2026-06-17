-- sap-nvim.core.browser
-- SAP object search and package browser (like Ctrl+Shift+A in Eclipse)

local M = {}
local adt = require("sap-nvim.core.adt")
local source = require("sap-nvim.core.source")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Parsing de filas de resultados.
-- `sapcli abap find` / `sapcli package list -l` devuelven una TABLA en columnas
-- separadas por "|":   Object type | Name | Description
-- con una fila de cabecera y una de guiones. El nombre real es la COLUMNA 2.
-- La columna 1 es el tipo ADT (p.ej. "PROG/I", "CLAS/OC", "PROG/P").

-- Prefijo de tipo ADT -> grupo de sapcli (el que entiende `<group> read`).
-- Nota: PROG/I (include) va a "include", que SÍ soporta read (a diferencia del
-- viejo `checkout`, que no bajaba includes sueltos).
local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class",
  INTF = "interface",
  PROG = "program",
  FUGR = "functiongroup",
  FUGS = "functiongroup",
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

-- Grupo de sapcli implícito en el tipo ADT (o nil si no se reconoce).
-- PROG/I (include de programa) -> "include".
local function type_group(line)
  local prefix, sub = type_token(line):match("(%u+)/(%u+)")
  if not prefix then return nil end
  if prefix == "PROG" and sub == "I" then return "include" end
  return TYPE_PREFIX_TO_GROUP[prefix]
end

-- Resuelve la fila elegida en el picker y abre el objeto remoto leyéndolo de SAP
-- (sapcli <group> read) a la caché local, vía source.open.
local function on_pick(choice)
  if not choice or not is_data_row(choice) then return end
  local obj = extract_name(choice)
  if not obj or obj == "" then return end

  local group = type_group(choice)
  if not group then
    notify("Tipo de objeto no soportado para '" .. obj .. "' (fila: " .. type_token(choice) .. ")",
      vim.log.levels.WARN)
    return
  end
  source.open(obj, group)
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
