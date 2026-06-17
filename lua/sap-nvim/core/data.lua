-- sap-nvim.core.data  (F14)
-- Visualizar tablas: definición DDIC (`sapcli table read`) y datos
-- (`sapcli datapreview osql "SELECT ..." -o human`), renderizando una tabla alineada.

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Buffers scratch creados, indexados por nombre exacto (no usamos vim.fn.bufnr porque
-- interpreta caracteres como '*' como comodín de patrón → bug con "SELECT * FROM ...").
local scratch_bufs = {}

-- Crea (o reusa) un buffer scratch de solo lectura con `lines` y lo muestra.
local function show_scratch(bufname, ft, lines)
  -- Saneamos el nombre: sin '*' ni caracteres raros que rompan el nombre del buffer.
  bufname = bufname:gsub("[^%w_:/%.-]", "_")
  local existing = scratch_bufs[bufname]
  local buf = (existing and vim.api.nvim_buf_is_valid(existing)) and existing
    or vim.api.nvim_create_buf(true, true)
  scratch_bufs[bufname] = buf
  -- Salvaguarda: ninguna línea puede contener '\n' (nvim_buf_set_lines lo rechaza).
  local safe = {}
  for _, l in ipairs(lines) do
    for _, sub in ipairs(vim.split(tostring(l), "\n", { plain = true })) do
      safe[#safe + 1] = sub:gsub("\r", "")
    end
  end
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, safe)
  vim.bo[buf].modifiable = false
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "hide"
  vim.bo[buf].swapfile = false
  if ft then vim.bo[buf].filetype = ft end
  pcall(vim.api.nvim_buf_set_name, buf, bufname)

  -- Mostrar en un SPLIT (no reemplazar el buffer actual), para que `q`/`-`/`:q` cierren la
  -- vista y vuelvan al fichero en el que estabas. Si ya está abierto, reusar su ventana.
  local win = vim.fn.bufwinid(buf)
  if win ~= -1 then
    vim.api.nvim_set_current_win(win)
  else
    vim.cmd("botright split")
    vim.api.nvim_win_set_buf(0, buf)
  end
  pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #safe + 1)))
  vim.wo.wrap = false
  vim.api.nvim_win_set_cursor(0, { 1, 0 })
  -- q / - cierran la vista de datos y vuelven.
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Cerrar datos SAP" })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "Cerrar datos SAP" })
end

