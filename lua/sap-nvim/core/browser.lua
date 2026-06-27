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

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
local function show(bufname, lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, b, bufname)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- ── ADT directo (Project Explorer estilo Eclipse) ───────────────────────────
-- Migración del browser a la API REST de ADT: más fiable y estructurada que
-- parsear las tablas de texto de `sapcli package list/stat`. Las funciones
-- sapcli de arriba (split_cols/is_data_row/extract_name/type_*/on_pick) se
-- conservan como RUTA DE RESPALDO para sistemas sin ADT.

-- Desescapa las entidades XML básicas.
local function unxml(s)
  if not s then return s end
  return (s:gsub("&lt;", "<"):gsub("&gt;", ">")
    :gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&"))
end

-- Texto de una etiqueta dentro de un bloque, tolerante a prefijos de namespace
-- (p.ej. <OBJECT_NAME> y <n0:OBJECT_NAME> valen igual). nil si no aparece.
local function tag_text(block, tag)
  return block:match("<[^>]-" .. tag .. "[^>]*>(.-)</[^>]-" .. tag .. ">")
end

-- Parsea el XML del endpoint `repository/nodestructure` a filas estructuradas
-- { type, name, uri, description }. El contenedor estándar de cada nodo es
-- <SEU_ADT_REPOSITORY_OBJ_NODE> con hijos OBJECT_TYPE/OBJECT_NAME/OBJECT_URI/
-- DESCRIPTION. Como respaldo, también acepta la forma con <objectReference
-- adtcore:.../> por si algún sistema responde con ese shape.
local function parse_nodestructure(body)
  local rows = {}
  if not body or body == "" then return rows end

  for block in body:gmatch("<[^>]-SEU_ADT_REPOSITORY_OBJ_NODE[^>]*>(.-)</[^>]-SEU_ADT_REPOSITORY_OBJ_NODE>") do
    local name = tag_text(block, "OBJECT_NAME")
    if name and vim.trim(name) ~= "" then
      rows[#rows + 1] = {
        type = vim.trim(unxml(tag_text(block, "OBJECT_TYPE") or "")),
        name = vim.trim(unxml(name)),
        uri = vim.trim(unxml(tag_text(block, "OBJECT_URI") or "")),
        description = vim.trim(unxml(tag_text(block, "DESCRIPTION") or "")),
      }
    end
  end

  if #rows == 0 then
    for attrs in body:gmatch("<[%w]*:?objectReference%s+([^>]*)/?>") do
      local name = attrs:match('adtcore:name%s*=%s*"([^"]*)"')
      if name and name ~= "" then
        rows[#rows + 1] = {
          type = unxml(attrs:match('adtcore:type%s*=%s*"([^"]*)"') or ""),
          name = unxml(name),
          uri = unxml(attrs:match('adtcore:uri%s*=%s*"([^"]*)"') or ""),
          description = unxml(attrs:match('adtcore:description%s*=%s*"([^"]*)"') or ""),
        }
      end
    end
  end

  return rows
end

-- Muestra filas ADT estructuradas en el picker y abre la elegida vía source.open,
-- resolviendo el grupo de sapcli con adt.group_from_adt_type (sin heurística de
-- texto: la fila ADT ya trae el tipo exacto, p.ej. "CLAS/OC").
local function pick_adt_rows(rows, prompt)
  table.sort(rows, function(a, b)
    if a.type == b.type then return a.name < b.name end
    return a.type < b.type
  end)
  vim.ui.select(rows, {
    prompt = prompt,
    format_item = function(r)
      return vim.trim(string.format("%-9s %-32s %s", r.type, r.name, r.description or ""))
    end,
  }, function(r)
    if not r then return end
    local group = adt.group_from_adt_type(r.type)
    if not group then
      notify("Tipo de objeto no soportado: " .. (r.type ~= "" and r.type or "?")
        .. " (" .. r.name .. ")", vim.log.levels.WARN)
      return
    end
    source.open(r.name, group)
  end)
end

-- Extrae el valor de un atributo XML (attr="valor") dentro de `xml`.
local function xml_attr(xml, name)
  if not xml then return nil end
  local v = xml:match(name .. '%s*=%s*"([^"]*)"')
  return v and unxml(v) or nil
end

-- Parsea el XML de `GET /sap/bc/adt/packages/<pkg>` a líneas legibles con los
-- atributos del paquete (descripción, superpaquete, componente software, capa
-- de transporte, responsable, idioma...). Devuelve {} si no reconoce nada.
local function parse_package_info(body, pkg)
  if not body or body == "" then return {} end
  -- Atributos del elemento raíz <...:package ...>.
  local root = body:match("<[%w]*:?package%s+(.-)/?>") or body
  local function line(label, value)
    if value and value ~= "" then return string.format("%-22s %s", label .. ":", value) end
    return nil
  end

  local lines = { "Paquete: " .. (xml_attr(root, "adtcore:name") or pkg), "" }
  local function add(label, value)
    local l = line(label, value)
    if l then lines[#lines + 1] = l end
  end

  add("Descripción", xml_attr(root, "adtcore:description"))
  add("Tipo", xml_attr(root, "adtcore:type"))
  add("Responsable", xml_attr(root, "adtcore:responsible"))
  add("Idioma maestro", xml_attr(root, "adtcore:masterLanguage"))
  add("Tipo de paquete", xml_attr(body:match("<[%w]*:?attributes%s+(.-)/?>") or "", "pak:packageType"))
  add("Superpaquete", xml_attr(body:match("<[%w]*:?superPackage%s+(.-)/?>") or "", "adtcore:name"))
  add("Componente software", xml_attr(body:match("<[%w]*:?softwareComponent%s+(.-)/?>") or "", "pak:name"))
  add("Capa de transporte", xml_attr(body:match("<[%w]*:?transportLayer%s+(.-)/?>") or "", "pak:name"))
  add("Componente aplicación", xml_attr(body:match("<[%w]*:?applicationComponent%s+(.-)/?>") or "", "pak:name"))

  -- Si solo quedó la cabecera, no reconocimos nada útil.
  if #lines <= 2 then return {} end
  return lines
end

-- Info/atributos de un paquete vía sapcli (RESPALDO de package_info).
local function package_info_sapcli(pkg)
  notify("Leyendo info del paquete (sapcli): " .. pkg)
  local stdout, stderr = {}, {}
  vim.fn.jobstart({ "sapcli", "package", "stat", pkg }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stdout, line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #stdout == 0 then
          local msg = #stderr > 0 and stderr[1] or ("No se pudo leer el paquete " .. pkg)
          notify(msg, vim.log.levels.WARN)
          return
        end
        show("sap-package://" .. pkg, stdout)
      end)
    end,
  })
