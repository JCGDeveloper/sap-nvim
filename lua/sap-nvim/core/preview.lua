-- lua/sap-nvim/core/preview.lua
local M = {}
local dbg = require("sap-nvim.core.debugger")
local last_preview = nil
local preview_win = nil
local preview_tab = nil
local preview_buf = nil
local code_tab = nil
local keep_preview_until = 0
local dap_focus_guard_installed = false
local COCKPIT_TABS = { "Datos", "Locales", "Globales", "Watch", "Stack", "Breakpoints", "Log" }
local cockpit = {
	active = "Datos",
	watches = {},
	logs = {},
	panes = {},
}

local function pane(name)
	cockpit.panes[name] = cockpit.panes[name] or { title = name, lines = { "(sin datos)" } }
	return cockpit.panes[name]
end

for _, tab in ipairs(COCKPIT_TABS) do
	pane(tab)
end

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function add_log(msg)
	local line = os.date("%H:%M:%S") .. "  " .. tostring(msg)
	cockpit.logs[#cockpit.logs + 1] = line
	if #cockpit.logs > 200 then
		table.remove(cockpit.logs, 1)
	end
	local p = pane("Log")
	p.title = "Log"
	p.lines = vim.deepcopy(cockpit.logs)
end

local function now_ms()
	local uv = vim.uv or vim.loop
	return uv.now()
end

local function tab_valid(tab)
	if not tab then
		return false
	end
	for _, t in ipairs(vim.api.nvim_list_tabpages()) do
		if t == tab then
			return true
		end
	end
	return false
end

local function close_preview_tab()
	local tab = preview_tab
	preview_tab, preview_buf, preview_win = nil, nil, nil
	if tab_valid(tab) then
		local cur = vim.api.nvim_get_current_tabpage()
		pcall(vim.api.nvim_set_current_tabpage, tab)
		pcall(vim.cmd, "tabclose")
		if tab_valid(cur) then
			pcall(vim.api.nvim_set_current_tabpage, cur)
		end
	end
end

local function preview_active()
	return tab_valid(preview_tab) and preview_buf and vim.api.nvim_buf_is_valid(preview_buf)
end

local function preview_window()
	if preview_win and vim.api.nvim_win_is_valid(preview_win) then
		return preview_win
	end
	if not preview_active() then
		return nil
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(preview_tab)) do
		if vim.api.nvim_win_get_buf(win) == preview_buf then
			preview_win = win
			return win
		end
	end
	return nil
end

local function focus_preview_tab()
	if not preview_active() then
		return
	end
	pcall(vim.api.nvim_set_current_tabpage, preview_tab)
	local win = preview_window()
	if win then
		pcall(vim.api.nvim_set_current_win, win)
	end
end

local function pin_preview_after_step()
	keep_preview_until = now_ms() + 10000
end

function M.restore_preview_after_stop()
	if keep_preview_until <= now_ms() or not preview_active() then
		return
	end

	local function restore()
		if keep_preview_until <= now_ms() or not preview_active() then
			return
		end
		local cur = vim.api.nvim_get_current_tabpage()
		if cur ~= preview_tab and tab_valid(cur) then
			code_tab = cur
		end
		focus_preview_tab()
	end

	for _, delay in ipairs({ 20, 80, 180, 350 }) do
		vim.defer_fn(restore, delay)
	end
end

function M.install_dap_focus_guard()
	if dap_focus_guard_installed then
		return
	end
	local ok, dap = pcall(require, "dap")
	if not ok then
		return
	end
	dap.listeners.after.event_stopped = dap.listeners.after.event_stopped or {}
	dap.listeners.after.event_terminated = dap.listeners.after.event_terminated or {}
	dap.listeners.after.event_exited = dap.listeners.after.event_exited or {}
	dap.listeners.after.event_stopped["sap_nvim_preview_focus"] = function()
		vim.schedule(M.restore_preview_after_stop)
	end
	dap.listeners.after.event_terminated["sap_nvim_preview_focus"] = function()
		keep_preview_until = 0
	end
	dap.listeners.after.event_exited["sap_nvim_preview_focus"] = function()
		keep_preview_until = 0
	end
	dap_focus_guard_installed = true
end

function M.jump_to_code()
	keep_preview_until = 0
	if tab_valid(code_tab) then
		pcall(vim.api.nvim_set_current_tabpage, code_tab)
	end
	local ok, dap = pcall(require, "dap")
	if ok and dap.focus_frame then
		pcall(dap.focus_frame)
	end
end

function M.should_preserve_focus()
	local buf = vim.api.nvim_get_current_buf()
	local name = vim.api.nvim_buf_get_name(buf)
	if vim.bo[buf].filetype == "sapdebugpreview" or name:match("^sap%-debug%-preview://") then
		return true
	end
	return keep_preview_until > now_ms() and preview_active()
end

