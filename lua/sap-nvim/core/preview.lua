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

local select_tab
local select_relative_tab

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
	vim.keymap.set("n", "<Tab>", function()
		select_relative_tab(1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: pestaña siguiente" }))
	vim.keymap.set("n", "<S-Tab>", function()
		select_relative_tab(-1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: pestaña anterior" }))
	for i, tab in ipairs(COCKPIT_TABS) do
		local tab_name = tab
		vim.keymap.set("n", tostring(i), function()
			select_tab(tab_name, { focus = true })
		end, vim.tbl_extend("force", opts, { desc = "Cockpit: " .. tab_name }))
	end
	vim.keymap.set("n", "r", function()
		if M.refresh_pane then
			M.refresh_pane(cockpit.active, { focus = true, preserve_cursor = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: refrescar" }))
	vim.keymap.set("n", "a", function()
		if cockpit.active == "Watch" and M.add_watch then
			M.add_watch()
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: añadir watch" }))
	vim.keymap.set("n", "d", function()
		if cockpit.active == "Watch" and M.delete_watch_under_cursor then
			M.delete_watch_under_cursor()
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: borrar watch" }))
	vim.keymap.set("n", "x", function()
		if cockpit.active == "Breakpoints" then
			local ok, sapdap = pcall(require, "sap-nvim.integrations.dap")
			if ok and sapdap.clear_breakpoints_current then
				sapdap.clear_breakpoints_current()
				add_log("breakpoints del buffer limpiados")
				vim.defer_fn(function()
					if M.refresh_pane then
						M.refresh_pane("Breakpoints", { focus = true })
					end
				end, 300)
			end
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: limpiar breakpoints buffer" }))
	vim.keymap.set("n", "X", function()
		if cockpit.active == "Breakpoints" then
			local ok, sapdap = pcall(require, "sap-nvim.integrations.dap")
			if ok and sapdap.clear_breakpoints_related then
				sapdap.clear_breakpoints_related()
				add_log("breakpoints relacionados limpiados")
				vim.defer_fn(function()
					if M.refresh_pane then
						M.refresh_pane("Breakpoints", { focus = true })
					end
				end, 300)
			end
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: limpiar breakpoints relacionados" }))
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
	local old_cursor, old_view
	if win and vim.api.nvim_win_is_valid(win) then
		old_cursor = vim.api.nvim_win_get_cursor(win)
		pcall(vim.api.nvim_win_call, win, function()
			old_view = vim.fn.winsaveview()
		end)
	end

	local out = cockpit_lines()
	vim.bo[preview_buf].modifiable = true
	vim.api.nvim_buf_set_lines(preview_buf, 0, -1, false, out)
	vim.bo[preview_buf].modifiable = false

	if win and vim.api.nvim_win_is_valid(win) then
		if opts.preserve_cursor and old_cursor then
			old_cursor[1] = math.min(old_cursor[1], math.max(#out, 1))
			old_view = old_view or {}
			old_view.lnum = old_cursor[1]
			old_view.col = old_cursor[2]
			pcall(vim.api.nvim_win_call, win, function()
				vim.fn.winrestview(old_view)
			end)
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

select_tab = function(name, opts)
	cockpit.active = name
	if M.refresh_pane then
		M.refresh_pane(name, opts or { focus = true })
	else
		render_cockpit(opts or { focus = true })
	end
end

select_relative_tab = function(delta)
	local idx = tab_index(cockpit.active)
	local next_idx = ((idx - 1 + delta) % #COCKPIT_TABS) + 1
	select_tab(COCKPIT_TABS[next_idx], { focus = true })
end

local function normalize_preview_opts(opts)
	if type(opts) == "table" then
		opts.pane = opts.pane or "Datos"
		return opts
	end
	return { focus = opts, pane = "Datos", preserve_cursor = opts == false }
end

local function render_struct(name, fields, opts)
	opts = normalize_preview_opts(opts)
	local w = 0
	for _, f in ipairs(fields) do
		w = math.max(w, #(f.name or ""))
	end
	local lines = {}
	for _, f in ipairs(fields) do
		lines[#lines + 1] = string.format("%-" .. w .. "s │ %s", f.name or "?", f.value or "")
	end
	open_preview("Estructura: " .. name, lines, opts)
end

local function render_table(name, rows, cells, filter_user, opts)
	opts = normalize_preview_opts(opts)
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
		open_preview("Tabla: " .. name .. " (" .. #rows .. " filas)", lines, opts)
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
	open_preview(title, lines, opts)
end

local function short_value(value, max_width)
	value = tostring(value or "")
	value = value:gsub("\r", " "):gsub("\n", " ")
	max_width = max_width or 90
	if #value > max_width then
		return value:sub(1, max_width - 1) .. "…"
	end
	return value
end

local function var_value(v)
	if v.value and v.value ~= "" then
		return v.value
	end
	if v.meta == "table" then
		return "Standard Table [" .. tostring(v.table_lines or 0) .. " filas]"
	end
	if v.meta == "structure" then
		return "{ … }"
	end
	return "''"
end

local function render_vars(title, vars, opts)
	opts = opts or {}
	vars = vars or {}
	local lines = {}
	local name_w, type_w = 4, 4
	for _, v in ipairs(vars) do
		name_w = math.min(38, math.max(name_w, #(v.name or "?")))
		type_w = math.min(34, math.max(type_w, #(v.type or v.meta or "")))
	end
	local header = string.format("%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s", "NAME", "TYPE", "VALUE")
	lines[#lines + 1] = header
	lines[#lines + 1] = string.rep("-", vim.fn.strdisplaywidth(header))
	for _, v in ipairs(vars) do
		lines[#lines + 1] = string.format(
			"%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s",
			short_value(v.name or "?", name_w),
			short_value(v.type or v.meta or "", type_w),
			short_value(var_value(v), 120)
		)
	end
	if #vars == 0 then
		lines[#lines + 1] = "(sin variables)"
	end
	open_preview(title, lines, {
		pane = opts.pane or title,
		focus = opts.focus,
		preserve_cursor = opts.preserve_cursor,
	})
end

local function refresh_scope(scope, pane_name, opts)
	opts = opts or {}
	if not dbg.session then
		open_preview(pane_name, { "No hay sesión de debug activa." }, { pane = pane_name, focus = opts.focus })
		return
	end
	dbg.get_variables(scope, function(vars)
		render_vars(pane_name, vars or {}, {
			pane = pane_name,
			focus = opts.focus,
			preserve_cursor = opts.preserve_cursor,
		})
	end)
end

local function refresh_watch(opts)
	opts = opts or {}
	if #cockpit.watches == 0 then
		open_preview("Watch", {
			"No hay expresiones.",
			"Pulsa a para añadir una expresión; d borra la expresión bajo el cursor.",
		}, { pane = "Watch", focus = opts.focus, preserve_cursor = opts.preserve_cursor })
		return
	end
	if not dbg.session then
		open_preview("Watch", { "No hay sesión de debug activa." }, { pane = "Watch", focus = opts.focus })
		return
	end

	local ids = {}
	for _, expr in ipairs(cockpit.watches) do
		ids[#ids + 1] = expr:upper()
	end
	dbg.get_vars_by_id(ids, function(vars)
		local lines = {}
		local by_name = {}
		for i, v in ipairs(vars or {}) do
			by_name[(v.name or v.id or ids[i] or ""):upper()] = v
			if ids[i] then
				by_name[ids[i]] = by_name[ids[i]] or v
			end
		end
		for i, expr in ipairs(cockpit.watches) do
			local v = by_name[expr:upper()] or vars[i]
			if v then
				lines[#lines + 1] = string.format("%2d │ %-32s │ %-24s │ %s", i, expr, v.type or v.meta or "", short_value(var_value(v), 120))
			else
				lines[#lines + 1] = string.format("%2d │ %-32s │ %s", i, expr, "no evaluable o fuera de scope")
			end
		end
		open_preview("Watch", lines, { pane = "Watch", focus = opts.focus, preserve_cursor = opts.preserve_cursor })
	end)
end

local function refresh_stack(opts)
	opts = opts or {}
	if not dbg.session then
		open_preview("Stack", { "No hay sesión de debug activa." }, { pane = "Stack", focus = opts.focus })
		return
	end
	dbg.get_stack(function(frames)
		local lines = {}
		for i, frame in ipairs(frames or {}) do
			local loc = (frame.include or frame.program or "?") .. ":" .. tostring(frame.line or 1)
			local extra = frame.eventName and (" · " .. frame.eventName) or ""
			lines[#lines + 1] = string.format("%2d │ %-44s │ %s%s", i, loc, frame.program or "?", extra)
		end
		if #lines == 0 then
			lines[#lines + 1] = "(sin stack disponible)"
		end
		open_preview("Stack", lines, { pane = "Stack", focus = opts.focus, preserve_cursor = opts.preserve_cursor })
	end)
end

local function refresh_breakpoints(opts)
	opts = opts or {}
	local lines = {}
	if dbg.session and dbg.session.breakpoints then
		lines[#lines + 1] = "SAP externos:"
		if #dbg.session.breakpoints == 0 then
			lines[#lines + 1] = "  (sin breakpoints SAP registrados en esta sesión)"
		else
			for i, bp in ipairs(dbg.session.breakpoints) do
				lines[#lines + 1] =
					string.format("  %2d │ L%-5s │ %s", i, tostring(bp.line or "?"), bp.source_uri or bp.uri or "?")
			end
		end
	else
		lines[#lines + 1] = "SAP externos: no hay sesión de debug activa."
	end

	local ok_bp, breakpoints = pcall(require, "dap.breakpoints")
	if ok_bp then
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Locales nvim-dap:"
		local count = 0
		for bufnr, bps in pairs(breakpoints.get() or {}) do
			if vim.api.nvim_buf_is_valid(bufnr) then
				local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(bufnr), ":t")
				for _, bp in ipairs(bps or {}) do
					count = count + 1
					lines[#lines + 1] = string.format("  %2d │ L%-5s │ %s", count, tostring(bp.line or "?"), name)
				end
			end
		end
		if count == 0 then
			lines[#lines + 1] = "  (sin breakpoints locales)"
		end
	end

	lines[#lines + 1] = ""
	lines[#lines + 1] = "x limpia los breakpoints del buffer actual; X limpia raíz + includes relacionados."
	open_preview("Breakpoints", lines, { pane = "Breakpoints", focus = opts.focus, preserve_cursor = opts.preserve_cursor })
end

function M.refresh_pane(name, opts)
	opts = opts or {}
	name = name or cockpit.active
	if opts.activate ~= false then
		cockpit.active = name
	end
	if name == "Datos" then
		if last_preview and dbg.session then
			M.show_alv(last_preview.mine_only, last_preview.name, {
				focus = opts.focus,
				activate = true,
				preserve_cursor = opts.preserve_cursor,
			})
		else
			open_preview("Datos", { "Selecciona una variable y usa :SapAlvPreview o <leader>dT." }, {
				pane = "Datos",
				focus = opts.focus,
				preserve_cursor = opts.preserve_cursor,
			})
		end
	elseif name == "Locales" then
		refresh_scope("@LOCALS", "Locales", opts)
	elseif name == "Globales" then
		refresh_scope("@GLOBALS", "Globales", opts)
	elseif name == "Watch" then
		refresh_watch(opts)
	elseif name == "Stack" then
		refresh_stack(opts)
	elseif name == "Breakpoints" then
		refresh_breakpoints(opts)
	elseif name == "Log" then
		local p = pane("Log")
		p.title = "Log"
		p.lines = #cockpit.logs > 0 and vim.deepcopy(cockpit.logs) or { "(sin eventos)" }
		render_cockpit({ focus = opts.focus, preserve_cursor = opts.preserve_cursor })
	else
		render_cockpit({ focus = opts.focus, preserve_cursor = opts.preserve_cursor })
	end
end

function M.open_cockpit()
	M.refresh_pane(cockpit.active or "Datos", { focus = true })
end

function M.add_watch(expr)
	if expr and expr ~= "" then
		cockpit.watches[#cockpit.watches + 1] = vim.trim(expr)
		add_log("watch añadido: " .. vim.trim(expr))
		cockpit.active = "Watch"
		refresh_watch({ focus = true })
		return
	end
	vim.ui.input({ prompt = "Watch ABAP: " }, function(input)
		if input and vim.trim(input) ~= "" then
			M.add_watch(input)
		end
	end)
end

function M.delete_watch_under_cursor()
	if cockpit.active ~= "Watch" or #cockpit.watches == 0 then
		return
	end
	local line = vim.api.nvim_get_current_line()
	local idx = tonumber(line:match("^%s*(%d+)%s*│"))
	if not idx then
		idx = #cockpit.watches
	end
	local removed = table.remove(cockpit.watches, idx)
	if removed then
		add_log("watch borrado: " .. removed)
	end
	refresh_watch({ focus = true })
end

-- 🔥 FIX ARQUITECTÓNICO: Resolvemos el ID oficial de SAP buscando en el Scope local y global primero
function M.show_alv(mine_only, name_override, opts)
	if not dbg.session then
		notify("No hay sesión de debug activa.", vim.log.levels.WARN)
		return
	end
	opts = opts or {}
	local focus = opts.focus ~= false
	local preview_opts = {
		focus = focus,
		pane = "Datos",
		activate = opts.activate ~= false,
		preserve_cursor = opts.preserve_cursor or focus == false,
	}
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
					open_preview("Tabla: " .. name .. " (vacía)", { "(0 filas)" }, preview_opts)
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
							render_table(name, rows, cells or {}, filter_user, preview_opts)
						end)
					else
						render_table(name, rows, {}, filter_user, preview_opts)
					end
				end)
			elseif v.meta == "structure" then
				dbg.get_variables(v.id, function(fields)
					render_struct(name, fields, preview_opts)
				end)
			else
				open_preview("Variable: " .. name, { (v.name or name) .. " : " .. (v.value or "") }, preview_opts)
			end
		end)
	end)
end

function M.refresh_active()
	if not dbg.session then
		return
	end
	if preview_active() then
		M.refresh_pane(cockpit.active, { focus = false, preserve_cursor = true })
	elseif last_preview then
		M.show_alv(last_preview.mine_only, last_preview.name, { focus = false, activate = false, preserve_cursor = true })
	end
end

function M.setup()
	M.install_dap_focus_guard()
	vim.api.nvim_create_user_command("SapDebugCockpit", function()
		M.open_cockpit()
	end, { desc = "Abrir Debug Cockpit SAP" })
	vim.api.nvim_create_user_command("SapDapWatch", function(args)
		M.add_watch(args.args)
	end, { nargs = "*", desc = "Añadir expresión Watch al Debug Cockpit" })
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
