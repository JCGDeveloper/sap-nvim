-- Offline regression test for debugger/cockpit behavior.
--
-- Run without SAP:
--   nvim --headless -u NONE -i NONE -c "set rtp+=." -c "luafile test/debugger_cockpit_spec.lua"
--
-- The test stubs adt_http and curl job responses. It never connects to SAP and
-- never starts a real sapcli/curl process.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local fails = 0
local function ok(cond, msg)
	if cond then
		print("  OK  " .. msg)
	else
		fails = fails + 1
		print("  FAIL " .. msg)
	end
end

local function same(actual, expected, msg)
	ok(actual == expected, msg .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
end

local function contains(haystack, needle, msg)
	ok(tostring(haystack or ""):find(needle, 1, true) ~= nil, msg)
end

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp, "p")
vim.env.XDG_CACHE_HOME = tmp .. "/cache"
vim.env.XDG_STATE_HOME = tmp .. "/state"

local adt
adt = {
	available = true,
	ready_value = true,
	creds_value = {
		base = "https://sap.example",
		client = "100",
		user = "developer",
		pass = "secret",
	},
	is_available = function()
		return adt.available
	end,
	ready = function()
		return adt.ready_value
	end,
	creds = function()
		return adt.creds_value
	end,
	is_auth_error = function()
		return false
	end,
	on_auth_failure = function()
		adt.auth_failed = true
	end,
}
package.loaded["sap-nvim.core.adt_http"] = adt
local config = {}
config.productive_values = { allow_debug_set_variable = false }
config.security = function()
	return { verify_tls = false, connect_timeout = 1, request_timeout = 1 }
end
config.productive = function()
	return config.productive_values
end
package.loaded["sap-nvim.core.config"] = config

