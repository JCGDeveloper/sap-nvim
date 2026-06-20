-- lua/sap-nvim/core/preview.lua
-- Previsualización tipo ALV/SE16N de una variable bajo el cursor durante el debug.
-- Distingue ESTRUCTURA (campo|valor) de TABLA (grid filas×columnas).
-- Batchea la lectura de celdas y usa un renderizado seguro a prueba de fallos.

local M = {}
local dbg = require("sap-nvim.core.debugger")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ── Float ergonómico (ancho/alto según contenido; q/Esc cierra; se autodestruye) ──
local function open_float(title, lines)
	if #lines == 0 then
		lines = { "(sin datos)" }
	end
	local w = 0
	for _, l in ipairs(lines) do
		w = math.max(w, vim.fn.strdisplaywidth(l))
	end
	w = math.min(math.max(w + 2, #title + 2, 30), math.floor(vim.o.columns * 0.9))
	local h = math.min(math.max(#lines, 1), math.floor(vim.o.lines * 0.8))

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
	vim.bo[buf].bufhidden = "wipe" -- Se destruye al cerrarse

	local win = vim.api.nvim_open_win(buf, true, {
		relative = "editor",
		width = w,
		height = h,
		row = math.floor((vim.o.lines - h) / 2 - 1),
		col = math.floor((vim.o.columns - w) / 2),
		border = "rounded",
		title = " " .. title .. " ",
		style = "minimal",
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
	for _, f in ipairs(fields) do
		w = math.max(w, #(f.name or ""))
	end
	local lines = {}
	for _, f in ipairs(fields) do
		lines[#lines + 1] = string.format("%-" .. w .. "s │ %s", f.name or "?", f.value or "")
	end
	open_float("Estructura: " .. name .. "  (" .. #fields .. " campos)", lines)
end

-- ── Render TABLA: grid filas×columnas (auto-anchos) y Filtro ────────────────────
local function render_table(name, rows, cells, filter_user)
	local by_row, col_order, seen = {}, {}, {}
	for _, c in ipairs(cells or {}) do
		for _, r in ipairs(rows) do
			if c.id and r.id and #c.id > #r.id and c.id:sub(1, #r.id) == r.id then
				by_row[r.id] = by_row[r.id] or {}
				by_row[r.id][c.name or "?"] = c.value or ""
				if not seen[c.name] then
					seen[c.name] = true
					col_order[#col_order + 1] = c.name or "?"
				end
				break
			end
		end
	end

	-- Filtro: "Solo Mías"
	local filtered_rows = {}
	for _, r in ipairs(rows) do
		local rd = by_row[r.id] or {}
		if filter_user then
			local belongs_to_me = false
			for _, col in ipairs(col_order) do
				local val = tostring(rd[col] or ""):upper()
				if val == filter_user:upper() then
					belongs_to_me = true
					break
				end
			end
			if belongs_to_me then
				table.insert(filtered_rows, r)
			end
		else
			table.insert(filtered_rows, r)
		end
	end
	rows = filtered_rows

	-- Fallback: tabla vacía tras filtrar o sin columnas
	if #col_order == 0 or #rows == 0 then
		local lines = {}
		for i, r in ipairs(rows) do
			lines[#lines + 1] = string.format("%6d │ %s", i, r.value or r.name or "")
		end
		local title = "Tabla: " .. name .. "  (" .. #rows .. " filas)"
		if filter_user then
			title = title .. " [FILTRO: " .. filter_user .. "]"
		end
		open_float(title, lines)
		return
	end

	-- Calcular anchos
	local widths = {}
	for _, col in ipairs(col_order) do
		widths[col] = #col
	end
	for _, r in ipairs(rows) do
		local rd = by_row[r.id] or {}
		for _, col in ipairs(col_order) do
			widths[col] = math.max(widths[col], #tostring(rd[col] or ""))
		end
	end

	-- FIX: Formateador ultra-seguro (Adiós al crash)
	local function pad(s, width)
		s = tostring(s or "")
		if #s >= width then
			return s
		end
		return s .. string.rep(" ", width - #s)
	end

	local function fmt(getter)
		local parts = {}
		for _, col in ipairs(col_order) do
			parts[#parts + 1] = pad(getter(col), widths[col])
		end
		return table.concat(parts, " │ ")
	end

	-- Construir líneas de la tabla
	local lines = { fmt(function(c)
		return c
	end) }
	local sep = {}
	for _, col in ipairs(col_order) do
		sep[#sep + 1] = string.rep("─", widths[col])
	end
	lines[#lines + 1] = table.concat(sep, "─┼─")
	for _, r in ipairs(rows) do
		local rd = by_row[r.id] or {}
		lines[#lines + 1] = fmt(function(col)
			return rd[col]
		end)
	end

	local title = "Tabla: " .. name .. "  (" .. #rows .. " filas × " .. #col_order .. " cols)"
	if filter_user then
		title = title .. " [FILTRO: " .. filter_user .. "]"
	end
	open_float(title, lines)
end

-- ── Entrada: previsualiza la variable bajo el cursor ────────────────────────────
function M.show_alv(mine_only)
	if not dbg.session then
		notify("No hay sesión de debug activa.", vim.log.levels.WARN)
		return
	end

	local name = vim.fn.expand("<cexpr>")
	if not name or name == "" then
		return
	end
	name = name:upper()

	-- Capturamos tu usuario de SAP de la sesión activa si activamos el filtro
	local filter_user = mine_only and dbg.session.user or nil

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
			local row_ids = dbg.table_row_ids(v.id, v.table_lines)
			dbg.get_vars_by_id(row_ids, function(rows)
				local first = rows[1]
				if first and first.expandable then
					dbg.get_variables(row_ids, function(cells)
						render_table(name, rows, cells or {}, filter_user)
					end)
				else
					render_table(name, rows, {}, filter_user)
				end
			end)
		elseif v.meta == "structure" then
			dbg.get_variables(v.id, function(fields)
				render_struct(name, fields)
			end)
		else
			open_float("Variable: " .. name, { (v.name or name) .. " : " .. (v.value or "") })
		end
	end)
end

function M.setup()
	-- Comandos
	vim.api.nvim_create_user_command("SapAlvPreview", function()
		M.show_alv(false)
	end, { desc = "Previsualizar variable (ALV)" })
	vim.api.nvim_create_user_command("SapAlvPreviewMine", function()
		M.show_alv(true)
	end, { desc = "Previsualizar variable (Solo mis datos)" })

	-- Atajos de teclado para archivos ABAP
	vim.api.nvim_create_autocmd("FileType", {
		pattern = "abap",
		group = vim.api.nvim_create_augroup("sap_nvim_preview", { clear = true }),
		callback = function(ev)
			vim.keymap.set("n", "<leader>dv", function()
				M.show_alv(false)
			end, { buffer = ev.buf, desc = "Debug: Previsualizar (ALV)" })
			vim.keymap.set("n", "<leader>dm", function()
				M.show_alv(true)
			end, { buffer = ev.buf, desc = "Debug: Previsualizar (Solo Mías)" })
		end,
	})
end

return M