local function map_preview_keys(buf)
	local function dap_call(fn)
		return function()
			M.install_dap_focus_guard()
			pin_preview_after_step()
			local ok_sapdap, sapdap = pcall(require, "sap-nvim.integrations.dap")
			if ok_sapdap and sapdap.step_from_preview then
				sapdap.step_from_preview(fn)
				return
			end
			local ok_dap, dap = pcall(require, "dap")
			if ok_dap and dap[fn] then
				dap[fn]()
			end
		end
	end

	local opts = { buffer = buf, nowait = true, silent = true }
	vim.keymap.set("n", "q", close_preview_tab, vim.tbl_extend("force", opts, { desc = "Cerrar preview SAP" }))
	vim.keymap.set("n", "<Esc>", close_preview_tab, opts)
	vim.keymap.set("n", "<CR>", M.jump_to_code, vim.tbl_extend("force", opts, { desc = "DAP ir al código" }))
	vim.keymap.set("n", "<F5>", dap_call("continue"), vim.tbl_extend("force", opts, { desc = "DAP continuar" }))
	vim.keymap.set("n", "<F10>", dap_call("step_over"), vim.tbl_extend("force", opts, { desc = "DAP step over" }))
	vim.keymap.set("n", "<F11>", dap_call("step_into"), vim.tbl_extend("force", opts, { desc = "DAP step into" }))
	vim.keymap.set("n", "<S-F11>", dap_call("step_out"), vim.tbl_extend("force", opts, { desc = "DAP step out" }))
	vim.keymap.set("n", "<leader>dc", dap_call("continue"), vim.tbl_extend("force", opts, { desc = "DAP continuar" }))
	vim.keymap.set("n", "<leader>do", dap_call("step_over"), vim.tbl_extend("force", opts, { desc = "DAP step over" }))
	vim.keymap.set("n", "<leader>di", dap_call("step_into"), vim.tbl_extend("force", opts, { desc = "DAP step into" }))
	vim.keymap.set("n", "<leader>du", dap_call("step_out"), vim.tbl_extend("force", opts, { desc = "DAP step out" }))
	vim.keymap.set("n", "<leader>dg", M.jump_to_code, vim.tbl_extend("force", opts, { desc = "DAP ir al código" }))
end

local function ensure_preview_tab(focus)
	if tab_valid(preview_tab) and preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
		if focus then
			pcall(vim.api.nvim_set_current_tabpage, preview_tab)
			preview_win = preview_window()
		end
		return true
	end

	if not focus then
		return false
	end

	local origin = vim.api.nvim_get_current_tabpage()
	vim.cmd("tabnew")
	code_tab = origin
	preview_tab = vim.api.nvim_get_current_tabpage()
	preview_win = vim.api.nvim_get_current_win()
	preview_buf = vim.api.nvim_get_current_buf()
	pcall(vim.api.nvim_buf_set_name, preview_buf, "sap-debug-preview://variables")
	vim.bo[preview_buf].buftype = "nofile"
	vim.bo[preview_buf].bufhidden = "wipe"
	vim.bo[preview_buf].swapfile = false
	vim.bo[preview_buf].filetype = "sapdebugpreview"
	vim.wo[preview_win].cursorline = true
	vim.wo[preview_win].wrap = false
	map_preview_keys(preview_buf)
	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = preview_buf,
		once = true,
		callback = function()
			preview_tab, preview_buf, preview_win = nil, nil, nil
		end,
	})
	if not tab_valid(origin) then
		origin = nil
	end
	return true
end

