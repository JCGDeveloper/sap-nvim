-- lua/sap-nvim/core/preview.lua
local M = {}
local dbg = require("sap-nvim.core.debugger")
local last_preview = nil
local preview_win = nil
local preview_tab = nil
local preview_buf = nil
local code_win = nil
local code_buf = nil
local stack_win = nil
local stack_buf = nil
local watch_win = nil
local watch_buf = nil
local code_tab = nil
local code_debug_keys = {}
local clear_code_debug_keys
local set_debug_window_options
local make_side_buffer
local map_watch_tab_keys
local map_code_debug_keys
local keep_preview_until = 0
local dap_focus_guard_installed = false
local COCKPIT_TABS = { "Datos", "Locales", "Globales", "Watch", "Stack", "Breakpoints", "Log" }
local SAPGUI_DESKTOPS =
	{ "Desktop1", "Desktop2", "Desktop3", "Standard", "Estruct", "Tablas", "Objetos", "Vis.detallada", "Data Explorer" }
local SAPGUI_WATCH_TABS = { "Variables1", "Variables2", "Locals", "Globals", "Auto", "Memory" }
local DESKTOP_ALIASES = {
	["Desktop 1"] = "Desktop1",
	["Desktop 2"] = "Desktop2",
	["Desktop 3"] = "Desktop3",
	Structures = "Estruct",
	Tables = "Tablas",
	Objects = "Objetos",
	Detail = "Vis.detallada",
	["Detailed View"] = "Vis.detallada",
}
local WATCH_TAB_ALIASES = {
	["Variables 1"] = "Variables1",
	["Variables 2"] = "Variables2",
	["Memory Analysis"] = "Memory",
}
local cockpit = {
	active = "Datos",
	desktop = "Standard",
	watches = {},
	watches2 = {},
	active_watch_tab = "Variables1",
	logs = {},
	panes = {},
	data_start_line = 9,
	current_frame = nil,
	stack_frames = {},
	data_explorer = {
		filter = "",
		page = 0,
		page_size = 20,
	},
}

local function canonical_desktop(name)
	return DESKTOP_ALIASES[name] or name
end

local function canonical_watch_tab(name)
	return WATCH_TAB_ALIASES[name] or name
end

local function pane(name)
	cockpit.panes[name] = cockpit.panes[name] or { title = name, lines = { "(sin datos)" }, actions = {} }
	cockpit.panes[name].actions = cockpit.panes[name].actions or {}
	return cockpit.panes[name]
end

for _, tab in ipairs(COCKPIT_TABS) do
	pane(tab)
end

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function layout_state_file()
	return vim.fn.stdpath("state") .. "/sap-nvim/debug_layout.json"
end

local function save_layout()
	local ok, json = pcall(vim.json.encode, {
		desktop = cockpit.desktop,
		active_watch_tab = cockpit.active_watch_tab,
		watches = cockpit.watches,
		watches2 = cockpit.watches2,
		data_explorer = cockpit.data_explorer,
	})
	if not ok then
		return
	end
	local path = layout_state_file()
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
	pcall(vim.fn.writefile, { json }, path)
end

local function load_layout()
	local path = layout_state_file()
	if vim.fn.filereadable(path) ~= 1 then
		return
	end
	local ok_read, lines = pcall(vim.fn.readfile, path)
	if not ok_read or not lines or not lines[1] then
		return
	end
	local ok, data = pcall(vim.json.decode, table.concat(lines, "\n"))
	if not ok or type(data) ~= "table" then
		return
	end
	if type(data.desktop) == "string" then
		cockpit.desktop = canonical_desktop(data.desktop)
	end
	if type(data.active_watch_tab) == "string" then
		cockpit.active_watch_tab = canonical_watch_tab(data.active_watch_tab)
	end
	if type(data.watches) == "table" then
		cockpit.watches = data.watches
	end
	if type(data.watches2) == "table" then
		cockpit.watches2 = data.watches2
	end
	if type(data.data_explorer) == "table" then
		cockpit.data_explorer.filter = tostring(data.data_explorer.filter or "")
		cockpit.data_explorer.page = tonumber(data.data_explorer.page) or 0
		cockpit.data_explorer.page_size = tonumber(data.data_explorer.page_size) or cockpit.data_explorer.page_size
	end
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
	if clear_code_debug_keys then
		clear_code_debug_keys()
	end
	preview_tab, preview_buf, preview_win = nil, nil, nil
	code_win, code_buf = nil, nil
	stack_win, stack_buf, watch_win, watch_buf = nil, nil, nil, nil
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

local function side_buf_valid(buf)
	return buf and vim.api.nvim_buf_is_valid(buf)
end

local function win_shows(win, buf)
	return win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)
		and vim.api.nvim_win_get_buf(win) == buf
end

local function restore_window_buffer(win, buf)
	if not (win and vim.api.nvim_win_is_valid(win) and buf and vim.api.nvim_buf_is_valid(buf)) then
		return false
	end
	if vim.api.nvim_win_get_buf(win) ~= buf then
		pcall(vim.api.nvim_win_set_buf, win, buf)
	end
	set_debug_window_options(win)
	return vim.api.nvim_win_get_buf(win) == buf
end

local function restore_or_make_panel(win, buf, name)
	if not (win and vim.api.nvim_win_is_valid(win)) then
		return buf, false
	end
	if not side_buf_valid(buf) then
		buf = make_side_buffer(name)
	end
	restore_window_buffer(win, buf)
	return buf, win_shows(win, buf)
end

local function close_duplicate_code_windows()
	if not (preview_tab and tab_valid(preview_tab) and code_buf and vim.api.nvim_buf_is_valid(code_buf)) then
		return
	end
	for _, win in ipairs(vim.api.nvim_tabpage_list_wins(preview_tab)) do
		if win ~= code_win and vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == code_buf then
			pcall(vim.api.nvim_win_close, win, true)
		end
	end
end

local function preview_window()
	if win_shows(preview_win, preview_buf) then
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
	if preview_tab and tab_valid(preview_tab) then
		pcall(vim.api.nvim_set_current_tabpage, preview_tab)
		if code_win and vim.api.nvim_win_is_valid(code_win) then
			pcall(vim.api.nvim_set_current_win, code_win)
		end
		return
	end
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
	if preview_active() and vim.api.nvim_get_current_tabpage() == preview_tab then
		return true
	end
	if vim.bo[buf].filetype == "sapdebugpreview" or name:match("^sap%-debug%-preview://") then
		return true
	end
	if preview_active() and cockpit.active == "Datos" and canonical_desktop(cockpit.desktop) == "Data Explorer" then
		return true
	end
	return keep_preview_until > now_ms() and preview_active()
end

function M.focus_source_in_cockpit(bufnr, line, column)
	if not (preview_active() and bufnr and vim.api.nvim_buf_is_valid(bufnr)) then
		return false
	end
	pcall(vim.api.nvim_set_current_tabpage, preview_tab)
	if not (code_win and vim.api.nvim_win_is_valid(code_win)) then
		return false
	end
	pcall(vim.api.nvim_set_current_win, code_win)
	if vim.api.nvim_win_get_buf(code_win) ~= bufnr then
		pcall(vim.api.nvim_win_set_buf, code_win, bufnr)
		code_buf = bufnr
		map_code_debug_keys(code_buf)
	end
	local target_line = math.max(1, math.min(tonumber(line) or 1, vim.api.nvim_buf_line_count(bufnr)))
	local target_col = math.max((tonumber(column) or 1) - 1, 0)
	pcall(vim.api.nvim_win_set_cursor, code_win, { target_line, target_col })
	set_debug_window_options(code_win)
	return true
end

