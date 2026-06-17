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

  local out, err = {}, {}
  local finished = false
  local job = vim.fn.jobstart({ "sapcli", "datapreview", "osql", sql, "--rows", tostring(rows), "-o", "json" }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do out[#out + 1] = l end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do if vim.trim(l) ~= "" then err[#err + 1] = vim.trim(l) end end
    end,
    on_exit = function(_, code)
      finished = true
      vim.schedule(function()
        if code == 143 then
          notify("Consulta cancelada por timeout (SAP no respondió a tiempo).", vim.log.levels.WARN)
          return
        end
        local raw = table.concat(out, "\n")
        local ok, decoded = pcall(vim.json.decode, raw)
        if code ~= 0 or not ok or type(decoded) ~= "table" then
          notify("Consulta fallida: " .. (err[1] or raw:sub(1, 120)), vim.log.levels.ERROR)
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
      end)
    end,
  })

  -- Timeout: si sapcli/SAP no responde, matar el job para no colgar la consulta.
  vim.defer_fn(function()
    if not finished and job and job > 0 then pcall(vim.fn.jobstop, job) end
  end, 25000)
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

-- Muestra la definición DDIC de una tabla/estructura/data element/dominio.
function M.read_table(name)
  if not adt.is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end
  name = name:upper()
  notify("Leyendo definición de " .. name .. "...")
  local out, err = {}, {}
  vim.fn.jobstart({ "sapcli", "table", "read", name }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do out[#out + 1] = l end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do if vim.trim(l) ~= "" then err[#err + 1] = vim.trim(l) end end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #out == 0 then
          notify("No se pudo leer " .. name .. ": " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR)
          return
        end
        if out[#out] == "" then table.remove(out) end
        show_scratch("sap-table://" .. name, "abap", out)
      end)
    end,
  })
end

local function prompt(msg, default, cb)
  vim.ui.input({ prompt = msg, default = default }, function(v)
    if v and v ~= "" then cb(v) end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapTable", function(a)
    if a.args ~= "" then M.read_table(a.args) else prompt("Tabla (definición DDIC): ", "", M.read_table) end
  end, { desc = "sap-nvim: Ver definición DDIC de una tabla", nargs = "?" })

  vim.api.nvim_create_user_command("SapTableData", function(a)
    if a.args ~= "" then M.preview_table(a.args) else prompt("Tabla (datos): ", "", M.preview_table) end
  end, { desc = "sap-nvim: Ver datos de una tabla (SELECT *)", nargs = "?" })

  vim.api.nvim_create_user_command("SapData", function(a)
    if a.args ~= "" then M.preview(a.args) else prompt("OpenSQL (sin punto): ", "SELECT * FROM ", M.preview) end
  end, { desc = "sap-nvim: Ejecutar OpenSQL y ver resultados", nargs = "?" })

  vim.keymap.set("n", "<leader>avt", function()
    prompt("Tabla (definición DDIC): ", "", M.read_table)
  end, { desc = "ABAP: Ver definición de tabla" })
  -- Datos de la tabla bajo el cursor (o pregunta si no hay palabra).
  vim.keymap.set("n", "<leader>avd", function() M.preview_cursor() end,
    { desc = "ABAP: Ver datos de la tabla bajo el cursor" })
  vim.keymap.set("n", "<leader>avq", function()
    prompt("OpenSQL (sin punto): ", "SELECT * FROM ", M.preview)
  end, { desc = "ABAP: Ejecutar OpenSQL" })

  -- En buffers ABAP, atajo directo gd-style: <leader>av sobre una tabla -> sus datos.
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_data", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>avd", function() M.preview_cursor() end,
        { buffer = ev.buf, desc = "ABAP: Datos de la tabla bajo el cursor" })
    end,
  })
end

return M