end

-- Explora el contenido de un paquete vía sapcli (RESPALDO de browse_package).
local function browse_package_sapcli(pkg)
  notify("Explorando paquete (sapcli): " .. pkg)
  local objects, stderr = {}, {}
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
          prompt = "Objetos en " .. pkg .. " (" .. #objects .. ", sapcli):",
          format_item = function(item) return item end,
        }, on_pick)
      end)
    end,
  })
end

-- Info/atributos de un paquete. Prefiere ADT (GET /sap/bc/adt/packages/<pkg>);
-- cae a sapcli si ADT no está disponible o no devuelve atributos reconocibles.
function M.package_info(pkg_name)
  local function do_stat(pkg)
    local adt_http = require("sap-nvim.core.adt_http")
    if adt_http.is_available() then
      notify("Leyendo info del paquete (ADT): " .. pkg)
      -- NOTA (validar en vivo): la ruta del paquete va en minúsculas.
      local resp, _, code = adt_http.raw({
        method = "GET",
        path = "/sap/bc/adt/packages/" .. pkg:lower(),
        accept = "application/xml",
      })
      if resp and code and code >= 200 and code < 300 then
        local lines = parse_package_info(resp, pkg)
        if #lines > 0 then
          show("sap-package://" .. pkg, lines)
          return
        end
      end
      notify("ADT no devolvió atributos del paquete; usando sapcli...", vim.log.levels.DEBUG)
    end
    package_info_sapcli(pkg)
  end

  if pkg_name and pkg_name ~= "" then
    do_stat(pkg_name:upper())
    return
  end

  local w = vim.fn.expand("<cword>")
  if w and w ~= "" and w:match("^[%w_/]+$") then
    do_stat(w:upper())
    return
  end

  vim.ui.input({ prompt = "Nombre del paquete (ej: ZMYPKG): ", default = "Z" }, function(pkg)
    if pkg and pkg ~= "" then do_stat(pkg:upper()) end
  end)
end

-- Browse a package's contents
function M.browse_package(pkg_name)
  local function do_browse(pkg)
    if not adt.is_configured() then
      notify("No hay conexion SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
      return
    end

    -- Ruta preferente: ADT directo (nodestructure), estructurado y fiable.
    local adt_http = require("sap-nvim.core.adt_http")
    if adt_http.is_available() then
      notify("Explorando paquete (ADT): " .. pkg)
      -- NOTA (validar en vivo): los params de nodestructure varían entre
      -- sistemas. parent_type=DEVC/K + parent_name=<PKG> es lo habitual; algunos
      -- exigen withShortDescriptions para traer la columna de descripción.
      local resp, _, code = adt_http.raw({
        method = "POST",
        path = "/sap/bc/adt/repository/nodestructure",
        query = {
          parent_type = "DEVC/K",
          parent_name = pkg,
          withShortDescriptions = "true",
        },
        accept = "application/xml",
        content_type = "application/xml",
      })
      if resp and code and code >= 200 and code < 300 then
        local rows = parse_nodestructure(resp)
        if #rows > 0 then
          pick_adt_rows(rows, "Objetos en " .. pkg .. " (" .. #rows .. ", ADT):")
          return
        end
      end
      notify("ADT no devolvió objetos del paquete; usando sapcli...", vim.log.levels.DEBUG)
    end

    -- Respaldo: sapcli (sistemas sin ADT o endpoint no disponible).
    browse_package_sapcli(pkg)
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

  vim.api.nvim_create_user_command("SapPackageInfo", function(args)
    M.package_info(args.args ~= "" and args.args or nil)
  end, { desc = "sap-nvim: Ver info/atributos de un paquete SAP", nargs = "?" })

  vim.keymap.set("n", "<leader>afs", M.search_objects, { desc = "ABAP: Buscar objeto en sistema" })
  vim.keymap.set("n", "<leader>afb", M.browse_package, { desc = "ABAP: Explorar paquete" })
  vim.keymap.set("n", "<leader>afi", function() M.package_info() end, { desc = "ABAP: Info del paquete" })
end

return M