local notifications = {}
vim.notify = function(msg, level)
	notifications[#notifications + 1] = { msg = msg, level = level }
end

local queue = {}
local jobs = {}
local original_jobstart = vim.fn.jobstart
local original_chansend = vim.fn.chansend
local original_chanclose = vim.fn.chanclose
local original_jobstop = vim.fn.jobstop

local function enqueue(resp)
	queue[#queue + 1] = resp
end

local function arg_after(args, flag)
	for i, v in ipairs(args or {}) do
		if v == flag then
			return args[i + 1]
		end
	end
end

local function find_buf(name_part)
	for _, buf in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_get_name(buf):find(name_part, 1, true) then
			return buf
		end
	end
end

local function find_win(buf)
	for _, win in ipairs(vim.api.nvim_list_wins()) do
		if vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == buf then
			return win
		end
	end
end

vim.fn.jobstart = function(args, opts)
	local resp = table.remove(queue, 1)
	if not resp then
		error("unexpected jobstart: " .. table.concat(args or {}, " "))
	end
	local job_id = #jobs + 1
	local hdrfile = arg_after(args, "-D")
	if hdrfile then
		vim.fn.writefile(vim.split(resp.headers or "HTTP/1.1 200 OK\n", "\n"), hdrfile)
	end
	local bodyfile_arg = arg_after(args, "--data-binary")
	local body = nil
	if bodyfile_arg and bodyfile_arg:sub(1, 1) == "@" then
		body = table.concat(vim.fn.readfile(bodyfile_arg:sub(2)), "\n")
	end
	jobs[job_id] = { args = args, opts = opts, body = body }
	if resp.stdout and opts.on_stdout then
		opts.on_stdout(job_id, vim.split(resp.stdout, "\n"))
	end
	if resp.exit_later then
		jobs[job_id].pending = resp
	else
		opts.on_exit(job_id, resp.exit_code or 0)
	end
	return job_id
end

vim.fn.chansend = function() end
vim.fn.chanclose = function() end
vim.fn.jobstop = function(job)
	if jobs[job] then
		jobs[job].stopped = true
	end
	return 1
end

local dbg = require("sap-nvim.core.debugger")

print("debugger - session and curl request behavior:")
adt.available = false
local init_ok = "not-called"
dbg.init_session(function(ok_init)
	init_ok = ok_init
end)
same(init_ok, false, "init_session fails closed when ADT is unavailable")
same(#jobs, 0, "init_session does not start curl when ADT is unavailable")
adt.available = true

dbg.session = {
	jar = tmp .. "/debug.cookies",
	csrf = "csrf-token",
	terminalId = "TERM-1",
	ideId = "IDE-1",
	user = "DEVELOPER",
	breakpoints = {},
}

local before_jobs = #jobs
local set_ok, set_err
dbg.set_variable("LV_TEXT", "blocked", function(ok_set, err_set)
	set_ok, set_err = ok_set, err_set
end)
same(set_ok, false, "set_variable is blocked by default")
contains(set_err, "allow_debug_set_variable=false", "set_variable explains config gate")
same(#jobs, before_jobs, "set_variable does not start curl while gated")

config.productive_values.allow_debug_set_variable = true
same(dbg.can_set_variable(), true, "can_set_variable follows productive config")
enqueue({
	headers = "HTTP/1.1 200 OK\n",
	stdout = "<ok/>",
})
set_ok, set_err = nil, nil
dbg.set_variable("LV_TEXT", "changed", function(ok_set, err_set)
	set_ok, set_err = ok_set, err_set
end)
vim.wait(1000, function()
	return set_ok ~= nil
end, 10)
same(set_ok, true, "set_variable accepts successful ADT response when enabled")
local set_job = jobs[#jobs]
local set_url = set_job.args[#set_job.args]
contains(set_url, "method=setVariableValue", "set_variable sends ADT setVariableValue method")
contains(set_url, "variableName=LV_TEXT", "set_variable sends variableName query")
same(jobs[#jobs].body, "changed", "set_variable sends plain value payload")

enqueue({
	headers = "HTTP/1.1 404 Not Found\n",
	stdout = "<not-supported/>",
})
set_ok, set_err = nil, nil
dbg.set_variable("LV_TEXT", "unsupported", function(ok_set, err_set)
	set_ok, set_err = ok_set, err_set
end)
vim.wait(1000, function()
	return set_ok ~= nil
end, 10)
same(set_ok, false, "set_variable fails closed when ADT rejects the request")
contains(set_err, "HTTP 404", "set_variable reports unsupported ADT response")
config.productive_values.allow_debug_set_variable = false

enqueue({
	headers = "HTTP/1.1 200 OK\n",
	stdout = '<dbg:breakpoints><breakpoint id="BP-1"/></dbg:breakpoints>',
})
local bp_ok, bp_info
dbg.set_breakpoint("/sap/bc/adt/programs/programs/zfoo/source/main?version=active", 42, function(ok_bp, info)
	bp_ok, bp_info = ok_bp, info
end, "/sap/bc/adt/programs/programs/zfoo", { source_uri = "/sap/bc/adt/programs/programs/zfoo/source/main" })
vim.wait(1000, function()
	return bp_ok ~= nil
end, 10)
same(bp_ok, true, "set_breakpoint accepts successful ADT response")
same(bp_info and bp_info.id, "BP-1", "set_breakpoint extracts breakpoint id")
same(#dbg.session.breakpoints, 1, "set_breakpoint records breakpoint in session")
contains(jobs[#jobs].body, 'scope="external"', "breakpoint payload uses external scope")
contains(jobs[#jobs].body, '<syncScope mode="partial">', "breakpoint payload uses partial sync scope when provided")
contains(jobs[#jobs].body, '#start=42', "breakpoint payload targets the requested line")

enqueue({
	headers = "HTTP/1.1 400 Bad Request\n",
	stdout = '<breakpoint errorMessage="InvalidLocation: no executable statement"/>',
})
local rejected
dbg.set_breakpoint("/sap/bc/adt/programs/programs/zfoo/source/main", 7, function(ok_bp, info)
	rejected = { ok = ok_bp, info = info }
end)
vim.wait(1000, function()
	return rejected ~= nil
end, 10)
same(rejected and rejected.ok, false, "set_breakpoint rejects unavailable locations")
same(rejected and rejected.info and rejected.info.unavailableLocation, true, "set_breakpoint marks unavailable locations")
contains(rejected and rejected.info and rejected.info.errorMessage, "no es ejecutable", "set_breakpoint returns friendly unavailable-location text")

print("debugger - parsers with synthetic ADT XML:")
enqueue({
	headers = "HTTP/1.1 200 OK\n",
	stdout = [[<dbg:stack>
<stackEntry programName="ZFOO" includeName="ZFOOI01" line="12" stackPosition="1" stackUri="/sap/bc/adt/debugger/stack/1" stackType="ABAP" eventName="START-OF-SELECTION" systemProgram="false" adtcore:uri="/sap/bc/adt/programs/programs/zfoo/source/main#start=12"/>
<stackEntry program="ZBAR" uri="/sap/bc/adt/programs/programs/zbar/source/main#start=5" stackPosition="2"/>
</dbg:stack>]],
})
local frames
dbg.get_stack(function(parsed)
	frames = parsed
end)
vim.wait(1000, function()
	return frames ~= nil
end, 10)
same(#frames, 2, "get_stack parses two stack frames")
same(frames[1].program, "ZFOO", "get_stack parses programName")
same(frames[1].include, "ZFOOI01", "get_stack parses includeName")
same(frames[1].line, 12, "get_stack parses explicit line")
same(frames[2].line, 5, "get_stack falls back to line from uri")

enqueue({
	headers = "HTTP/1.1 200 OK\n",
	stdout = [[<asx:abap><asx:values><DATA>
<VARIABLES>
<STPDA_ADT_VARIABLE><ID>LV_TEXT</ID><NAME>lv_text</NAME><VALUE>A&amp;B</VALUE><DECLARED_TYPE_NAME>STRING</DECLARED_TYPE_NAME><META_TYPE>simple</META_TYPE><TABLE_LINES>0</TABLE_LINES></STPDA_ADT_VARIABLE>
<STPDA_ADT_VARIABLE><ID>LT_ITEMS[]</ID><NAME>lt_items</NAME><VALUE></VALUE><DECLARED_TYPE_NAME>STANDARD TABLE</DECLARED_TYPE_NAME><META_TYPE>simple</META_TYPE><TABLE_LINES>3</TABLE_LINES></STPDA_ADT_VARIABLE>
</VARIABLES>
<HIERARCHIES>
<STPDA_ADT_VARIABLE_HIERARCHY><CHILD_ID>@LOCALS</CHILD_ID><CHILD_NAME>Locals</CHILD_NAME></STPDA_ADT_VARIABLE_HIERARCHY>
</HIERARCHIES>
</DATA></asx:values></asx:abap>]],
})
local vars, scopes
dbg.get_variables("@ROOT", function(parsed_vars, parsed_scopes)
	vars, scopes = parsed_vars, parsed_scopes
end)
vim.wait(1000, function()
	return vars ~= nil and scopes ~= nil
end, 10)
same(#vars, 2, "get_variables parses variables")
same(vars[1].value, "A&B", "get_variables unescapes values")
same(vars[2].meta, "table", "get_variables promotes table_lines to table meta")
same(vars[2].expandable, true, "get_variables marks tables expandable")
same(scopes[1].id, "@LOCALS", "get_variables parses hierarchy child ids")
contains(jobs[#jobs].body, "<PARENT_ID>@ROOT</PARENT_ID>", "get_variables requests the requested parent scope")

local ids = dbg.table_row_ids("LT_ITEMS[]", 5, 1, 3)
same(table.concat(ids, ","), "LT_ITEMS[2],LT_ITEMS[3],LT_ITEMS[4]", "table_row_ids paginates rows")

local old_get_vars_by_id = dbg.get_vars_by_id
local old_get_variables = dbg.get_variables
dbg.get_vars_by_id = function(row_ids, cb)
	same(table.concat(row_ids, ","), "LT_ITEMS[3],LT_ITEMS[4]", "get_table_rows asks only requested page")
	cb({})
end
dbg.get_variables = function(parent_id, cb)
	same(parent_id, "LT_ITEMS[]", "get_table_rows falls back to child variables")
	cb({ { id = "LT_ITEMS[3]", name = "[3]" } })
end
local rows
dbg.get_table_rows("LT_ITEMS[]", 4, function(parsed_rows)
	rows = parsed_rows
end, 2, 2)
same(#rows, 1, "get_table_rows returns fallback child rows")
dbg.get_vars_by_id = old_get_vars_by_id
dbg.get_variables = old_get_variables

print("debugger - listener conflict stays local:")
enqueue({
	headers = "HTTP/1.1 409 Conflict\n",
	stdout = '<debuggerListener conflictText="already in use"/>',
})
local listened = false
dbg.listen(function()
	listened = true
end)
vim.wait(1000, function()
	return dbg.session.listener_job == nil
end, 10)
same(listened, false, "listen does not attach when SAP reports a listener conflict")

print("cockpit - headless UI without SAP:")
dbg.session = nil
local preview = require("sap-nvim.core.preview")
preview.setup()
same(vim.fn.exists(":SapDebugCockpit"), 2, "preview.setup registers :SapDebugCockpit")
same(vim.fn.exists(":SapDapWatch"), 2, "preview.setup registers :SapDapWatch")
same(vim.fn.exists(":SapDebugDataExplorer"), 2, "preview.setup registers :SapDebugDataExplorer")
same(vim.fn.exists(":SapDebugDataFilter"), 2, "preview.setup registers :SapDebugDataFilter")
same(vim.fn.exists(":SapDebugSetVariable"), 2, "preview.setup registers :SapDebugSetVariable")
preview.open_cockpit()
local cockpit_buf = find_buf("sap-debug-preview://variables")
same(vim.bo[cockpit_buf].filetype, "sapdebugpreview", "open_cockpit creates a cockpit buffer")
local lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(lines, "Datos", "cockpit renders the Datos pane")
contains(lines, "Selecciona una variable", "cockpit renders the no-session Datos message")
contains(lines, "Desktop1", "cockpit renders SAP GUI Desktop1 tab")
contains(lines, "Desktop2", "cockpit renders SAP GUI Desktop2 tab")
contains(lines, "Desktop3", "cockpit renders SAP GUI Desktop3 tab")
contains(lines, "Estruct", "cockpit renders SAP GUI Estruct tab")
contains(lines, "Tablas", "cockpit renders SAP GUI Tablas tab")
contains(lines, "Objetos", "cockpit renders SAP GUI Objetos tab")
contains(lines, "Vis.detallada", "cockpit renders SAP GUI detailed-view tab")
contains(lines, "Data Explorer", "cockpit renders SAP GUI Data Explorer tab")

local state = preview._debug_state()
ok(state.wins.stack and vim.api.nvim_win_is_valid(state.wins.stack), "cockpit has a right-top stack window")
ok(state.wins.watch and vim.api.nvim_win_is_valid(state.wins.watch), "cockpit has a right-bottom variable window")

preview.add_watch(" lv_text ")
preview.select_watch_tab("Variables 1", { focus = false })
local watch_buf = find_buf("sap-debug-preview://watch")
local buf_lines = table.concat(vim.api.nvim_buf_get_lines(watch_buf, 0, -1, false), "\n")
contains(buf_lines, "debug activa.", "watch rendering stays offline without a debug session")
contains(buf_lines, "Variables1", "right panel renders Variables1 tab")
contains(buf_lines, "Variables2", "right panel renders Variables2 tab")
contains(buf_lines, "Memory", "right panel renders Memory tab")
same(preview._debug_state().active_watch_tab, "Variables1", "watch tab alias is stored canonically")

local watch_win = find_win(watch_buf)
ok(watch_win ~= nil, "watch window is visible")
if watch_win then
	vim.api.nvim_set_current_win(watch_win)
	preview.refresh_pane("Datos", { focus = false, preserve_cursor = true })
	same(vim.api.nvim_get_current_win(), watch_win, "refresh_pane with focus=false preserves current window")
end

local original_input = vim.ui.input
vim.ui.input = function(opts, cb)
	same(opts.default, "lv_text", "edit_watch_under_cursor offers current watch as default")
	cb(" lv_changed ")
end
if watch_win then
	vim.api.nvim_set_current_win(watch_win)
	vim.api.nvim_win_set_cursor(watch_win, { 10, 0 })
	preview.edit_watch_under_cursor()
end
vim.ui.input = original_input
same(preview._debug_state().watches[1], "lv_changed", "edit_watch_under_cursor updates Variables1 watch")

dbg.session = { breakpoints = { { id = "BP-1", line = 42, source_uri = "/sap/bc/adt/programs/programs/zfoo/source/main" } } }
enqueue({
	headers = "HTTP/1.1 200 OK\n",
	stdout = "<dbg:stack></dbg:stack>",
})
preview.refresh_pane("Breakpoints", { focus = true })
vim.wait(1000, function()
	return #queue == 0
end, 10)
buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(buf_lines, "SAP externos:", "breakpoints pane renders SAP breakpoint heading")
contains(buf_lines, "L42", "breakpoints pane renders session breakpoints")

local saved_get_variables = dbg.get_variables
local saved_get_vars_by_id = dbg.get_vars_by_id
local saved_get_table_rows = dbg.get_table_rows
local saved_get_stack = dbg.get_stack
dbg.session = { user = "DEVELOPER", breakpoints = {} }
dbg.get_stack = function(cb)
	cb({
		{ program = "ZFOO", include = "ZFOOI01", line = 42, stackUri = "/sap/bc/adt/debugger/stack/1" },
	})
end
dbg.get_variables = function(scope, cb)
	if type(scope) == "table" then
		cb({
			{ id = "LT_ITEMS[]", name = "LT_ITEMS", value = "", type = "STANDARD TABLE", meta = "table", table_lines = 3, expandable = true },
		}, {})
	else
		cb({
			{ id = "LT_ITEMS[1]-COL", name = "COL", value = "A", type = "CHAR1", meta = "simple", expandable = false },
			{ id = "LT_ITEMS[2]-COL", name = "COL", value = "B", type = "CHAR1", meta = "simple", expandable = false },
			{ id = "LT_ITEMS[3]-COL", name = "COL", value = "C", type = "CHAR1", meta = "simple", expandable = false },
		}, {})
	end
end
dbg.get_vars_by_id = function(ids, cb)
	local first = type(ids) == "table" and ids[1] or ids
	if tostring(first):find("^LT_ITEMS%[%d") then
		cb({
			{ id = "LT_ITEMS[1]", name = "[1]", value = "", meta = "structure", expandable = true },
			{ id = "LT_ITEMS[2]", name = "[2]", value = "", meta = "structure", expandable = true },
			{ id = "LT_ITEMS[3]", name = "[3]", value = "", meta = "structure", expandable = true },
		})
	else
		cb({
			{ id = "LT_ITEMS[]", name = "LT_ITEMS", value = "", type = "STANDARD TABLE", meta = "table", table_lines = 3, expandable = true },
		})
	end
end
dbg.get_table_rows = function(id, total, cb, offset, limit)
	cb({
		{ id = "LT_ITEMS[1]", name = "[1]", value = "", meta = "structure", expandable = true },
		{ id = "LT_ITEMS[2]", name = "[2]", value = "", meta = "structure", expandable = true },
		{ id = "LT_ITEMS[3]", name = "[3]", value = "", meta = "structure", expandable = true },
	})
end

preview.show_alv(false, "LT_ITEMS", { focus = false })
vim.wait(1000, function()
	return preview._debug_state().last_preview and preview._debug_state().last_preview.table ~= nil
end, 10)
state = preview._debug_state()
same(state.desktop, "Tablas", "table visualization switches to Tablas desktop")
same(state.last_preview and state.last_preview.table and state.last_preview.table.name, "LT_ITEMS", "table visualization stores last preview")
if watch_win and vim.api.nvim_win_is_valid(watch_win) then
	vim.api.nvim_set_current_win(watch_win)
	preview.refresh_active()
	vim.wait(1000, function()
		local s = preview._debug_state()
		return s.last_preview and s.last_preview.table and s.last_preview.table.name == "LT_ITEMS"
	end, 10)
	same(vim.api.nvim_get_current_win(), watch_win, "refresh_active keeps focus while refreshing persisted visualization")
end
state = preview._debug_state()
same(state.last_preview and state.last_preview.table and state.last_preview.table.name, "LT_ITEMS", "table visualization persists after refresh_active")

dbg.get_variables = function(scope, cb)
	if type(scope) == "table" then
		local out = {
			{ id = "@LOCALS\\LS_HEAD", name = "LS_HEAD", value = "", type = "ZHEAD", meta = "structure", expandable = true },
			{ id = "@LOCALS\\LT_ITEMS[]", name = "LT_ITEMS", value = "", type = "STANDARD TABLE", meta = "table", table_lines = 3, expandable = true },
			{ id = "@LOCALS\\LO_APP", name = "LO_APP", value = "ref", type = "REF TO ZCL_APP", meta = "object", expandable = true },
		}
		for i = 1, 25 do
			out[#out + 1] = {
				id = "@LOCALS\\LV_" .. string.format("%02d", i),
				name = "LV_" .. string.format("%02d", i),
				value = "VALUE_" .. i,
				type = "CHAR10",
				meta = "simple",
				expandable = false,
			}
		end
		cb(out, {})
	else
		cb({
			{ id = tostring(scope) .. "-FIELD", name = "FIELD", value = "A", type = "CHAR1", meta = "simple", expandable = false },
		}, {})
	end
end
dbg.get_vars_by_id = function(ids, cb)
	local out = {}
	for i, id in ipairs(type(ids) == "table" and ids or { ids }) do
		out[i] = { id = id, name = id, value = "WATCH_" .. i, type = "CHAR10", meta = "simple", expandable = false }
	end
	cb(out)
end

if watch_win and vim.api.nvim_win_is_valid(watch_win) then
	vim.api.nvim_set_current_win(watch_win)
	preview.select_desktop("Data Explorer", { focus = false })
	vim.wait(1000, function()
		return preview._debug_state().desktop == "Data Explorer"
	end, 10)
	same(vim.api.nvim_get_current_win(), watch_win, "Data Explorer opens with focus=false without stealing focus")
end
buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(buf_lines, "Data Explorer", "Data Explorer renders a real grid")
contains(buf_lines, "LV_01", "Data Explorer includes debugger variables")
preview.set_data_explorer_filter("LV_CHANGED")
vim.wait(1000, function()
	return preview._debug_state().data_explorer.filter == "LV_CHANGED"
end, 10)
buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(buf_lines, "LV_CHANGED", "Data Explorer includes watch expressions")
preview.set_data_explorer_filter("")

preview.data_explorer_page(1)
vim.wait(1000, function()
	return preview._debug_state().data_explorer.page == 1
end, 10)
state = preview._debug_state()
same(state.data_explorer.page, 1, "Data Explorer stores current page")
buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(buf_lines, "pág 2/", "Data Explorer renders requested page")

preview.set_data_explorer_filter("LV_2")
vim.wait(1000, function()
	return preview._debug_state().data_explorer.filter == "LV_2"
end, 10)
state = preview._debug_state()
same(state.data_explorer.page, 0, "Data Explorer filter resets page")
buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
contains(buf_lines, "filtro: LV_2", "Data Explorer renders persisted filter")
contains(buf_lines, "LV_20", "Data Explorer applies filter to variable names")

preview.set_data_explorer_filter("")
preview.data_explorer_page(1)
if watch_win and vim.api.nvim_win_is_valid(watch_win) then
	vim.api.nvim_set_current_win(watch_win)
	preview.refresh_active()
	vim.wait(1000, function()
		return preview._debug_state().data_explorer.page == 1
	end, 10)
	same(vim.api.nvim_get_current_win(), watch_win, "Data Explorer refresh_active preserves focus")
end
same(preview._debug_state().data_explorer.page, 1, "Data Explorer page persists after refresh_active")

preview.set_data_explorer_filter("LS_HEAD")
vim.wait(1000, function()
	return preview._debug_state().data_explorer.filter == "LS_HEAD"
end, 10)
local preview_win = preview._debug_state().wins.preview
if preview_win and vim.api.nvim_win_is_valid(preview_win) then
	local ls_line
	local data_lines = vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false)
	for i, line in ipairs(data_lines) do
		if line:find("Locals", 1, true) and line:find("LS_HEAD", 1, true) then
			ls_line = i
			break
		end
	end
	ok(ls_line ~= nil, "Data Explorer exposes structure rows as actions")
	if ls_line then
		vim.api.nvim_set_current_win(preview_win)
		vim.api.nvim_win_set_cursor(preview_win, { ls_line, 0 })
		preview.open_selected_variable()
		vim.wait(1000, function()
			local rendered = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
			return rendered:find("Estructura: LS_HEAD", 1, true) ~= nil
		end, 10)
		buf_lines = table.concat(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false), "\n")
		contains(buf_lines, "Estructura: LS_HEAD", "Data Explorer opens structures from variable rows")
	end
end

config.productive_values.allow_debug_set_variable = true
local captured_set
local original_set_variable = dbg.set_variable
dbg.set_variable = function(name, value, cb)
	captured_set = { name = name, value = value }
	cb(true)
end
preview.select_desktop("Data Explorer", { focus = false })
preview.set_data_explorer_filter("LV_01")
vim.wait(1000, function()
	return preview._debug_state().desktop == "Data Explorer"
end, 10)
preview_win = preview._debug_state().wins.preview
if preview_win and vim.api.nvim_win_is_valid(preview_win) then
	local lv_line
	for i, line in ipairs(vim.api.nvim_buf_get_lines(cockpit_buf, 0, -1, false)) do
		if line:find("Locals", 1, true) and line:find("LV_01", 1, true) then
			lv_line = i
			break
		end
	end
	ok(lv_line ~= nil, "Data Explorer exposes scalar rows for set variable")
	if lv_line then
		vim.api.nvim_set_current_win(preview_win)
		vim.api.nvim_win_set_cursor(preview_win, { lv_line, 0 })
		vim.ui.input = function(opts, cb)
			same(opts.default, "VALUE_1", "set_selected_variable offers current value as default")
			cb("999")
		end
		preview.set_selected_variable(false)
		vim.ui.input = original_input
	end
end
same(captured_set and captured_set.name, "@LOCALS\\LV_01", "set_selected_variable uses ADT variable id")
same(captured_set and captured_set.value, "999", "set_selected_variable forwards requested value")
dbg.set_variable = original_set_variable
config.productive_values.allow_debug_set_variable = false

dbg.get_variables = saved_get_variables
dbg.get_vars_by_id = saved_get_vars_by_id
dbg.get_table_rows = saved_get_table_rows
dbg.get_stack = saved_get_stack

vim.fn.jobstart = original_jobstart
vim.fn.chansend = original_chansend
vim.fn.chanclose = original_chanclose
vim.fn.jobstop = original_jobstop

if fails == 0 then
	print("\nTODO OK")
	vim.cmd("qa!")
else
	print("\n" .. fails .. " FALLOS")
	vim.cmd("cquit")
end