local select_tab
local select_relative_tab
local open_debug_variable
local refresh_stack_side
local select_watch_tab
local select_desktop
local refresh_objects_desktop
local refresh_data_explorer
local refresh_last_preview
local short_value
local var_value

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
		local watch_tab_name = SAPGUI_WATCH_TABS[i]
		vim.keymap.set("n", tostring(i), function()
			if buf == watch_buf and watch_tab_name and select_watch_tab then
				select_watch_tab(watch_tab_name, { focus = true })
				return
			end
			select_tab(tab_name, { focus = true })
		end, vim.tbl_extend("force", opts, { desc = "Cockpit: " .. tab_name }))
	end
	vim.keymap.set("n", "L", function()
		if buf == watch_buf and select_watch_tab then
			select_watch_tab("Locals", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Locals" }))
	vim.keymap.set("n", "G", function()
		if buf == watch_buf and select_watch_tab then
			select_watch_tab("Globals", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Globals" }))
	vim.keymap.set("n", "S", function()
		if select_desktop then
			select_desktop("Estruct", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Estruct" }))
	vim.keymap.set("n", "T", function()
		if select_desktop then
			select_desktop("Tablas", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Tablas" }))
	vim.keymap.set("n", "O", function()
		if select_desktop then
			select_desktop("Objetos", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Objetos" }))
	vim.keymap.set("n", "D", function()
		if select_desktop then
			select_desktop("Vis.detallada", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Vis.detallada" }))
	vim.keymap.set("n", "E", function()
		if select_desktop then
			select_desktop("Data Explorer", { focus = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: Data Explorer" }))
	vim.keymap.set("n", "r", function()
		if M.refresh_pane then
			M.refresh_pane(cockpit.active, { focus = false, preserve_cursor = true })
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: refrescar" }))
	vim.keymap.set("n", "/", function()
		if M.set_data_explorer_filter then
			M.set_data_explorer_filter()
		end
	end, vim.tbl_extend("force", opts, { desc = "Data Explorer: filtrar" }))
	vim.keymap.set("n", "f", function()
		if M.set_data_explorer_filter then
			M.set_data_explorer_filter()
		end
	end, vim.tbl_extend("force", opts, { desc = "Data Explorer: filtrar" }))
	vim.keymap.set("n", "o", function()
		if buf == watch_buf and M.open_selected_right_variable then
			M.open_selected_right_variable()
		elseif M.open_selected_variable then
			M.open_selected_variable()
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: abrir variable en Datos" }))
	vim.keymap.set("n", "=", function()
		if M.set_selected_variable then
			M.set_selected_variable(buf == watch_buf)
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: set variable" }))
	vim.keymap.set("n", "a", function()
		local tab = cockpit.active_watch_tab or "Variables1"
		if M.add_watch and (cockpit.active == "Watch" or (buf == watch_buf and (tab == "Variables1" or tab == "Variables2"))) then
			M.add_watch()
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: añadir watch" }))
	vim.keymap.set("n", "d", function()
		if M.delete_watch_under_cursor and (cockpit.active == "Watch" or buf == watch_buf) then
			M.delete_watch_under_cursor()
		end
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: borrar watch" }))
	vim.keymap.set("n", "e", function()
		if M.edit_watch_under_cursor and (cockpit.active == "Watch" or buf == watch_buf) then
			M.edit_watch_under_cursor()
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: editar variable/watch" }))
	vim.keymap.set("n", "i", function()
		local tab = cockpit.active_watch_tab or "Variables1"
		if M.add_watch and buf == watch_buf and (tab == "Variables1" or tab == "Variables2") then
			M.add_watch()
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: escribir expresión" }))
	vim.keymap.set("n", "<CR>", function()
		local tab = cockpit.active_watch_tab or "Variables1"
		if buf == watch_buf and (tab == "Variables1" or tab == "Variables2") then
			M.add_watch()
		elseif buf == stack_buf and M.select_stack_under_cursor then
			M.select_stack_under_cursor()
		else
			M.jump_to_code()
		end
	end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: acción principal" }))
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
	-- Paginación de tablas grandes en el panel Datos: ]/> avanza, [/< retrocede.
	vim.keymap.set("n", "]", function()
		M.table_page(1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: página siguiente (tabla)" }))
	vim.keymap.set("n", "[", function()
		M.table_page(-1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: página anterior (tabla)" }))
	vim.keymap.set("n", ">", function()
		M.table_page(1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: página siguiente (tabla)" }))
	vim.keymap.set("n", "<", function()
		M.table_page(-1)
	end, vim.tbl_extend("force", opts, { desc = "Cockpit: página anterior (tabla)" }))
	-- Teclas estilo SAP GUI New ABAP Debugger dentro de la pestaña del cockpit:
	-- F5 single step, F6 execute/step over, F7 return, F8 continue.
	vim.keymap.set("n", "<F5>", dap_call("step_into"), vim.tbl_extend("force", opts, { desc = "SAP Debugger: Single Step" }))
	vim.keymap.set("n", "<F6>", dap_call("step_over"), vim.tbl_extend("force", opts, { desc = "SAP Debugger: Execute" }))
	vim.keymap.set("n", "<F7>", dap_call("step_out"), vim.tbl_extend("force", opts, { desc = "SAP Debugger: Return" }))
	vim.keymap.set("n", "<F8>", dap_call("continue"), vim.tbl_extend("force", opts, { desc = "SAP Debugger: Continue" }))
	-- Compatibilidad con nvim-dap/VS Code.
	vim.keymap.set("n", "<F10>", dap_call("step_over"), vim.tbl_extend("force", opts, { desc = "DAP step over" }))
	vim.keymap.set("n", "<F11>", dap_call("step_into"), vim.tbl_extend("force", opts, { desc = "DAP step into" }))
	vim.keymap.set("n", "<S-F11>", dap_call("step_out"), vim.tbl_extend("force", opts, { desc = "DAP step out" }))
	vim.keymap.set("n", "<leader>dc", dap_call("continue"), vim.tbl_extend("force", opts, { desc = "DAP continuar" }))
	vim.keymap.set("n", "<leader>do", dap_call("step_over"), vim.tbl_extend("force", opts, { desc = "DAP step over" }))
	vim.keymap.set("n", "<leader>di", dap_call("step_into"), vim.tbl_extend("force", opts, { desc = "DAP step into" }))
	vim.keymap.set("n", "<leader>du", dap_call("step_out"), vim.tbl_extend("force", opts, { desc = "DAP step out" }))
	vim.keymap.set("n", "<leader>dg", M.jump_to_code, vim.tbl_extend("force", opts, { desc = "DAP ir al código" }))
end

local function dap_call_from_debugger(fn)
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

clear_code_debug_keys = function()
	if not (code_buf and vim.api.nvim_buf_is_valid(code_buf)) then
		code_debug_keys = {}
		return
	end
	for _, lhs in ipairs(code_debug_keys) do
		pcall(vim.keymap.del, "n", lhs, { buffer = code_buf })
	end
	code_debug_keys = {}
end

map_code_debug_keys = function(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	clear_code_debug_keys()
	local opts = { buffer = buf, nowait = true, silent = true }
	local function set(lhs, rhs, desc)
		vim.keymap.set("n", lhs, rhs, vim.tbl_extend("force", opts, { desc = desc }))
		code_debug_keys[#code_debug_keys + 1] = lhs
	end

	set("o", function()
		if M.show_alv then
			M.show_alv(false, nil, { focus = true })
		end
	end, "SAP Debugger: visualizar variable bajo cursor")
	set("O", function()
		if select_desktop then
			select_desktop("Objetos", { focus = true })
		end
	end, "SAP Debugger: Objetos")
	set("S", function()
		if select_desktop then
			select_desktop("Estruct", { focus = true })
		end
	end, "SAP Debugger: Estruct")
	set("T", function()
		if select_desktop then
			select_desktop("Tablas", { focus = true })
		end
	end, "SAP Debugger: Tablas")
	set("D", function()
		if select_desktop then
			select_desktop("Vis.detallada", { focus = true })
		end
	end, "SAP Debugger: Vis.detallada")
	set("E", function()
		if select_desktop then
			select_desktop("Data Explorer", { focus = true })
		end
	end, "SAP Debugger: Data Explorer")
	set("=", function()
		if M.set_variable_under_cursor then
			M.set_variable_under_cursor()
		end
	end, "SAP Debugger: set variable bajo cursor")
	set("L", function()
		if select_watch_tab then
			select_watch_tab("Locals", { focus = true })
		end
	end, "SAP Debugger: Locals")
	set("G", function()
		if select_watch_tab then
			select_watch_tab("Globals", { focus = true })
		end
	end, "SAP Debugger: Globals")
	set("<F5>", dap_call_from_debugger("step_into"), "SAP Debugger: Single Step")
	set("<F6>", dap_call_from_debugger("step_over"), "SAP Debugger: Execute")
	set("<F7>", dap_call_from_debugger("step_out"), "SAP Debugger: Return")
	set("<F8>", dap_call_from_debugger("continue"), "SAP Debugger: Continue")
	set("<leader>di", dap_call_from_debugger("step_into"), "DAP step into")
	set("<leader>do", dap_call_from_debugger("step_over"), "DAP step over")
	set("<leader>du", dap_call_from_debugger("step_out"), "DAP step out")
	set("<leader>dc", dap_call_from_debugger("continue"), "DAP continuar")
	set("<leader>dg", M.jump_to_code, "DAP ir al código")
end

local function ensure_preview_tab(focus)
	if tab_valid(preview_tab) then
		if not side_buf_valid(preview_buf) and preview_win and vim.api.nvim_win_is_valid(preview_win) then
			preview_buf = make_side_buffer("sap-debug-preview://variables")
		end
		if not side_buf_valid(stack_buf) and stack_win and vim.api.nvim_win_is_valid(stack_win) then
			stack_buf = make_side_buffer("sap-debug-preview://callstack")
		end
		if not side_buf_valid(watch_buf) and watch_win and vim.api.nvim_win_is_valid(watch_win) then
			watch_buf = make_side_buffer("sap-debug-preview://watch")
		end
	end
	if tab_valid(preview_tab) and preview_buf and vim.api.nvim_buf_is_valid(preview_buf) then
		restore_window_buffer(code_win, code_buf)
		preview_buf = select(1, restore_or_make_panel(preview_win, preview_buf, "sap-debug-preview://variables"))
		stack_buf = select(1, restore_or_make_panel(stack_win, stack_buf, "sap-debug-preview://callstack"))
		watch_buf = select(1, restore_or_make_panel(watch_win, watch_buf, "sap-debug-preview://watch"))
		map_watch_tab_keys(watch_buf)
		close_duplicate_code_windows()
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
	local origin_buf = vim.api.nvim_get_current_buf()
	vim.cmd("tabnew")
	code_tab = origin
	preview_tab = vim.api.nvim_get_current_tabpage()

	code_win = vim.api.nvim_get_current_win()
	code_buf = origin_buf
	if code_buf and vim.api.nvim_buf_is_valid(code_buf) then
		pcall(vim.api.nvim_win_set_buf, code_win, code_buf)
	else
		code_buf = vim.api.nvim_get_current_buf()
	end
	set_debug_window_options(code_win)
	map_code_debug_keys(code_buf)

	-- Columna derecha completa: arriba Call Stack, abajo Variables/Watch.
	vim.cmd("rightbelow vertical split")
	stack_win = vim.api.nvim_get_current_win()
	stack_buf = make_side_buffer("sap-debug-preview://callstack")
	vim.api.nvim_win_set_buf(stack_win, stack_buf)
	local side_width = math.max(46, math.floor(vim.o.columns * 0.34))
	pcall(vim.api.nvim_win_set_width, stack_win, side_width)
	vim.wo[stack_win].winfixwidth = true
	set_debug_window_options(stack_win)

	vim.cmd("belowright split")
	watch_win = vim.api.nvim_get_current_win()
	watch_buf = make_side_buffer("sap-debug-preview://watch")
	map_watch_tab_keys(watch_buf)
	vim.api.nvim_win_set_buf(watch_win, watch_buf)
	pcall(vim.api.nvim_win_set_height, watch_win, math.max(10, math.floor(vim.o.lines * 0.30)))
	pcall(vim.api.nvim_win_set_width, watch_win, side_width)
	vim.wo[watch_win].winfixwidth = true
	vim.wo[watch_win].winfixheight = true
	set_debug_window_options(watch_win)

	-- Panel inferior izquierdo: herramientas/pestañas (Datos, Locales, estructuras, tablas...).
	pcall(vim.api.nvim_set_current_win, code_win)
	vim.cmd("belowright split")
	preview_win = vim.api.nvim_get_current_win()
	preview_buf = make_side_buffer("sap-debug-preview://variables")
	vim.api.nvim_win_set_buf(preview_win, preview_buf)
	pcall(vim.api.nvim_win_set_height, preview_win, math.max(10, math.floor(vim.o.lines * 0.30)))
	vim.wo[preview_win].winfixheight = true
	set_debug_window_options(preview_win)
	pcall(vim.api.nvim_set_current_win, code_win)

	vim.api.nvim_create_autocmd("BufWipeout", {
		buffer = preview_buf,
		once = true,
		callback = function()
			if clear_code_debug_keys then
				clear_code_debug_keys()
			end
			preview_tab, preview_buf, preview_win = nil, nil, nil
			code_win, code_buf = nil, nil
			stack_win, stack_buf, watch_win, watch_buf = nil, nil, nil, nil
		end,
	})
	if not tab_valid(origin) then
		origin = nil
	end
	return true
end

set_debug_window_options = function(win)
	if not win or not vim.api.nvim_win_is_valid(win) then
		return
	end
	vim.wo[win].number = false
	vim.wo[win].relativenumber = false
	vim.wo[win].signcolumn = "no"
	vim.wo[win].foldcolumn = "0"
	vim.wo[win].wrap = false
	vim.wo[win].cursorline = true
	vim.wo[win].list = false
end

make_side_buffer = function(name)
	local buf = vim.api.nvim_create_buf(false, true)
	pcall(vim.api.nvim_buf_set_name, buf, name)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].filetype = "sapdebugpreview"
	map_preview_keys(buf)
	return buf
end

map_watch_tab_keys = function(buf)
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		return
	end
	local opts = { buffer = buf, nowait = true, silent = true }
	for i, name in ipairs(SAPGUI_WATCH_TABS) do
		local tab_name = name
		vim.keymap.set("n", tostring(i), function()
			if select_watch_tab then
				select_watch_tab(tab_name, { focus = true })
			end
		end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: " .. tab_name }))
		vim.keymap.set("n", "v" .. tostring(i), function()
			if select_watch_tab then
				select_watch_tab(tab_name, { focus = true })
			end
		end, vim.tbl_extend("force", opts, { desc = "SAP Debugger: " .. tab_name }))
	end
end

local function ensure_side_layout()
	if not preview_active() then
		return
	end
	preview_buf = select(1, restore_or_make_panel(preview_win, preview_buf, "sap-debug-preview://variables"))
	restore_window_buffer(code_win, code_buf)
	local has_stack, has_watch
	stack_buf, has_stack = restore_or_make_panel(stack_win, stack_buf, "sap-debug-preview://callstack")
	watch_buf, has_watch = restore_or_make_panel(watch_win, watch_buf, "sap-debug-preview://watch")
	map_watch_tab_keys(watch_buf)
	close_duplicate_code_windows()
	if has_stack and has_watch then
		local side_width = math.max(46, math.floor(vim.o.columns * 0.34))
		pcall(vim.api.nvim_win_set_width, stack_win, side_width)
		pcall(vim.api.nvim_win_set_width, watch_win, side_width)
		vim.wo[stack_win].winfixwidth = true
		vim.wo[watch_win].winfixwidth = true
		vim.wo[watch_win].winfixheight = true
		return
	end

	local cur = vim.api.nvim_get_current_win()
	local base_win = (code_win and vim.api.nvim_win_is_valid(code_win)) and code_win or preview_win
	if not base_win or not vim.api.nvim_win_is_valid(base_win) then
		return
	end
	pcall(vim.api.nvim_set_current_win, base_win)
	vim.cmd("botright vertical split")
	stack_win = vim.api.nvim_get_current_win()
	stack_buf = make_side_buffer("sap-debug-preview://callstack")
	vim.api.nvim_win_set_buf(stack_win, stack_buf)
	local side_width = math.max(46, math.floor(vim.o.columns * 0.34))
	pcall(vim.api.nvim_win_set_width, stack_win, side_width)
	vim.wo[stack_win].winfixwidth = true
	set_debug_window_options(stack_win)

	vim.cmd("belowright split")
	watch_win = vim.api.nvim_get_current_win()
	watch_buf = make_side_buffer("sap-debug-preview://watch")
	map_watch_tab_keys(watch_buf)
	vim.api.nvim_win_set_buf(watch_win, watch_buf)
	pcall(vim.api.nvim_win_set_height, watch_win, math.max(10, math.floor(vim.o.lines * 0.28)))
	pcall(vim.api.nvim_win_set_width, watch_win, side_width)
	vim.wo[watch_win].winfixwidth = true
	vim.wo[watch_win].winfixheight = true
	set_debug_window_options(watch_win)
	if preview_win and vim.api.nvim_win_is_valid(preview_win) then
		pcall(vim.api.nvim_set_current_win, preview_win)
		restore_window_buffer(preview_win, preview_buf)
		vim.wo[preview_win].winfixheight = true
		set_debug_window_options(preview_win)
	end
	if code_win and vim.api.nvim_win_is_valid(code_win) then
		set_debug_window_options(code_win)
		map_code_debug_keys(vim.api.nvim_win_get_buf(code_win))
	end
	if cur and vim.api.nvim_win_is_valid(cur) then
		pcall(vim.api.nvim_set_current_win, cur)
	end
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

local function active_desktop()
	if cockpit.desktop and cockpit.desktop ~= "" then
		return canonical_desktop(cockpit.desktop)
	end
	local data_title = pane("Datos").title or ""
	if data_title:match("^Estructura:") then
		return "Estruct"
	end
	if data_title:match("^Tabla:") then
		return "Tablas"
	end
	if cockpit.active == "Datos" and data_title ~= "" and data_title ~= "Datos" then
		return "Data Explorer"
	end
	if cockpit.active == "Breakpoints" or cockpit.active == "Watch" then
		return "Vis.detallada"
	end
	return "Standard"
end

local function sapgui_tabline(items, active, with_index)
	local labels = {}
	for i, name in ipairs(items) do
		local label = with_index and (tostring(i) .. " " .. name) or name
		if name == active then
			label = "[" .. label .. "]"
		else
			label = " " .. label .. " "
		end
		labels[#labels + 1] = label
	end
	return table.concat(labels, " ")
end

local function fit_line(text, width)
	width = width or math.min(math.max(vim.o.columns, 96), 160)
	text = tostring(text or "")
	if #text >= width then
		return text:sub(1, width)
	end
	return text .. string.rep(" ", width - #text)
end

local function sapgui_rule(left, fill)
	local width = math.min(math.max(vim.o.columns, 96), 160)
	left = left or ""
	fill = fill or "─"
	if #left >= width then
		return left:sub(1, width)
	end
	return left .. string.rep(fill, width - #left)
end

local function frame_summary()
	local f = cockpit.current_frame or {}
	local s = dbg.session or {}
	local program = f.program or s.program or "?"
	local include = f.include or s.include or program
	local line = f.line or s.line or "?"
	local event = f.eventName and ("  Evento: " .. f.eventName) or ""
	local sid = s.debugSessionId and ("  DebugSession: " .. s.debugSessionId) or ""
	return string.format(
		"Usuario: %s  Programa: %s  Include: %s  Línea: %s%s%s",
		s.user or "?",
		program,
		include,
		tostring(line),
		event,
		sid
	)
end

local function cockpit_lines()
	local p = pane(cockpit.active)
	local lines = {
		sapgui_rule("┌─ ABAP Debugger (New) "),
		fit_line("│ Debugger  Edit  Goto  Breakpoints  Settings  System  Help"),
		fit_line("│ F8 Continue  F5 Single Step  F6 Execute  F7 Return  |  r Refresh  o Display  <Enter> Source"),
		sapgui_rule("├─ " .. frame_summary() .. " "),
		fit_line("│ Desktop      " .. sapgui_tabline(SAPGUI_DESKTOPS, active_desktop(), false)),
		fit_line("│ Acceso       S Estruct  T Tablas  O Objetos  D Vis.detallada  E Data Explorer  |  o abre  = set  / filtro"),
		fit_line("│ Herramientas " .. sapgui_tabline(COCKPIT_TABS, cockpit.active, true)),
		sapgui_rule("├─ " .. (p.title or cockpit.active) .. " "),
		"",
	}
	cockpit.data_start_line = #lines + 1
	vim.list_extend(lines, p.lines or { "(sin datos)" })
	lines[#lines + 1] = sapgui_rule("└")
	return lines
end

local function apply_cockpit_highlights()
	if not preview_buf or not vim.api.nvim_buf_is_valid(preview_buf) then
		return
	end
	local ns = vim.api.nvim_create_namespace("sap_nvim_debug_cockpit")
	vim.api.nvim_buf_clear_namespace(preview_buf, ns, 0, -1)
	local function hi(line, group)
		pcall(vim.api.nvim_buf_add_highlight, preview_buf, ns, group, line - 1, 0, -1)
	end
	hi(1, "SapDebugGuiTitle")
	hi(2, "SapDebugGuiMenu")
	hi(3, "SapDebugGuiToolbar")
	hi(4, "SapDebugGuiStatus")
	hi(5, "SapDebugGuiTabs")
	hi(6, "SapDebugGuiTabs")
	hi(7, "SapDebugGuiTabs")
	hi(8, "SapDebugGuiPanel")
	local data_start = cockpit.data_start_line or 9
	local lines = vim.api.nvim_buf_line_count(preview_buf)
	for line = data_start, lines - 1 do
		if line == data_start or line == data_start + 1 then
			hi(line, "SapDebugGuiGridHeader")
		end
	end
	hi(lines, "SapDebugGuiPanel")
end

local function side_title(title)
	local width = 46
	local win = (title == "Call Stack") and stack_win or watch_win
	if win and vim.api.nvim_win_is_valid(win) then
		width = math.max(24, vim.api.nvim_win_get_width(win) - 1)
	end
	local left = "┌─ " .. title .. " "
	return {
		left .. string.rep("─", math.max(0, width - #left)),
	}
end

local function side_footer()
	local width = 46
	local win = watch_win or stack_win
	if win and vim.api.nvim_win_is_valid(win) then
		width = math.max(24, vim.api.nvim_win_get_width(win) - 1)
	end
	return "└" .. string.rep("─", math.max(0, width - 1))
end

local function set_panel_lines(buf, lines)
	if not side_buf_valid(buf) then
		return
	end
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function apply_side_highlights(buf)
	if not side_buf_valid(buf) then
		return
	end
	local ns = vim.api.nvim_create_namespace("sap_nvim_debug_side")
	vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
	local count = vim.api.nvim_buf_line_count(buf)
	pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapDebugGuiPanel", 0, 0, -1)
	if count > 1 then
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapDebugGuiGridHeader", 1, 0, -1)
	end
	if count > 0 then
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapDebugGuiPanel", count - 1, 0, -1)
	end
end

local function render_stack_panel()
	if not side_buf_valid(stack_buf) then
		return
	end
	local p = pane("Stack")
	local lines = side_title("Call Stack")
	vim.list_extend(lines, p.lines or { "(sin stack disponible)" })
	lines[#lines + 1] = ""
	lines[#lines + 1] = "Enter cambia frame"
	lines[#lines + 1] = "5 abre Stack"
	lines[#lines + 1] = side_footer()
	set_panel_lines(stack_buf, lines)
	apply_side_highlights(stack_buf)
end

local function watch_tab_lines()
	local out = {}
	local active = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	for i, name in ipairs(SAPGUI_WATCH_TABS) do
		local marker = active == name and "▶" or " "
		out[#out + 1] = string.format("%s %d %s", marker, i, name)
	end
	return out
end

local function render_watch_panel()
	if not side_buf_valid(watch_buf) then
		return
	end
	local tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	local lines = side_title("Variables")
	vim.list_extend(lines, watch_tab_lines())
	lines[#lines + 1] = ""
	if tab == "Variables1" or tab == "Variables2" then
		lines[#lines + 1] = "Entrada  > pulsa a, i o Enter para escribir"
		local p = pane(tab == "Variables1" and "Watch" or "Variables2")
		local exprs = tab == "Variables1" and cockpit.watches or cockpit.watches2
		if #exprs == 0 then
			lines[#lines + 1] = "(sin expresiones)"
		else
			vim.list_extend(lines, p.lines or {})
		end
	elseif tab == "Locals" then
		local p = pane("Locales")
		vim.list_extend(lines, p.lines or { "(sin locales)" })
	elseif tab == "Globals" then
		local p = pane("Globales")
		vim.list_extend(lines, p.lines or { "(sin globales)" })
	elseif tab == "Auto" then
		local f = cockpit.current_frame or {}
		lines[#lines + 1] = "Frame actual"
		lines[#lines + 1] = "Programa │ " .. tostring(f.program or "?")
		lines[#lines + 1] = "Include  │ " .. tostring(f.include or f.program or "?")
		lines[#lines + 1] = "Línea    │ " .. tostring(f.line or "?")
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Variables recientes"
		local p = pane("Locales")
		for i, line in ipairs(p.lines or {}) do
			if i > 8 then
				break
			end
			lines[#lines + 1] = line
		end
	elseif tab == "Memory" then
		local s = dbg.session or {}
		lines[#lines + 1] = "Sesión"
		lines[#lines + 1] = "Usuario        │ " .. tostring(s.user or "?")
		lines[#lines + 1] = "Debug Session  │ " .. tostring(s.debugSessionId or "?")
		lines[#lines + 1] = "Stack frames   │ " .. tostring(#(cockpit.stack_frames or {}))
		lines[#lines + 1] = "Variables1     │ " .. tostring(#cockpit.watches)
		lines[#lines + 1] = "Variables2     │ " .. tostring(#cockpit.watches2)
		lines[#lines + 1] = ""
		lines[#lines + 1] = "Tablas abiertas"
		if last_preview and last_preview.table then
			lines[#lines + 1] = string.format("%s │ %s filas", last_preview.table.name or "?", tostring(last_preview.table.total or "?"))
		else
			lines[#lines + 1] = "(sin tabla abierta)"
		end
	else
		lines[#lines + 1] = "(sin datos)"
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "1..6/v1..v6 cambia pestaña"
	lines[#lines + 1] = "o abre  ·  a/i/Enter añade  ·  e edita  ·  d borra"
	lines[#lines + 1] = side_footer()
	set_panel_lines(watch_buf, lines)
	apply_side_highlights(watch_buf)
end

local function render_side_panels()
	if not preview_active() then
		return
	end
	ensure_side_layout()
	if dbg.session and refresh_stack_side and not cockpit.stack_loading then
		local stack_lines = pane("Stack").lines or {}
		if #stack_lines == 0 or stack_lines[1] == "(sin datos)" or stack_lines[1] == "(sin stack disponible)" then
			refresh_stack_side()
		end
	end
	render_stack_panel()
	render_watch_panel()
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
	apply_cockpit_highlights()
	render_side_panels()

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
			pcall(vim.api.nvim_win_set_cursor, win, { math.min(cockpit.data_start_line or 9, #out), 0 })
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
	if tab == "Datos" then
		if title:match("^Estructura:") then
			cockpit.desktop = "Estruct"
		elseif title:match("^Tabla:") then
			cockpit.desktop = "Tablas"
		elseif title:match("^Variable:") then
			cockpit.desktop = "Vis.detallada"
		end
	end
	if opts.actions then
		p.actions = opts.actions
	end
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

select_desktop = function(name, opts)
	opts = opts or {}
	name = canonical_desktop(name or "Standard")
	cockpit.desktop = name
	save_layout()
	if name == "Standard" then
		render_cockpit({ focus = false, preserve_cursor = true })
		if opts.focus and code_win and vim.api.nvim_win_is_valid(code_win) then
			pcall(vim.api.nvim_set_current_win, code_win)
		end
		return
	end
	if name == "Estruct" then
		open_preview("Estruct", {
			"Selecciona una workarea/estructura en Locales, Globals o Variables y pulsa o.",
			"Ejemplos: wa_alv, ls_cabecera, <fs_line>.",
			"También puedes situarte sobre una variable en el código y usar <leader>dT.",
		}, { pane = "Datos", focus = opts.focus, activate = true })
	elseif name == "Tablas" then
		open_preview("Tablas", {
			"Selecciona una tabla interna en Locales, Globals o Variables y pulsa o.",
			"Ejemplos: lt_alv, gt_items, rv_table_bd.",
			"En una tabla abierta usa ]/[ para paginar.",
		}, { pane = "Datos", focus = opts.focus, activate = true })
	elseif name == "Objetos" then
		if refresh_objects_desktop then
			refresh_objects_desktop(opts)
		end
	elseif name == "Vis.detallada" then
		open_preview("Vis.detallada", {
			"Vista detallada del valor seleccionado.",
			"Usa o sobre una variable, fila, campo o watch para abrir su detalle aquí.",
			"Usa 5 para Stack, 6 para Breakpoints, 4 para Watch.",
		}, { pane = "Datos", focus = opts.focus, activate = true })
	elseif name == "Data Explorer" then
		if refresh_data_explorer then
			refresh_data_explorer(opts)
		end
	else
		render_cockpit({ focus = opts.focus, preserve_cursor = true })
	end
end
M.select_desktop = select_desktop

local function looks_like_object(v)
	local name = tostring(v.name or ""):upper()
	local typ = tostring(v.type or v.meta or ""):upper()
	return v.meta == "object"
		or typ:find("REF TO", 1, true) ~= nil
		or typ:find("OBJECT", 1, true) ~= nil
		or typ:find("CLASS", 1, true) ~= nil
		or name:match("^[LG]O_") ~= nil
end

refresh_objects_desktop = function(opts)
	opts = opts or {}
	if not dbg.session then
		open_preview("Objetos", { "No hay sesión de debug activa." }, { pane = "Datos", focus = opts.focus, activate = true })
		return
	end
	dbg.get_variables({ "@LOCALS", "@GLOBALS" }, function(vars)
		local lines = {}
		local actions = {}
		local name_w, type_w = 8, 10
		for _, v in ipairs(vars or {}) do
			if looks_like_object(v) then
				name_w = math.min(38, math.max(name_w, #(v.name or "?")))
				type_w = math.min(42, math.max(type_w, #(v.type or v.meta or "")))
			end
		end
		lines[#lines + 1] = string.format("%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s", "OBJECT", "TYPE", "VALUE")
		lines[#lines + 1] = string.rep("-", vim.fn.strdisplaywidth(lines[1]))
		for _, v in ipairs(vars or {}) do
			if looks_like_object(v) then
				local idx = #lines + 1
				lines[idx] = string.format(
					"%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s",
					short_value(v.name or "?", name_w),
					short_value(v.type or v.meta or "", type_w),
					short_value(var_value(v), 120)
				)
				actions[idx] = { kind = "object", label = v.name, var = v }
			end
		end
		if #lines == 2 then
			lines[#lines + 1] = "No se encontraron referencias de objeto en Locales/Globals."
			lines[#lines + 1] = "Añade una referencia en Variables1/2 o abre Locals/Globals y pulsa o sobre lo_* / go_*."
		else
			lines[#lines + 1] = ""
			lines[#lines + 1] = "Pulsa o sobre una referencia para abrir atributos/hijos si SAP los expone."
		end
		open_preview("Objetos", lines, { pane = "Datos", focus = opts.focus, activate = true, actions = actions })
	end)
end

local function data_explorer_matches(row, filter)
	filter = vim.trim(tostring(filter or "")):lower()
	if filter == "" then
		return true
	end
	local haystack = table.concat({
		row.source or "",
		row.name or "",
		row.type or "",
		row.value or "",
		row.kind or "",
	}, "\n"):lower()
	return haystack:find(filter, 1, true) ~= nil
end

local function data_explorer_add(rows, source, v)
	if not v then
		return
	end
	rows[#rows + 1] = {
		source = source,
		name = v.name or v.id or "?",
		type = v.type or v.meta or "",
		value = var_value(v),
		kind = v.meta or (v.expandable and "structure" or "simple"),
		var = v,
	}
end

local function render_data_explorer_rows(rows, opts)
	opts = opts or {}
	local state = cockpit.data_explorer
	local filtered = {}
	for _, row in ipairs(rows or {}) do
		if data_explorer_matches(row, state.filter) then
			filtered[#filtered + 1] = row
		end
	end
	table.sort(filtered, function(a, b)
		if a.source == b.source then
			return tostring(a.name) < tostring(b.name)
		end
		return tostring(a.source) < tostring(b.source)
	end)

	local page_size = math.max(1, tonumber(state.page_size) or 20)
	local max_page = math.max(0, math.ceil(math.max(#filtered, 1) / page_size) - 1)
	state.page = math.max(0, math.min(tonumber(state.page) or 0, max_page))
	local offset = state.page * page_size
	local last = math.min(#filtered, offset + page_size)
	local pages = max_page + 1
	local filter_label = vim.trim(tostring(state.filter or "")) ~= "" and (" · filtro: " .. state.filter) or ""
	local title = string.format("Data Explorer (%d/%d · pág %d/%d%s)", #filtered, #rows, state.page + 1, pages, filter_label)

	local lines = {
		string.format("%-12s │ %-32s │ %-24s │ %s", "SOURCE", "NAME", "TYPE", "VALUE"),
		string.rep("-", 90),
	}
	local actions = {}
	if #filtered == 0 then
		lines[#lines + 1] = vim.trim(tostring(state.filter or "")) ~= "" and "Sin resultados para el filtro actual."
			or "(sin variables disponibles)"
	else
		for idx = offset + 1, last do
			local row = filtered[idx]
			local line_idx = #lines + 1
			lines[line_idx] = string.format(
				"%-12s │ %-32s │ %-24s │ %s",
				short_value(row.source, 12),
				short_value(row.name, 32),
				short_value(row.type, 24),
				short_value(row.value, 120)
			)
			actions[line_idx] = { kind = row.kind, label = row.name, var = row.var }
		end
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "/ o f filtra · ]/[ pagina · o abre estructura/tabla/objeto · = set escalar"
	save_layout()
	open_preview(title, lines, {
		pane = "Datos",
		focus = opts.focus == true,
		activate = opts.activate ~= false,
		preserve_cursor = opts.preserve_cursor or opts.focus ~= true,
		actions = actions,
	})
end

refresh_data_explorer = function(opts)
	opts = opts or {}
	cockpit.desktop = "Data Explorer"
	if not dbg.session then
		open_preview("Data Explorer", {
			"No hay sesión de debug activa.",
			"Abre una sesión para explorar Locales, Globales y Variables1/2.",
		}, {
			pane = "Datos",
			focus = opts.focus == true,
			activate = opts.activate ~= false,
			preserve_cursor = opts.preserve_cursor or opts.focus ~= true,
		})
		return
	end

	dbg.get_variables({ "@LOCALS", "@GLOBALS" }, function(vars)
		local rows = {}
		for _, v in ipairs(vars or {}) do
			local src = "Scope"
			local id = tostring(v.id or "")
			if id:find("@GLOBALS", 1, true) then
				src = "Globals"
			elseif id:find("@LOCALS", 1, true) then
				src = "Locals"
			end
			data_explorer_add(rows, src, v)
		end

		local exprs = {}
		for _, expr in ipairs(cockpit.watches or {}) do
			exprs[#exprs + 1] = { source = "Variables1", expr = expr }
		end
		for _, expr in ipairs(cockpit.watches2 or {}) do
			exprs[#exprs + 1] = { source = "Variables2", expr = expr }
		end
		if #exprs == 0 then
			render_data_explorer_rows(rows, opts)
			return
		end

		local ids = {}
		for _, item in ipairs(exprs) do
			ids[#ids + 1] = tostring(item.expr or ""):upper()
		end
		dbg.get_vars_by_id(ids, function(watch_vars)
			for i, item in ipairs(exprs) do
				local v = watch_vars and watch_vars[i] or nil
				if v then
					if not v.name or v.name == "" then
						v.name = item.expr
					end
					data_explorer_add(rows, item.source, v)
				else
					rows[#rows + 1] = {
						source = item.source,
						name = item.expr,
						type = "",
						value = "no evaluable o fuera de scope",
						kind = "watch",
					}
				end
			end
			render_data_explorer_rows(rows, opts)
		end)
	end)
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
	local actions = {}
	for _, f in ipairs(fields) do
		local idx = #lines + 1
		lines[idx] = string.format("%-" .. w .. "s │ %s", f.name or "?", f.value or "")
		actions[idx] = { kind = "field", label = f.name, var = f }
	end
	opts.actions = actions
	open_preview("Estructura: " .. name, lines, opts)
end

-- pageinfo (opcional) = { offset, total, page, page_size } para paginar tablas grandes:
-- numera las filas con su índice real y muestra "filas X–Y de N" en la cabecera.
local function render_table(name, rows, cells, filter_user, opts, pageinfo)
	opts = normalize_preview_opts(opts)
	local row_offset = (pageinfo and pageinfo.offset) or 0
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

	-- Construye el título: "filas X–Y de N · pág p/total · ]/[ avanza" si está paginada.
	local function make_title()
		if pageinfo and pageinfo.total and pageinfo.page_size and pageinfo.total > pageinfo.page_size then
			local from = #rows > 0 and (row_offset + 1) or row_offset
			local to = row_offset + #rows
			local pages = math.max(1, math.ceil(pageinfo.total / pageinfo.page_size))
			return string.format(
				"Tabla: %s (filas %d–%d de %d · pág %d/%d · ]/[ avanza)",
				name,
				from,
				to,
				pageinfo.total,
				(pageinfo.page or 0) + 1,
				pages
			)
		end
		return "Tabla: " .. name .. " (" .. #rows .. " filas)"
	end

	if #col_order == 0 or #rows == 0 then
		local lines = {}
		local actions = {}
		for i, r in ipairs(rows) do
			local idx = #lines + 1
			lines[idx] = string.format("%6d │ %s", row_offset + i, r.value or r.name or "")
			actions[idx] = { kind = "row", label = r.name or ("[" .. tostring(row_offset + i) .. "]"), var = r }
		end
		opts.actions = actions
		open_preview(make_title(), lines, opts)
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
	local actions = {}
	local sep = {}
	for _, col in ipairs(col_order) do
		sep[#sep + 1] = string.rep("─", widths[col])
	end
	lines[#lines + 1] = table.concat(sep, "─┼─")
	for _, r in ipairs(rows) do
		local rd = by_row[r.id] or {}
		local idx = #lines + 1
		lines[idx] = fmt(function(col)
			return rd[col]
		end)
		actions[idx] = { kind = "row", label = r.name or ("[" .. tostring(row_offset + idx - 2) .. "]"), var = r }
	end

	local title = make_title()
	if filter_user then
		title = title .. " [FILTRO: " .. filter_user .. "]"
	end
	opts.actions = actions
	open_preview(title, lines, opts)
end

-- Tamaño de página = MAX_CHILDREN (no es un tope duro: con ]/[ se navegan todas las filas).
local PAGE_SIZE = dbg.MAX_CHILDREN or 500

-- Carga y renderiza UNA página (clampada) de una tabla grande ya resuelta (tbl = {id,name,total,
-- filter_user,page}). Reutiliza dbg.get_table_rows con offset/limit para no truncar la tabla.
local function load_table_page(tbl, page, opts)
	if not dbg.session then
		return
	end
	local total = tbl.total or 0
	local max_page = math.max(0, math.ceil(math.max(total, 1) / PAGE_SIZE) - 1)
	page = math.max(0, math.min(page or 0, max_page))
	tbl.page = page
	local offset = page * PAGE_SIZE
	local pageinfo = { offset = offset, total = total, page = page, page_size = PAGE_SIZE }
	dbg.get_table_rows(tbl.id, total, function(rows)
		local first = rows[1]
		local function finish(cells)
			render_table(tbl.name, rows, cells or {}, tbl.filter_user, opts, pageinfo)
		end
		if first and first.expandable then
			local ids = {}
			for _, row in ipairs(rows) do
				ids[#ids + 1] = row.id
			end
			dbg.get_variables(ids, function(cells)
				finish(cells)
			end)
		else
			finish(nil)
		end
	end, offset, PAGE_SIZE)
end

open_debug_variable = function(label, var, opts)
	opts = opts or {}
	if not dbg.session or not var then
		return
	end
	label = tostring(label or var.name or var.id or "?"):upper()
	local prev_page = (last_preview and last_preview.table and last_preview.name == label)
			and last_preview.table.page
		or 0
	local preview_opts = {
		focus = opts.focus ~= false,
		pane = "Datos",
		activate = true,
		preserve_cursor = opts.preserve_cursor,
	}

	local function render(v)
		if not v then
			notify("No se pudo evaluar " .. label .. ".", vim.log.levels.WARN)
			return
		end
		last_preview = {
			mode = "variable",
			name = label,
			id = v.id or var.id,
			kind = v.meta or (v.expandable and "structure" or "scalar"),
			mine_only = false,
		}
		if v.meta == "table" then
			if (v.table_lines or 0) == 0 then
				open_preview("Tabla: " .. label .. " (vacía)", { "(0 filas)" }, preview_opts)
				return
			end
			last_preview.table = {
				id = v.id,
				name = label,
				total = v.table_lines or 0,
				filter_user = nil,
				page = prev_page,
			}
			load_table_page(last_preview.table, prev_page, preview_opts)
		elseif v.meta == "structure" or v.expandable then
			dbg.get_variables(v.id, function(fields)
				render_struct(label, fields or {}, preview_opts)
			end)
		else
			open_preview("Variable: " .. label, { (v.name or label) .. " : " .. (v.value or "") }, preview_opts)
		end
	end

	if var.meta then
		render(var)
		return
	end
	if var.id then
		dbg.get_vars_by_id(var.id, function(vars)
			render(vars and vars[1])
		end)
	end
end

local function current_pane_action()
	if not preview_active() then
		return nil
	end
	local win = preview_window()
	if not win then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(win)[1]
	local pane_line = row - (cockpit.data_start_line or 9) + 1
	if pane_line < 1 then
		return nil
	end
	local p = pane(cockpit.active)
	return p.actions and p.actions[pane_line] or nil
end

local function current_right_pane_action()
	if not (watch_win and vim.api.nvim_win_is_valid(watch_win)) then
		return nil
	end
	local row = vim.api.nvim_win_get_cursor(watch_win)[1]
	local tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	local pane_name
	local start_line
	if tab == "Variables1" then
		pane_name = "Watch"
		start_line = 10
	elseif tab == "Variables2" then
		pane_name = "Variables2"
		start_line = 10
	elseif tab == "Locals" then
		pane_name = "Locales"
		start_line = 9
	elseif tab == "Globals" then
		pane_name = "Globales"
		start_line = 9
	else
		return nil
	end
	local pane_line = row - start_line + 1
	if pane_line < 1 then
		return nil
	end
	local p = pane(pane_name)
	return p.actions and p.actions[pane_line] or nil
end

function M.open_selected_variable()
	local action = current_pane_action()
	if not action or not action.var then
		notify("No hay variable expandible bajo el cursor.", vim.log.levels.WARN)
		return
	end
	open_debug_variable(action.label, action.var, { focus = true })
end

function M.open_selected_right_variable()
	local action = current_right_pane_action()
	if not action or not action.var then
		notify("No hay variable expandible bajo el cursor.", vim.log.levels.WARN)
		return
	end
	open_debug_variable(action.label, action.var, { focus = true })
end

local function selected_variable_action(from_right)
	local action = from_right and current_right_pane_action() or current_pane_action()
	if action and action.var then
		return action
	end
	local name = vim.fn.expand("<cexpr>")
	if name and name ~= "" then
		name = name:upper()
		return { label = name, var = { id = name, name = name, value = "" } }
	end
	return nil
end

function M.set_variable_value(name, value, opts)
	opts = opts or {}
	name = vim.trim(tostring(name or ""))
	if name == "" then
		notify("Variable vacía.", vim.log.levels.WARN)
		return
	end
	local cur_win = vim.api.nvim_get_current_win()
	dbg.set_variable(name, value, function(ok, err)
		if ok then
			add_log("variable modificada: " .. name)
			notify("Variable modificada: " .. name, vim.log.levels.INFO)
			M.refresh_active()
		else
			notify(tostring(err or "No se pudo modificar la variable."), vim.log.levels.WARN)
		end
		if opts.restore_focus ~= false and cur_win and vim.api.nvim_win_is_valid(cur_win) then
			pcall(vim.api.nvim_set_current_win, cur_win)
		end
	end)
end

function M.set_selected_variable(from_right)
	local action = selected_variable_action(from_right)
	if not action or not action.var then
		notify("No hay variable bajo el cursor.", vim.log.levels.WARN)
		return
	end
	if dbg.can_set_variable and not dbg.can_set_variable() then
		notify("Set variable desactivado por config productive.allow_debug_set_variable=false.", vim.log.levels.WARN)
		return
	end
	local v = action.var
	local id = v.id or action.label or v.name
	local label = action.label or v.name or id
	if not id or id == "" then
		notify("No hay ID ADT para la variable seleccionada.", vim.log.levels.WARN)
		return
	end
	vim.ui.input({ prompt = "Set " .. tostring(label) .. ": ", default = tostring(v.value or "") }, function(input)
		if input == nil then
			return
		end
		M.set_variable_value(id, input)
	end)
end

function M.set_variable_under_cursor()
	M.set_selected_variable(false)
end

-- Navegación de páginas: ]/> avanza, [/< retrocede. Sólo aplica sobre la tabla del panel Datos.
function M.table_page(delta)
	if cockpit.active == "Datos" and canonical_desktop(cockpit.desktop) == "Data Explorer" then
		M.data_explorer_page(delta)
		return
	end
	if cockpit.active ~= "Datos" or not (last_preview and last_preview.table) then
		return
	end
	local tbl = last_preview.table
	load_table_page(tbl, (tbl.page or 0) + delta, {
		focus = true,
		pane = "Datos",
		activate = true,
		preserve_cursor = false,
	})
end

function M.data_explorer_page(delta)
	cockpit.data_explorer.page = math.max(0, (tonumber(cockpit.data_explorer.page) or 0) + (tonumber(delta) or 0))
	save_layout()
	if refresh_data_explorer then
		refresh_data_explorer({ focus = false, activate = true, preserve_cursor = true })
	end
end

function M.set_data_explorer_filter(filter)
	if filter ~= nil then
		cockpit.data_explorer.filter = vim.trim(tostring(filter or ""))
		cockpit.data_explorer.page = 0
		save_layout()
		if refresh_data_explorer then
			refresh_data_explorer({ focus = false, activate = true, preserve_cursor = true })
		end
		return
	end
	vim.ui.input({ prompt = "Data Explorer filtro: ", default = cockpit.data_explorer.filter or "" }, function(input)
		if input == nil then
			return
		end
		M.set_data_explorer_filter(input)
	end)
end

short_value = function(value, max_width)
	value = tostring(value or "")
	value = value:gsub("\r", " "):gsub("\n", " ")
	max_width = max_width or 90
	if #value > max_width then
		return value:sub(1, max_width - 1) .. "…"
	end
	return value
end

var_value = function(v)
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
	local actions = {}
	local name_w, type_w = 4, 4
	for _, v in ipairs(vars) do
		name_w = math.min(38, math.max(name_w, #(v.name or "?")))
		type_w = math.min(34, math.max(type_w, #(v.type or v.meta or "")))
	end
	local header = string.format("%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s", "NAME", "TYPE", "VALUE")
	lines[#lines + 1] = header
	lines[#lines + 1] = string.rep("-", vim.fn.strdisplaywidth(header))
	for _, v in ipairs(vars) do
		local idx = #lines + 1
		lines[idx] = string.format(
			"%-" .. name_w .. "s │ %-" .. type_w .. "s │ %s",
			short_value(v.name or "?", name_w),
			short_value(v.type or v.meta or "", type_w),
			short_value(var_value(v), 120)
		)
		actions[idx] = { kind = "var", label = v.name, var = v }
	end
	if #vars == 0 then
		lines[#lines + 1] = "(sin variables)"
	end
	open_preview(title, lines, {
		pane = opts.pane or title,
		focus = opts.focus,
		preserve_cursor = opts.preserve_cursor,
		actions = actions,
		activate = opts.activate,
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
			activate = opts.activate,
		})
	end)
end

local function render_watch_list(pane_name, exprs, opts)
	opts = opts or {}
	if #exprs == 0 then
		open_preview(pane_name, {
			"No hay expresiones.",
			"Pulsa a, i o Enter en Variables1/2 para añadir una expresión.",
		}, { pane = pane_name, focus = opts.focus, preserve_cursor = opts.preserve_cursor, activate = opts.activate })
		return
	end
	if not dbg.session then
		open_preview(pane_name, { "No hay sesión de debug activa." }, { pane = pane_name, focus = opts.focus, activate = opts.activate })
		return
	end

	local ids = {}
	for _, expr in ipairs(exprs) do
		ids[#ids + 1] = expr:upper()
	end
	dbg.get_vars_by_id(ids, function(vars)
		local lines = {}
		local actions = {}
		local by_name = {}
		for i, v in ipairs(vars or {}) do
			by_name[(v.name or v.id or ids[i] or ""):upper()] = v
			if ids[i] then
				by_name[ids[i]] = by_name[ids[i]] or v
			end
		end
		for i, expr in ipairs(exprs) do
			local v = by_name[expr:upper()] or vars[i]
			if v then
				local idx = #lines + 1
				lines[idx] = string.format("%2d │ %-32s │ %-24s │ %s", i, expr, v.type or v.meta or "", short_value(var_value(v), 120))
				actions[idx] = { kind = "watch", label = expr, var = v }
			else
				lines[#lines + 1] = string.format("%2d │ %-32s │ %s", i, expr, "no evaluable o fuera de scope")
			end
		end
		open_preview(pane_name, lines, {
			pane = pane_name,
			focus = opts.focus,
			preserve_cursor = opts.preserve_cursor,
			actions = actions,
			activate = opts.activate,
		})
		render_watch_panel()
	end)
end

local function refresh_watch(opts)
	opts = opts or {}
	render_watch_list("Watch", cockpit.watches, opts)
end

select_watch_tab = function(name, opts)
	opts = opts or {}
	cockpit.active_watch_tab = canonical_watch_tab(name or cockpit.active_watch_tab or "Variables1")
	save_layout()
	if cockpit.active_watch_tab == "Variables1" then
		render_watch_list("Watch", cockpit.watches, { focus = false, activate = false })
	elseif cockpit.active_watch_tab == "Variables2" then
		render_watch_list("Variables2", cockpit.watches2, { focus = false, activate = false })
	elseif cockpit.active_watch_tab == "Locals" then
		refresh_scope("@LOCALS", "Locales", { focus = false, activate = false, preserve_cursor = true })
	elseif cockpit.active_watch_tab == "Globals" then
		refresh_scope("@GLOBALS", "Globales", { focus = false, activate = false, preserve_cursor = true })
	end
	render_watch_panel()
	if opts.focus and watch_win and vim.api.nvim_win_is_valid(watch_win) then
		pcall(vim.api.nvim_set_current_win, watch_win)
	end
end
M.select_watch_tab = select_watch_tab

refresh_stack_side = function()
	if not dbg.session then
		local p = pane("Stack")
		p.title = "Call Stack"
		p.lines = { "No hay sesión de debug activa." }
		render_stack_panel()
		return
	end
	cockpit.stack_loading = true
	dbg.get_stack(function(frames)
		cockpit.stack_loading = false
		local lines = {}
		cockpit.current_frame = frames and frames[1] or cockpit.current_frame
		cockpit.stack_frames = frames or {}
		for i, frame in ipairs(frames or {}) do
			local loc = (frame.include or frame.program or "?") .. ":" .. tostring(frame.line or 1)
			local extra = frame.eventName and (" · " .. frame.eventName) or ""
			local cur = cockpit.current_frame or {}
			local marker = ((cur.stackUri and frame.stackUri and cur.stackUri == frame.stackUri) or (not cur.stackUri and i == 1)) and "▶" or " "
			lines[#lines + 1] = string.format("%s %2d │ %-30s │ %s%s", marker, i, loc, frame.program or "?", extra)
		end
		if #lines == 0 then
			lines[#lines + 1] = "(sin stack disponible)"
		end
		local p = pane("Stack")
		p.title = "Call Stack"
		p.lines = lines
		render_stack_panel()
		if cockpit.active == "Stack" and preview_active() then
			render_cockpit({ focus = false, preserve_cursor = true })
		end
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
		cockpit.current_frame = frames and frames[1] or cockpit.current_frame
		cockpit.stack_frames = frames or {}
		for i, frame in ipairs(frames or {}) do
			local loc = (frame.include or frame.program or "?") .. ":" .. tostring(frame.line or 1)
			local extra = frame.eventName and (" · " .. frame.eventName) or ""
			local cur = cockpit.current_frame or {}
			local marker = ((cur.stackUri and frame.stackUri and cur.stackUri == frame.stackUri) or (not cur.stackUri and i == 1)) and "▶" or " "
			lines[#lines + 1] = string.format("%s %2d │ %-44s │ %s%s", marker, i, loc, frame.program or "?", extra)
		end
		if #lines == 0 then
			lines[#lines + 1] = "(sin stack disponible)"
		end
		local p = pane("Stack")
		p.title = "Call Stack"
		p.lines = lines
		render_stack_panel()
		open_preview("Stack", lines, { pane = "Stack", focus = opts.focus, preserve_cursor = opts.preserve_cursor })
	end)
end

local function focus_stack_frame_code(frame)
	if not frame then
		return
	end
	M.jump_to_code()
	if not (code_win and vim.api.nvim_win_is_valid(code_win)) then
		return
	end
	local bufnr = vim.api.nvim_win_get_buf(code_win)
	local bname = vim.api.nvim_buf_get_name(bufnr):upper()
	local include = tostring(frame.include or frame.program or ""):upper()
	if include ~= "" and bname ~= "" and not bname:find(include, 1, true) then
		return
	end
	local line = tonumber(frame.line)
	if line and line > 0 then
		local max_line = math.max(1, vim.api.nvim_buf_line_count(bufnr))
		pcall(vim.api.nvim_win_set_cursor, code_win, { math.min(line, max_line), 0 })
	end
end

function M.select_stack_under_cursor()
	if not dbg.session or not (stack_win and vim.api.nvim_win_is_valid(stack_win)) then
		return
	end
	local row = vim.api.nvim_win_get_cursor(stack_win)[1]
	-- Panel stack: 1 borde; desde la 2 empiezan frames.
	local idx = row - 1
	local frame = cockpit.stack_frames and cockpit.stack_frames[idx]
	if not frame then
		return
	end
	cockpit.current_frame = frame
	if frame.stackUri then
		dbg.goto_stack(frame.stackUri, function()
			add_log("stack seleccionado: " .. (frame.include or frame.program or "?") .. ":" .. tostring(frame.line or "?"))
			refresh_stack_side()
			if canonical_desktop(cockpit.desktop) == "Objetos" and refresh_objects_desktop then
				refresh_objects_desktop({ focus = false })
			elseif cockpit.active_watch_tab == "Locals" or cockpit.active_watch_tab == "Globals" then
				select_watch_tab(cockpit.active_watch_tab, { focus = false })
			else
				render_cockpit({ focus = false, preserve_cursor = true })
			end
			focus_stack_frame_code(frame)
		end)
	else
		render_stack_panel()
		focus_stack_frame_code(frame)
	end
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
		if canonical_desktop(cockpit.desktop) == "Data Explorer" and refresh_data_explorer then
			refresh_data_explorer({
				focus = opts.focus,
				activate = true,
				preserve_cursor = opts.preserve_cursor,
			})
		elseif last_preview and dbg.session then
			refresh_last_preview({
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

function M.open_cockpit(opts)
	opts = opts or {}
	local focus = opts.focus ~= false
	M.refresh_pane(cockpit.active or "Datos", { focus = focus, preserve_cursor = opts.preserve_cursor })
	if focus and code_win and vim.api.nvim_win_is_valid(code_win) then
		pcall(vim.api.nvim_set_current_win, code_win)
	end
end

function M._debug_state()
	return {
		active = cockpit.active,
		desktop = canonical_desktop(cockpit.desktop),
		active_watch_tab = canonical_watch_tab(cockpit.active_watch_tab),
		watches = vim.deepcopy(cockpit.watches),
		watches2 = vim.deepcopy(cockpit.watches2),
		data_explorer = vim.deepcopy(cockpit.data_explorer),
		last_preview = vim.deepcopy(last_preview),
		bufs = {
			code = code_buf,
			preview = preview_buf,
			stack = stack_buf,
			watch = watch_buf,
		},
		wins = {
			code = code_win,
			preview = preview_win,
			stack = stack_win,
			watch = watch_win,
		},
		desktop_tabs = vim.deepcopy(SAPGUI_DESKTOPS),
		watch_tabs = vim.deepcopy(SAPGUI_WATCH_TABS),
	}
end

function M.add_watch(expr)
	if expr and expr ~= "" then
		cockpit.active_watch_tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
		local target = cockpit.active_watch_tab == "Variables2" and cockpit.watches2 or cockpit.watches
		target[#target + 1] = vim.trim(expr)
		add_log((cockpit.active_watch_tab or "Variables1") .. ": variable añadida " .. vim.trim(expr))
		if cockpit.active_watch_tab == "Variables2" then
			render_watch_list("Variables2", cockpit.watches2, { focus = false, activate = false })
		else
			render_watch_list("Watch", cockpit.watches, { focus = false, activate = false })
		end
		save_layout()
		render_watch_panel()
		if watch_win and vim.api.nvim_win_is_valid(watch_win) then
			pcall(vim.api.nvim_set_current_win, watch_win)
		end
		return
	end
	local tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	if tab ~= "Variables1" and tab ~= "Variables2" then
		cockpit.active_watch_tab = "Variables1"
		tab = "Variables1"
	end
	vim.ui.input({ prompt = tab .. " ABAP: " }, function(input)
		if input and vim.trim(input) ~= "" then
			M.add_watch(input)
		end
	end)
end

function M.delete_watch_under_cursor()
	cockpit.active_watch_tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	local target = cockpit.active_watch_tab == "Variables2" and cockpit.watches2 or cockpit.watches
	if #target == 0 then
		return
	end
	local line = vim.api.nvim_get_current_line()
	local idx = tonumber(line:match("^%s*(%d+)%s*│"))
	if not idx then
		idx = #target
	end
	local removed = table.remove(target, idx)
	if removed then
		add_log("watch borrado: " .. removed)
	end
	save_layout()
	if cockpit.active_watch_tab == "Variables2" then
		render_watch_list("Variables2", cockpit.watches2, { focus = false, activate = false })
	else
		render_watch_list("Watch", cockpit.watches, { focus = false, activate = false })
	end
	render_watch_panel()
end

function M.edit_watch_under_cursor()
	local tab = canonical_watch_tab(cockpit.active_watch_tab or "Variables1")
	if tab ~= "Variables1" and tab ~= "Variables2" then
		return
	end
	local target = tab == "Variables2" and cockpit.watches2 or cockpit.watches
	if #target == 0 then
		return
	end
	local line = vim.api.nvim_get_current_line()
	local idx = tonumber(line:match("^%s*(%d+)%s*│")) or 1
	idx = math.max(1, math.min(idx, #target))
	vim.ui.input({ prompt = tab .. " editar: ", default = target[idx] }, function(input)
		if not input then
			return
		end
		input = vim.trim(input)
		if input == "" then
			table.remove(target, idx)
		else
			target[idx] = input
		end
		save_layout()
		if tab == "Variables2" then
			render_watch_list("Variables2", cockpit.watches2, { focus = false, activate = false })
		else
			render_watch_list("Watch", cockpit.watches, { focus = false, activate = false })
		end
		render_watch_panel()
		if watch_win and vim.api.nvim_win_is_valid(watch_win) then
			pcall(vim.api.nvim_set_current_win, watch_win)
		end
	end)
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
	-- Conserva la página actual si se está refrescando la MISMA tabla (refresh_active/step).
	local prev_page = (last_preview and last_preview.table and last_preview.table.name == name)
			and last_preview.table.page
		or 0
	last_preview = { mode = "name", name = name, mine_only = mine_only == true }
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

			last_preview.id = v.id
			last_preview.kind = v.meta or (v.expandable and "structure" or "scalar")
			if v.meta == "table" then
				if (v.table_lines or 0) == 0 then
					open_preview("Tabla: " .. name .. " (vacía)", { "(0 filas)" }, preview_opts)
					return
				end
				-- Guardamos el contexto de la tabla para poder paginar con ]/[ sin re-resolver.
				last_preview.table = {
					id = v.id,
					name = name,
					total = v.table_lines or 0,
					filter_user = filter_user,
					page = prev_page,
				}
				load_table_page(last_preview.table, prev_page, preview_opts)
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

refresh_last_preview = function(opts)
	opts = opts or {}
	if not last_preview then
		open_preview("Datos", { "Selecciona una variable y usa :SapAlvPreview o <leader>dT." }, {
			pane = "Datos",
			focus = opts.focus,
			preserve_cursor = opts.preserve_cursor,
		})
		return
	end

	local name = last_preview.name
	local function fallback_by_name()
		if name and name ~= "" then
			M.show_alv(last_preview.mine_only, name, {
				focus = opts.focus,
				activate = opts.activate,
				preserve_cursor = opts.preserve_cursor,
			})
			return true
		end
		return false
	end

	if last_preview.mode == "variable" and last_preview.id then
		dbg.get_vars_by_id(last_preview.id, function(vars)
			local v = vars and vars[1]
			if v then
				open_debug_variable(name, v, {
					focus = opts.focus,
					activate = opts.activate,
					preserve_cursor = opts.preserve_cursor,
				})
			elseif not fallback_by_name() then
				open_preview("Datos", { "La variable ya no está disponible en este punto de ejecución." }, {
					pane = "Datos",
					focus = opts.focus,
					preserve_cursor = opts.preserve_cursor,
				})
			end
		end)
		return
	end

	if not fallback_by_name() then
		open_preview("Datos", { "La variable ya no está disponible en este punto de ejecución." }, {
			pane = "Datos",
			focus = opts.focus,
			preserve_cursor = opts.preserve_cursor,
		})
	end
end

function M.refresh_active()
	if not dbg.session then
		return
	end
	if preview_active() then
		M.refresh_pane(cockpit.active, { focus = false, preserve_cursor = true })
	elseif last_preview then
		refresh_last_preview({ focus = false, activate = false, preserve_cursor = true })
	end
end

function M.setup()
	load_layout()
	vim.api.nvim_set_hl(0, "SapDebugGuiTitle", { fg = "#7aa2f7", bg = "NONE", bold = true })
	vim.api.nvim_set_hl(0, "SapDebugGuiMenu", { fg = "#9aa5ce", bg = "NONE" })
	vim.api.nvim_set_hl(0, "SapDebugGuiToolbar", { fg = "#9ece6a", bg = "NONE", bold = true })
	vim.api.nvim_set_hl(0, "SapDebugGuiStatus", { fg = "#c0caf5", bg = "NONE" })
	vim.api.nvim_set_hl(0, "SapDebugGuiTabs", { fg = "#bb9af7", bg = "NONE", bold = true })
	vim.api.nvim_set_hl(0, "SapDebugGuiPanel", { fg = "#7dcfff", bg = "NONE", bold = true })
	vim.api.nvim_set_hl(0, "SapDebugGuiGridHeader", { fg = "#e0af68", bg = "NONE", bold = true })
	M.install_dap_focus_guard()
	vim.api.nvim_create_user_command("SapDebugCockpit", function()
		M.open_cockpit()
	end, { desc = "Abrir Debug Cockpit SAP" })
	vim.api.nvim_create_user_command("SapDapWatch", function(args)
		M.add_watch(args.args)
	end, { nargs = "*", desc = "Añadir expresión Watch al Debug Cockpit" })
	vim.api.nvim_create_user_command("SapDebugWatchTab", function(args)
		local raw = vim.trim(args.args or "")
		local idx = tonumber(raw)
		local name = idx and SAPGUI_WATCH_TABS[idx] or raw
		if name and name ~= "" and M.select_watch_tab then
			M.select_watch_tab(name, { focus = true })
		end
	end, { nargs = "?", desc = "Cambiar subpestaña derecha del debugger SAP GUI" })
	vim.api.nvim_create_user_command("SapDebugDataExplorer", function()
		select_desktop("Data Explorer", { focus = true })
	end, { desc = "Abrir Data Explorer del debugger SAP" })
	vim.api.nvim_create_user_command("SapDebugDataFilter", function(args)
		M.set_data_explorer_filter(args.args or "")
	end, { nargs = "*", desc = "Filtrar Data Explorer del debugger SAP" })
	vim.api.nvim_create_user_command("SapDebugSetVariable", function(args)
		local raw = vim.trim(args.args or "")
		local name, value = raw:match("^(%S+)%s+(.+)$")
		if name and value ~= nil then
			M.set_variable_value(name, value)
			return
		end
		local default_name = raw ~= "" and raw or vim.fn.expand("<cexpr>")
		vim.ui.input({ prompt = "Variable ADT: ", default = default_name }, function(input_name)
			input_name = input_name and vim.trim(input_name) or ""
			if input_name == "" then
				return
			end
			vim.ui.input({ prompt = "Valor para " .. input_name .. ": " }, function(input_value)
				if input_value ~= nil then
					M.set_variable_value(input_name, input_value)
				end
			end)
		end)
	end, { nargs = "*", desc = "Set variable en debugger SAP (bloqueado por config por defecto)" })
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