-- Renderiza filas (cada una array de celdas) como tabla alineada con box-drawing.
-- rows[1] es la cabecera.
local function render_cells(rows)
  if #rows == 0 then return { "(sin filas)" } end
  -- Sanea las celdas: algunos campos (p.ej. de VBAK) traen saltos de línea/tabs, que
  -- rompen nvim_buf_set_lines ("item contains newlines"). Los sustituimos por un espacio.
  for _, r in ipairs(rows) do
    for i, c in ipairs(r) do r[i] = tostring(c):gsub("[\r\n\t]", " ") end
  end
  local widths = {}
  for _, r in ipairs(rows) do
    for i, c in ipairs(r) do
      widths[i] = math.max(widths[i] or 0, vim.fn.strdisplaywidth(c))
    end
  end
  local function fmt(r)
    local parts = {}
    for i = 1, #widths do
      local c = r[i] or ""
      parts[i] = c .. string.rep(" ", widths[i] - vim.fn.strdisplaywidth(c))
    end
    return table.concat(parts, " │ ")
  end
  local out = { fmt(rows[1]) }
  local seps = {}
  for i = 1, #widths do seps[i] = string.rep("─", widths[i]) end
  out[#out + 1] = table.concat(seps, "─┼─")
  for i = 2, #rows do out[#out + 1] = fmt(rows[i]) end
  return out
end

-- Orden de columnas a partir del texto crudo JSON (las claves del primer objeto en orden
-- de aparición), porque vim.json.decode pierde el orden de las claves.
local function column_order(raw)
  local cols, seen = {}, {}
  local first = raw:match("%b{}")
  if first then
    for key in first:gmatch('"([^"]+)"%s*:') do
      if not seen[key] then seen[key] = true; cols[#cols + 1] = key end
    end
  end
  return cols, seen
end

-- Ejecuta OpenSQL (-o json) y muestra los datos en una tabla alineada. JSON evita la
-- desalineación de `-o human` (que omite celdas vacías de forma inconsistente).
function M.preview(sql, rows)
  if not adt.is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end
  rows = rows or require("sap-nvim.core.config").data().rows or 100
  notify("Consultando: " .. sql .. " (máx " .. rows .. " filas)...")

  -- IMPORTANTE: vim.fn.system() (síncrono), NO jobstart: `datapreview osql` SE CUELGA vía
  -- jobstart (proceso colgado para siempre), pero con system() responde bien. Bloquea
  -- brevemente, aceptable para una consulta on-demand con --rows limitado.
  local raw = vim.fn.system({ "sapcli", "datapreview", "osql", sql, "--rows", tostring(rows), "-o", "json" })
  local ok, decoded = pcall(vim.json.decode, raw)
  if vim.v.shell_error ~= 0 or not ok or type(decoded) ~= "table" then
    -- Mostrar el motivo COMPLETO (la 1ª línea suele ser "Exception (ADTError): <detalle>").
    notify("Consulta fallida: " .. vim.trim(raw):sub(1, 400), vim.log.levels.ERROR)
    return
  end
  if #decoded == 0 then notify("Sin filas para: " .. sql); return end

  local cols, seen = column_order(raw)
  for _, row in ipairs(decoded) do  -- añadir columnas extra que no salieran en la 1ª
    for k in pairs(row) do if not seen[k] then seen[k] = true; cols[#cols + 1] = k end end
  end

  local cells = { cols }
  for _, row in ipairs(decoded) do
    local vals = {}
    for i, c in ipairs(cols) do
      local v = row[c]
      vals[i] = (v ~= nil) and tostring(v) or ""
    end
    cells[#cells + 1] = vals
  end

  local lines = { "-- " .. sql .. "  (" .. #decoded .. " filas, máx " .. rows .. ")", "" }
  vim.list_extend(lines, render_cells(cells))
  show_scratch("sap-data://" .. sql:gsub("%s+", "_"):sub(1, 40), nil, lines)
end

-- Atajo: datos de una tabla -> SELECT * FROM NAME.
function M.preview_table(name)
  M.preview("SELECT * FROM " .. name:upper())
end

-- Datos de la TABLA/ENTIDAD bajo el cursor (cword). Si no hay palabra, pregunta.
function M.preview_cursor()
  local w = vim.fn.expand("<cword>")
  if w and w:match("^[%w_/]+$") then
    M.preview_table(w)
  else
    vim.ui.input({ prompt = "Tabla (datos): " }, function(v) if v and v ~= "" then M.preview_table(v) end end)
  end
end

-- Previsualiza los datos del SELECT bajo el cursor. Extrae el statement (multi-línea hasta
-- el punto), quita el `INTO ...` y, si hay variables de host (@s_curso, @var), quita el
-- WHERE (no se pueden evaluar fuera del programa) y avisa. Ejecuta el resto con osql.
function M.preview_select()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local row = vim.api.nvim_win_get_cursor(0)[1]

  -- inicio: hacia atrás hasta una línea con SELECT
  local s = row
  while s > 1 and not lines[s]:upper():match("%f[%w]SELECT%f[%W]") do s = s - 1 end
  if not (lines[s] or ""):upper():match("%f[%w]SELECT%f[%W]") then
    notify("No hay un SELECT bajo el cursor.", vim.log.levels.WARN); return
  end
  -- fin: hacia delante hasta una línea que acabe en '.'
  local e = row
  while e < #lines and not lines[e]:match("%.%s*$") do e = e + 1 end

  local sub = {}
  for i = s, e do sub[#sub + 1] = lines[i] end
  local stmt = table.concat(sub, " ")
  -- Empezar en SELECT (descarta lo de antes) y cortar en el primer punto: un statement
  -- OpenSQL no tiene puntos dentro (campos/tablas/host-vars no llevan '.'), así garantizamos
  -- que NO llegue ningún '.' a osql ("'.' is invalid here").
  stmt = stmt:match("[Ss][Ee][Ll][Ee][Cc][Tt].*") or stmt
  stmt = stmt:match("^([^.]*)") or stmt
  stmt = stmt:gsub("[Ii][Nn][Tt][Oo]%s.*$", "")  -- quita INTO ...
  if stmt:find("@") then
    stmt = stmt:gsub("[Ww][Hh][Ee][Rr][Ee]%s.*$", "") -- filtros con host-vars no evaluables
    notify("Filtros con variables (@) omitidos en la preview.", vim.log.levels.WARN)
  end
  stmt = vim.trim(stmt:gsub("%s+", " "))
  if not stmt:upper():match("^SELECT") then notify("No se pudo extraer el SELECT.", vim.log.levels.WARN); return end
  M.preview(stmt)
end

-- Prefijo de tipo ADT (de `abap find`) -> grupo de sapcli para leer la definición.
local TYPE_TO_GROUP = {
  TABL = "table", DDLS = "ddl", STRU = "structure", DTEL = "dataelement", DOMA = "domain",
}

-- Lee y muestra la definición de `group`/`real_name`.
local function read_and_show(group, real_name)
  local out = {}
  vim.fn.jobstart({ "sapcli", group, "read", real_name }, {
    on_stdout = function(_, data) for _, l in ipairs(data) do out[#out + 1] = l end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #out == 0 or (out[1] or ""):match("Exception") then
          notify("No se pudo leer " .. real_name .. " (" .. group .. ").", vim.log.levels.ERROR)
          return
        end
        if out[#out] == "" then table.remove(out) end
        show_scratch("sap-def://" .. real_name, "abap", out)
      end)
    end,
  })
end

-- Muestra la definición de tabla / CDS / estructura / data element / dominio. Resuelve el
-- tipo y el NOMBRE REAL con `abap find` (clave para CDS: el nombre de la entidad
-- -p.ej. ZCDS_JCG_CALE- difiere del DDL source -ZCDS_JCG_CALENDARIO-).
function M.read_definition(name)
  if not adt.is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end
  name = name:upper()
  notify("Resolviendo " .. name .. "...")
  local rows = {}
  vim.fn.jobstart({ "sapcli", "abap", "find", name }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l:find("|") and not l:find("Object type") then
          local cols = {}
          for c in (l .. "|"):gmatch("%s*(.-)%s*|") do cols[#cols + 1] = c end
          local prefix = (cols[1] or ""):match("^(%u+)")
          if prefix and cols[2] and cols[2] ~= "" then
            rows[#rows + 1] = { prefix = prefix, name = cols[2], group = TYPE_TO_GROUP[prefix] }
          end
        end
      end
    end,
    on_exit = function(_, _code)
      vim.schedule(function()
        -- 1) coincidencia exacta de nombre con tipo leíble.
        for _, r in ipairs(rows) do
          if r.group and r.name:upper() == name then return read_and_show(r.group, r.name) end
        end
        -- 2) CDS: si el nombre exacto era la entidad, leer el primer DDL source.
        for _, r in ipairs(rows) do
          if r.group == "ddl" then return read_and_show("ddl", r.name) end
        end
        -- 3) primer objeto leíble.
        for _, r in ipairs(rows) do
          if r.group then return read_and_show(r.group, r.name) end
        end
        notify("No se encontró definición para " .. name .. " (tabla/CDS/estructura/...).", vim.log.levels.WARN)
      end)
    end,
  })
end

-- Alias para compatibilidad.
M.read_table = M.read_definition

-- Definición del objeto bajo el cursor (cword) o pregunta.
function M.read_definition_cursor()
  local w = vim.fn.expand("<cword>")
  if w and w:match("^[%w_/]+$") then
    M.read_definition(w)
  else
    vim.ui.input({ prompt = "Objeto (definición): " }, function(v) if v and v ~= "" then M.read_definition(v) end end)
  end
end

local function prompt(msg, default, cb)
  vim.ui.input({ prompt = msg, default = default }, function(v)
    if v and v ~= "" then cb(v) end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapTable", function(a)
    if a.args ~= "" then M.read_definition(a.args) else M.read_definition_cursor() end
  end, { desc = "sap-nvim: Ver definición de tabla/CDS/estructura (cursor)", nargs = "?" })

  vim.api.nvim_create_user_command("SapTableData", function(a)
    if a.args ~= "" then M.preview_table(a.args) else M.preview_cursor() end
  end, { desc = "sap-nvim: Ver datos de una tabla (cursor o SELECT *)", nargs = "?" })

  vim.api.nvim_create_user_command("SapData", function(a)
    if a.args ~= "" then M.preview(a.args) else prompt("OpenSQL (sin punto): ", "SELECT * FROM ", M.preview) end
  end, { desc = "sap-nvim: Ejecutar OpenSQL y ver resultados", nargs = "?" })

  vim.api.nvim_create_user_command("SapSelectPreview", function() M.preview_select() end,
    { desc = "sap-nvim: Previsualizar el SELECT bajo el cursor (quita INTO y filtros @)" })

  vim.keymap.set("n", "<leader>avt", function() M.read_definition_cursor() end,
    { desc = "ABAP: Ver definición (tabla/CDS/estructura) bajo el cursor" })
  -- Datos de la tabla bajo el cursor (o pregunta si no hay palabra).
  vim.keymap.set("n", "<leader>avd", function() M.preview_cursor() end,
    { desc = "ABAP: Ver datos de la tabla bajo el cursor" })
  vim.keymap.set("n", "<leader>avq", function()
    prompt("OpenSQL (sin punto): ", "SELECT * FROM ", M.preview)
  end, { desc = "ABAP: Ejecutar OpenSQL" })
  vim.keymap.set("n", "<leader>avs", function() M.preview_select() end,
    { desc = "ABAP: Previsualizar el SELECT bajo el cursor" })
  -- Nota: en buffers ABAP, <leader>avd lo mapea keymaps.lua (buffer-local) a :SapTableData,
  -- que ahora usa la tabla bajo el cursor.
end

return M
