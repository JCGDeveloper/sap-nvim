-- sap-nvim.core.preview
-- Previsualización tipo ALV/SE16N de una variable bajo el cursor durante el debug.
-- Distingue ESTRUCTURA (campo|valor) de TABLA (grid filas×columnas). Batchea la lectura de
-- celdas (get_variables acepta lista de parents → 1 sola petición). Robusto: nunca deja
-- "pantalla negra" (siempre hay fallback) y el float es responsivo + se autocierra (q/Esc, wipe).

local M = {}
local dbg = require("sap-nvim.core.debugger")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ── Float ergonómico (ancho/alto según contenido + pantalla; q/Esc cierra; se autodestruye) ──
local function open_float(title, lines)
  if #lines == 0 then lines = { "(sin datos)" } end
  local w = 0
  for _, l in ipairs(lines) do w = math.max(w, vim.fn.strdisplaywidth(l)) end
  w = math.min(math.max(w + 2, #title + 2, 30), math.floor(vim.o.columns * 0.9))
  local h = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.8))
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.bo[buf].bufhidden = "wipe" -- buffer safety: se destruye al ocultarse
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor", width = w, height = h,
    row = math.floor((vim.o.lines - h) / 2 - 1), col = math.floor((vim.o.columns - w) / 2),
    border = "rounded", title = " " .. title .. " ", style = "minimal",
  })
  vim.wo[win].cursorline = true
  for _, k in ipairs({ "q", "<Esc>" }) do
    vim.keymap.set("n", k, "<cmd>close<CR>", { buffer = buf, nowait = true })
  end
  return buf, win
end

-- ── Render ESTRUCTURA: campo : valor (columna de nombres alineada) ──────────────
local function render_struct(name, fields)
  local w = 0
  for _, f in ipairs(fields) do w = math.max(w, #(f.name or "")) end
  local lines = {}
  for _, f in ipairs(fields) do
    lines[#lines + 1] = string.format("%-" .. w .. "s │ %s", f.name or "?", f.value or "")
  end
  open_float("Estructura: " .. name .. "  (" .. #fields .. " campos)", lines)
end

-- ── Render TABLA: grid filas×columnas (auto-anchos). Fallback a lista si no hay columnas ──
local function render_table(name, rows, cells)
  -- Agrupa cada celda en su fila (el ID de la celda empieza por el ID de su fila) y recoge
  -- el orden de columnas (de la 1ª fila que aporte campos).
  local by_row, col_order, seen = {}, {}, {}
  for _, c in ipairs(cells or {}) do
    for _, r in ipairs(rows) do
      if c.id and r.id and #c.id > #r.id and c.id:sub(1, #r.id) == r.id then
        by_row[r.id] = by_row[r.id] or {}
        by_row[r.id][c.name or "?"] = c.value or ""
        if not seen[c.name] then seen[c.name] = true; col_order[#col_order + 1] = c.name or "?" end
        break
      end
    end
  end

  -- Fallback robusto: tabla elemental (filas escalares) o agrupación vacía → lista índice|valor.
  if #col_order == 0 then
    local lines = {}
    for i, r in ipairs(rows) do
      lines[#lines + 1] = string.format("%6d │ %s", i, r.value or r.name or "")
    end
    open_float("Tabla: " .. name .. "  (" .. #rows .. " filas)", lines)
    return
  end

  -- Anchos de columna
  local widths = {}
  for _, col in ipairs(col_order) do widths[col] = #col end
  for _, r in ipairs(rows) do
    local rd = by_row[r.id] or {}
    for _, col in ipairs(col_order) do widths[col] = math.max(widths[col], #tostring(rd[col] or "")) end
  end
  local function fmt(getter)
    local parts = {}
    for _, col in ipairs(col_order) do
      parts[#parts + 1] = string.format("%-" .. widths[col] .. "s", tostring(getter(col) or ""))
    end
    return table.concat(parts, " │ ")
  end

  local lines = { fmt(function(c) return c end) }      -- cabecera
  local sep = {}
  for _, col in ipairs(col_order) do sep[#sep + 1] = string.rep("─", widths[col]) end
  lines[#lines + 1] = table.concat(sep, "─┼─")          -- separador
  for _, r in ipairs(rows) do
    local rd = by_row[r.id] or {}
    lines[#lines + 1] = fmt(function(col) return rd[col] end)
  end
  open_float("Tabla: " .. name .. "  (" .. #rows .. " filas × " .. #col_order .. " cols)", lines)
end

-- ── Entrada: previsualiza la variable bajo el cursor ────────────────────────────
function M.show_alv()
  if not dbg.session then
    notify("No hay sesión de debug activa.", vim.log.levels.WARN)
    return
  end
  local name = vim.fn.expand("<cexpr>")
  if not name or name == "" then return end
  name = name:upper()

  -- get_variables(parent) devuelve los HIJOS del parent (campos si es estructura; filas si
  -- es tabla). Pillar 1: distinguimos por si los hijos son expandibles (filas) o escalares.
  -- 1) Metadata de la variable (getVariables por ID) → META_TYPE / TABLE_LINES.
  dbg.get_vars_by_id(name, function(metas)
    local v = metas and metas[1]
    if not v then
      notify(name .. ": no encontrada en este punto.", vim.log.levels.WARN)
      return
    end

    if v.meta == "table" then
      if (v.table_lines or 0) == 0 then
        open_float("Tabla: " .. name .. " (vacía)", { "(0 filas)" })
        return
      end
      -- 2) Filas: se construyen los IDs ID[1]..ID[N] y se piden con getVariables.
      local row_ids = dbg.table_row_ids(v.id, v.table_lines)
      dbg.get_vars_by_id(row_ids, function(rows)
        local first = rows[1]
        if first and first.expandable then
          -- 3) Celdas de TODAS las filas en UNA llamada (getChildVariables batched).
          dbg.get_variables(row_ids, function(cells)
            render_table(name, rows, cells or {})
          end)
        else
          render_table(name, rows, {}) -- tabla elemental → lista índice|valor (fallback)
        end
      end)
    elseif v.meta == "structure" then
      -- Estructura: sus campos con getChildVariables.
      dbg.get_variables(v.id, function(fields)
        render_struct(name, fields)
      end)
    else
      -- Escalar: mostramos el valor directamente.
      open_float("Variable: " .. name, { (v.name or name) .. " : " .. (v.value or "") })
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapAlvPreview", function() M.show_alv() end,
    { desc = "sap-nvim: Previsualizar variable (ALV/SE16N) en debug" })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_preview", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>dv", function() M.show_alv() end,
        { buffer = ev.buf, desc = "Debug: previsualizar variable (ALV)" })
    end,
  })
end

return M