local function cockpit_tabline()
	local labels = {}
	for i, name in ipairs(COCKPIT_TABS) do
		local label = tostring(i) .. ":" .. name
		if name == cockpit.active then
			label = "[" .. label .. "]"
		end
		labels[#labels + 1] = label
	end
	return table.concat(labels, "  ")
end

local function cockpit_lines()
	local p = pane(cockpit.active)
	local lines = {
		"# SAP Debug Cockpit",
		cockpit_tabline(),
		"",
		"## " .. (p.title or cockpit.active),
		"",
	}
	vim.list_extend(lines, p.lines or { "(sin datos)" })
	return lines
end

local function render_cockpit(opts)
	opts = opts or {}
	local focus = opts.focus ~= false
	local origin = vim.api.nvim_get_current_tabpage()
	if not ensure_preview_tab(focus) then
		return
	end

	local win = preview_window()
	local old_cursor, old_topline
	if win and vim.api.nvim_win_is_valid(win) then
		old_cursor = vim.api.nvim_win_get_cursor(win)
		old_topline = vim.fn.getwininfo(win)[1] and vim.fn.getwininfo(win)[1].topline or nil
	end

	local out = cockpit_lines()
	vim.bo[preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, out)
	vim.bo[preview_buf].modifiable = false

	if win and vim.api.nvim_win_is_valid(win) then
		if opts.preserve_cursor and old_cursor then
			old_cursor[1] = math.min(old_cursor[1], math.max(#out, 1))
			pcall(vim.api.nvim_win_set_cursor, win, old_cursor)
			if old_topline then
				pcall(vim.api.nvim_win_call, win, function()
					vim.cmd("normal! " .. old_topline .. "zt")
				end)
			end
		elseif focus then
			pcall(vim.api.nvim_win_set_cursor, win, { math.min(6, #out), 0 })
		end
	end

	if not focus and tab_valid(origin) then
		pcall(vim.api.nvim_set_current_tabpage, origin)
	end
end

local function open_preview(title, lines, opts)
	opts = opts or {}
	local focus = opts.focus ~= false
	if #lines == 0 then
		lines = { "(sin datos)" }
	end

	local tab = opts.pane or "Datos"
	local p = pane(tab)
	p.title = title
	p.lines = lines
	if opts.activate ~= false then
		cockpit.active = tab
	end

	if cockpit.active == tab or focus then
		render_cockpit({ focus = focus, preserve_cursor = opts.preserve_cursor or focus == false })
	end
end

local function tab_index(name)
	for i, tab in ipairs(COCKPIT_TABS) do
		if tab == name then
			return i
		end
	end
	return 1
end

local function select_tab(name, opts)
	cockpit.active = name
	if M.refresh_pane then
		M.refresh_pane(name, opts or { focus = true })
	else
		render_cockpit(opts or { focus = true })
	end
end

local function select_relative_tab(delta)
	local idx = tab_index(cockpit.active)
	local next_idx = ((idx - 1 + delta) % #COCKPIT_TABS) + 1
	select_tab(COCKPIT_TABS[next_idx], { focus = true })
end

local function render_struct(name, fields, focus)
	local w = 0
	for _, f in ipairs(fields) do
		w = math.max(w, #(f.name or ""))
	end
	local lines = {}
	for _, f in ipairs(fields) do
		lines[#lines + 1] = string.format("%-" .. w .. "s │ %s", f.name or "?", f.value or "")
	end
	open_preview("Estructura: " .. name, lines, { focus = focus })
end

local function render_table(name, rows, cells, filter_user, focus)
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

	if #col_order == 0 or #rows == 0 then
		local lines = {}
		for i, r in ipairs(rows) do
			lines[#lines + 1] = string.format("%6d │ %s", i, r.value or r.name or "")
		end
		open_preview("Tabla: " .. name .. " (" .. #rows .. " filas)", lines, { focus = focus })
		return
	end

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

	local title = "Tabla: " .. name .. " (" .. #rows .. " filas)"
	if filter_user then
		title = title .. " [FILTRO: " .. filter_user .. "]"
	end
	open_preview(title, lines, { focus = focus })
end

-- 🔥 FIX ARQUITECTÓNICO: Resolvemos el ID oficial de SAP buscando en el Scope local y global primero
function M.show_alv(mine_only, name_override, opts)
	if not dbg.session then
		notify("No hay sesión de debug activa.", vim.log.levels.WARN)
		return
	end
	opts = opts or {}
	local focus = opts.focus ~= false
	local name = name_override or vim.fn.expand("<cexpr>")
	if not name or name == "" then
		return
	end
	name = name:upper()
	last_preview = { name = name, mine_only = mine_only == true }
	local filter_user = mine_only and dbg.session.user or nil

	-- 1. Buscamos el ID real de la variable dentro del Scope
	dbg.get_variables({ "@LOCALS", "@GLOBALS" }, function(vars)
		local found_id = nil
		for _, v in ipairs(vars) do
			if (v.name or ""):upper() == name then
				found_id = v.id
				break
			end
		end

		if not found_id then
			notify("Variable " .. name .. " no inicializada o fuera de alcance.", vim.log.levels.WARN)
			return
		end

		-- 2. Con el ID oficial (ej: @LOCALS\TL_PROFESORES), pedimos la tabla
		dbg.get_vars_by_id(found_id, function(metas)
			local v = metas and metas[1]
			if not v then
				return
			end

			if v.meta == "table" then
				if (v.table_lines or 0) == 0 then
					open_preview("Tabla: " .. name .. " (vacía)", { "(0 filas)" }, { focus = focus })
					return
				end
				dbg.get_table_rows(v.id, v.table_lines, function(rows)
					local first = rows[1]
					if first and first.expandable then
						local ids = {}
						for _, row in ipairs(rows) do
							ids[#ids + 1] = row.id
						end
						dbg.get_variables(ids, function(cells)
							render_table(name, rows, cells or {}, filter_user, focus)
						end)
					else
						render_table(name, rows, {}, filter_user, focus)
					end
				end)
			elseif v.meta == "structure" then
				dbg.get_variables(v.id, function(fields)
					render_struct(name, fields, focus)
				end)
			else
				open_preview("Variable: " .. name, { (v.name or name) .. " : " .. (v.value or "") }, { focus = focus })
			end
		end)
	end)
end

function M.refresh_active()
	if not last_preview or not dbg.session then
		return
	end
	M.show_alv(last_preview.mine_only, last_preview.name, { focus = false })
end

function M.setup()
	M.install_dap_focus_guard()
	vim.api.nvim_create_user_command("SapAlvPreview", function()
		M.show_alv(false)
	end, { desc = "Previsualizar variable (ALV)" })
	vim.api.nvim_create_user_command("SapAlvPreviewMine", function()
		M.show_alv(true)
	end, { desc = "Previsualizar variable (Solo mis datos)" })
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
