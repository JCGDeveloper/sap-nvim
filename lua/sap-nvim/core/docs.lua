-- sap-nvim.core.docs
-- Ayuda/documentacion oficial SAP sin scraping: primero intenta busqueda ADT
-- de solo lectura; siempre ofrece URLs oficiales configurables como fallback.

local M = {}

local adt_http = require("sap-nvim.core.adt_http")
local config = require("sap-nvim.core.config")
local index = require("sap-nvim.core.index")
local source = require("sap-nvim.core.source")

local HELP_ACCEPT = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml"

local TYPE_INFO = {
	["CLAS/OC"] = { label = "Class", group = "class" },
	["INTF/OI"] = { label = "Interface", group = "interface" },
	["PROG/P"] = { label = "Program", group = "program" },
	["PROG/I"] = { label = "Include", group = "include" },
	["FUGR/F"] = { label = "Function Group", group = "functiongroup" },
	["FUGR/FF"] = { label = "Function Module", group = "functionmodule" },
	["FUNC/FF"] = { label = "Function Module", group = "functionmodule" },
	["DTEL/DE"] = { label = "Data Element", group = "dataelement" },
	["DOMA/DO"] = { label = "Domain", group = "domain" },
	["TABL/DT"] = { label = "Table", group = "table" },
	["TABL/DS"] = { label = "Structure", group = "structure" },
	["VIEW/DV"] = { label = "View", group = "table" },
	["TTYP/TT"] = { label = "Table Type", group = "tabletype" },
	["DDLS/DF"] = { label = "CDS View", group = "ddls" },
	["DDLX/EX"] = { label = "Metadata Extension", group = "ddlx" },
	["DCLS/DL"] = { label = "Access Control", group = "dcl" },
	["BDEF/BDO"] = { label = "Behavior Definition", group = "bdef" },
	["SRVD/SRV"] = { label = "Service Definition", group = "srvd" },
	["TRAN/T"] = { label = "Transaction", group = "transaction" },
	["DEVC/K"] = { label = "Package", group = "package" },
}

local SECTION_LABELS = {
	docs = "Docs",
	adt = "ADT",
	favorites = "Favoritos",
	history = "Historial",
}

local SECTION_ORDER = { "docs", "adt", "favorites", "history" }

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function unxml(s)
	return (s or "")
		:gsub("&lt;", "<")
		:gsub("&gt;", ">")
		:gsub("&quot;", '"')
		:gsub("&apos;", "'")
		:gsub("&amp;", "&")
end

local function url_encode(str)
	return (tostring(str or ""):gsub("[^%w%-%._~]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

local clean_query

local function docs_config()
	local c = config.docs and config.docs() or {}
	return c or {}
end

local function store_path()
	return vim.fn.stdpath("state") .. "/sap-nvim/docs.json"
end

local function empty_store()
	return { favorites = {}, history = {} }
end

local function normalize_store(data)
	if type(data) ~= "table" then
		return empty_store()
	end
	if type(data.favorites) ~= "table" then
		data.favorites = {}
	end
	if type(data.history) ~= "table" then
		data.history = {}
	end
	return data
end

local function load_store()
	local path = store_path()
	if vim.fn.filereadable(path) ~= 1 then
		return empty_store()
	end
	local ok, data = pcall(function()
		return vim.fn.json_decode(table.concat(vim.fn.readfile(path), "\n"))
	end)
	if not ok then
		return empty_store()
	end
	return normalize_store(data)
end

local function save_store(data)
	data = normalize_store(data)
	local path = store_path()
	vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
	pcall(vim.fn.writefile, vim.split(vim.fn.json_encode(data), "\n", { plain = true }), path)
end

local function store_limit(kind)
	local c = docs_config()
	if kind == "favorites" then
		return c.favorite_limit or 100
	end
	return c.history_limit or 50
end

local function item_key(item)
	if not item then
		return ""
	end
	if item.kind == "adt" then
		return table.concat({ "adt", item.adt_type or "", item.name or "", item.uri or "" }, "\0")
	end
	return table.concat({ "query", item.query or "" }, "\0")
end

local function trim_list(list, limit)
	while #list > limit do
		table.remove(list)
	end
end

local function upsert_front(list, item, limit)
	local key = item_key(item)
	for i = #list, 1, -1 do
		if item_key(list[i]) == key then
			table.remove(list, i)
		end
	end
	item.ts = os.time()
	table.insert(list, 1, item)
	trim_list(list, limit)
end

local function record_history(query, kind)
	query = clean_query(query)
	if query == "" then
		return
	end
	local data = load_store()
	upsert_front(data.history, { kind = "query", query = query, search_kind = kind }, store_limit("history"))
	save_store(data)
end

local function favorite_query(query)
	query = clean_query(query)
	if query == "" then
		return false
	end
	local data = load_store()
	upsert_front(data.favorites, { kind = "query", query = query, label = query }, store_limit("favorites"))
	save_store(data)
	return true
end

local function favorite_row(row, query)
	if not row or not row.name or row.name == "" then
		return false
	end
	local data = load_store()
	upsert_front(data.favorites, {
		kind = "adt",
		name = row.name,
		adt_type = row.adt_type,
		desc = row.desc,
		uri = row.uri,
		query = query,
	}, store_limit("favorites"))
	save_store(data)
	return true
end

local function apply_template(template, query)
	return (template or ""):gsub("{query}", url_encode(query)):gsub("{raw}", tostring(query or ""))
end

clean_query = function(q)
	q = vim.trim(tostring(q or ""))
	q = q:gsub("^['\"`]+", ""):gsub("['\"`,%.;:]+$", "")
	return q
end

local function cursor_symbol()
	local line = vim.api.nvim_get_current_line()
	local col = vim.api.nvim_win_get_cursor(0)[2] + 1

	local i = 1
	while i <= #line do
		local start_col = line:find("['\"]", i)
		if not start_col then
			break
		end
		local quote = line:sub(start_col, start_col)
		local end_col = line:find(quote, start_col + 1, true)
		if not end_col then
			break
		end
		if col >= start_col and col <= end_col then
			local value = line:sub(start_col + 1, end_col - 1)
			if value:match("^[%w_/%-]+$") then
				return value
			end
		end
		i = end_col + 1
	end

	local cword = clean_query(vim.fn.expand("<cword>"))
	local cWORD = clean_query(vim.fn.expand("<cWORD>"))
	local method = cWORD:match("([%w_]+=>[%w_]+)") or cWORD:match("([%w_]+%-%>[%w_]+)")
	if method and method:find(cword, 1, true) then
		return method
	end

	return cword ~= "" and cword or cWORD
end

local function infer_kind(query, opts)
	opts = opts or {}
	if opts.kind and opts.kind ~= "" then
		return opts.kind
	end
	local q = query:upper()
	if q:match("^BAPI_") then
		return "bapi"
	end
	if q:match("^RFC_") or q:match("^%u+_%u+") then
		return "function"
	end
	if q:match("=>") or q:match("%-%>") then
		return "method"
	end
	if q:match("^CL_") or q:match("^IF_") then
		return "class"
	end
	if q:match("^DOMA:") then
		return "domain"
	end
	if q:match("^DTEL:") then
		return "data_element"
	end
	return "generic"
end

local function object_types_for(kind)
	if kind == "all" then
		return { false }
	end
	if kind == "bapi" or kind == "function" then
		return { "FUNC", "FUGR" }
	end
	if kind == "class" or kind == "method" then
		return { "CLAS", "INTF" }
	end
	if kind == "domain" then
		return { "DOMA" }
	end
	if kind == "data_element" then
		return { "DTEL" }
	end
	return { false }
end

local function parse_search_body(body)
	local out, seen = {}, {}
	if not body or body == "" then
		return out
	end
	for tag in body:gmatch("<[^>]+>") do
		local name = tag:match('adtcore:name="([^"]*)"')
		local typ = tag:match('adtcore:type="([^"]*)"')
		if name and typ then
			name, typ = unxml(name), unxml(typ)
			local key = typ .. "\0" .. name
			if not seen[key] then
				seen[key] = true
				out[#out + 1] = {
					name = name,
					adt_type = typ,
					desc = unxml(tag:match('adtcore:description="([^"]*)"') or ""),
					uri = unxml(tag:match('adtcore:uri="([^"]*)"') or ""),
				}
			end
		end
	end
	return out
end

local function index_search_rows(query, kind, opts)
	opts = opts or {}
	local types = object_types_for(kind)
	local rows, seen = {}, {}
	local max_results = tonumber(opts.max_results or docs_config().max_results) or 25
	for _, object_type in ipairs(types) do
		local indexed = index.search_adt_rows(query:upper():gsub("%*+$", "") .. "*", {
			type = object_type or nil,
			kinds = { "object", "package" },
			limit = max_results,
		})
		for _, r in ipairs(indexed) do
			local key = (r.adt_type or "") .. "\0" .. (r.name or "")
			if not seen[key] then
				seen[key] = true
				rows[#rows + 1] = r
			end
		end
	end
	table.sort(rows, function(a, b)
		if a.adt_type == b.adt_type then
			return a.name < b.name
		end
		return a.adt_type < b.adt_type
	end)
	return rows
end

local function index_status_text()
	local st = index.status()
	if st.counts.total == 0 then
		return nil
	end
	if st.stale then
		return "indice local obsoleto (" .. tostring(st.counts.total) .. " entradas)"
	end
	return "indice local (" .. tostring(st.counts.total) .. " entradas)"
end

local function result_label(r)
	local info = TYPE_INFO[r.adt_type]
	local label = (info and info.label) or r.adt_type or "ADT"
	local desc = r.desc and r.desc ~= "" and (" - " .. r.desc) or ""
	return string.format("%-28s [%s]%s", r.name or "?", label, desc)
end

local function fgroup_from_uri(uri)
	return uri and uri:match("/functions/groups/([^/]+)/fmodules/") or nil
end

local function open_adt_row(row)
	if not row or not row.name then
		return
	end
	local info = TYPE_INFO[row.adt_type]
	if not info or not info.group then
		notify("No se puede abrir este tipo ADT: " .. tostring(row.adt_type), vim.log.levels.WARN)
		return
	end
	source.open(row.name, info.group, {
		uri = row.uri,
		package = row.package,
		fgroup = fgroup_from_uri(row.uri),
	})
end

local function favorite_label(item)
	if item.kind == "adt" then
		return result_label(item)
	end
	return item.query or item.label or "Busqueda"
end

local function official_links(query, kind)
	local c = docs_config()
	local links = {}
	local help_template = c.help_url or "https://help.sap.com/docs/search?q={query}"
	local api_template = c.api_hub_url or "https://api.sap.com/search?searchterm={query}"
	links[#links + 1] = { label = "SAP Help Portal", url = apply_template(help_template, query) }
	if kind == "bapi" or kind == "function" or kind == "method" or c.always_show_api_hub == true then
		links[#links + 1] = { label = "SAP Business Accelerator Hub", url = apply_template(api_template, query) }
	end
	return links
end

local function is_wsl()
	local f = io.open("/proc/sys/kernel/osrelease", "r")
	if not f then
		return false
	end
	local release = f:read("*a") or ""
	f:close()
	return release:lower():find("microsoft", 1, true) ~= nil
end

local function can_run(exe)
	if not exe or exe == "" then
		return false
	end
	if exe:find("/", 1, true) then
		return vim.fn.filereadable(exe) == 1
	end
	return vim.fn.executable(exe) == 1
end

local function ps_quote(s)
	return "'" .. tostring(s or ""):gsub("'", "''") .. "'"
end

local function browser_candidates(url)
	local candidates = {}
	local function add(label, exe, cmd)
		candidates[#candidates + 1] = { label = label, exe = exe, cmd = cmd }
	end

	if vim.fn.has("mac") == 1 then
		add("macOS open", "open", { "open", url })
	elseif vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1 then
		add("Windows cmd start", "cmd.exe", { "cmd.exe", "/C", "start", "", url })
	elseif is_wsl() then
		add("WSL rundll32 URL handler", "/mnt/c/Windows/System32/rundll32.exe",
			{ "/mnt/c/Windows/System32/rundll32.exe", "url.dll,FileProtocolHandler", url })
		add("WSL PowerShell Start-Process", "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe", {
			"/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
			"-NoProfile",
			"-NonInteractive",
			"-Command",
			"Start-Process -FilePath " .. ps_quote(url),
		})
		add("WSL cmd.exe start", "/mnt/c/Windows/System32/cmd.exe",
			{ "/mnt/c/Windows/System32/cmd.exe", "/C", "start", "", url })
		add("wslview", "wslview", { "wslview", url })
		add("WSL explorer.exe", "/mnt/c/Windows/explorer.exe", { "/mnt/c/Windows/explorer.exe", url })
	else
		add("xdg-open", "xdg-open", { "xdg-open", url })
	end

	return candidates
end

local function open_url(url)
	if not url or url == "" then
		return
	end
	for _, candidate in ipairs(browser_candidates(url)) do
		if can_run(candidate.exe) then
			vim.fn.system(candidate.cmd)
			if vim.v.shell_error == 0 then
				notify("Abriendo URL oficial con " .. candidate.label .. ": " .. url)
				return
			end
		end
	end
	if vim.ui and vim.ui.open then
		local ok = pcall(vim.ui.open, url)
		if ok then
			notify("Abriendo URL oficial: " .. url)
			return
		end
	end
	vim.fn.setreg("+", url)
	notify("No pude abrir navegador; URL copiada al portapapeles: " .. url, vim.log.levels.WARN)
end

M._open_url = open_url

function M.browser_status()
	local probe = "https://help.sap.com/docs/search?q=SAP"
	local lines = { "Lanzadores de navegador detectados:" }
	for _, candidate in ipairs(browser_candidates(probe)) do
		lines[#lines + 1] = string.format("%s %s  -> %s",
			can_run(candidate.exe) and "✅" or "❌",
			candidate.label,
			candidate.exe)
	end
	notify(table.concat(lines, "\n"))
end

function M.search_adt(query, opts, cb)
	query = clean_query(query)
	opts = opts or {}
	if query == "" then
		cb({}, "Sin termino de busqueda")
		return
	end
	local kind = opts.all_types and "all" or infer_kind(query, opts)
	if not opts.force_live then
		local local_rows = index_search_rows(query, kind, opts)
		if #local_rows > 0 then
			cb(local_rows, index_status_text())
			return
		end
	end
	if not adt_http.is_available() then
		local status = index.status()
		if status.counts.total > 0 then
			cb({}, "Sin resultado en indice local; ADT no validado")
		else
			cb({}, "Indice local vacio; ADT no validado")
		end
		return
	end
	local types = object_types_for(kind)
	local pending, rows, seen = #types, {}, {}
	local function done()
		table.sort(rows, function(a, b)
			if a.adt_type == b.adt_type then
				return a.name < b.name
			end
			return a.adt_type < b.adt_type
		end)
		cb(rows)
	end

	for _, object_type in ipairs(types) do
		local query_params = {
			operation = "quickSearch",
			query = query:upper():gsub("%*+$", "") .. "*",
			maxResults = tostring(opts.max_results or docs_config().max_results or 25),
		}
		if object_type then
			query_params.objectType = object_type
		end
		adt_http.request_async({
			method = "GET",
			path = "/sap/bc/adt/repository/informationsystem/search",
			query = query_params,
			accept = HELP_ACCEPT,
		}, function(body)
			local parsed = parse_search_body(body)
			if #parsed > 0 then
				pcall(function()
					index.add_entries(parsed, { source = "docs:" .. query, save = true })
				end)
			end
			for _, r in ipairs(parsed) do
				local key = (r.adt_type or "") .. "\0" .. (r.name or "")
				if not seen[key] then
					seen[key] = true
					rows[#rows + 1] = r
				end
			end
			pending = pending - 1
			if pending == 0 then
				vim.schedule(done)
			end
		end)
	end
end

local function filter_rows(rows, filter)
	filter = clean_query(filter or "")
	if filter == "" then
		return rows or {}
	end
	local needle = filter:lower()
	local out = {}
	for _, r in ipairs(rows or {}) do
		local hay = table.concat({
			r.name or "",
			r.adt_type or "",
			r.desc or "",
			r.uri or "",
		}, " "):lower()
		if hay:find(needle, 1, true) then
			out[#out + 1] = r
		end
	end
	return out
end

local function current_section(state)
	return state.section or "docs"
end

local function section_tabs(section)
	local parts = {}
	for i, name in ipairs(SECTION_ORDER) do
		local label = SECTION_LABELS[name]
		if name == section then
			parts[#parts + 1] = "[" .. i .. " " .. label .. "]"
		else
			parts[#parts + 1] = " " .. i .. " " .. label .. " "
		end
	end
	return table.concat(parts, "  ")
end

local function add_line(lines, actions, items, text, action, item)
	lines[#lines + 1] = text
	if action then
		actions[#lines] = action
	end
	if item then
		items[#lines] = item
	end
end

local function build_lines(state)
	local query = state.query
	local kind = state.kind
	local rows = state.rows
	local status = state.status
	local local_filter = state.filter
	local section = current_section(state)
	local visible_rows = filter_rows(rows, local_filter)
	local store = load_store()
	local lines, actions, items = {}, {}, {}

	add_line(lines, actions, items, "# SAP Help: " .. query)
	add_line(lines, actions, items, section_tabs(section))
	add_line(lines, actions, items, "")
	add_line(lines, actions, items, "Alcance ADT: " .. (kind == "all" and "todos los tipos" or kind))
	add_line(lines, actions, items, "Fuente ADT: " .. (status or (adt_http.is_available() and "quickSearch disponible" or "no validada")))
	add_line(lines, actions, items, "Filtro local: " .. ((local_filter and local_filter ~= "") and local_filter or "(sin filtro)"))
	add_line(lines, actions, items, "")

	if section == "docs" then
		add_line(lines, actions, items, "## Docs")
		for i, link in ipairs(official_links(query, kind)) do
			local current_link = link
			add_line(lines, actions, items, string.format("%d. %s", i, link.label), function()
				open_url(current_link.url)
			end)
			add_line(lines, actions, items, "   " .. link.url, function()
				open_url(current_link.url)
			end)
		end
		add_line(lines, actions, items, "")
		add_line(lines, actions, items, "m guarda la busqueda actual como favorita.")
	elseif section == "adt" then
		add_line(lines, actions, items, "## ADT")
		if visible_rows and #visible_rows > 0 then
			for _, r in ipairs(visible_rows) do
				local current_row = r
				local uri = r.uri ~= "" and (" `" .. r.uri .. "`") or ""
				add_line(lines, actions, items, "- " .. result_label(r) .. uri, function()
					open_adt_row(current_row)
				end, { kind = "adt", row = current_row })
			end
		elseif rows and #rows > 0 then
			add_line(lines, actions, items, "- Sin resultados para el filtro local.")
		else
			add_line(lines, actions, items, "- Sin resultados ADT locales.")
		end
		add_line(lines, actions, items, "")
		add_line(lines, actions, items, "m guarda el resultado bajo el cursor como favorito.")
	elseif section == "favorites" then
		add_line(lines, actions, items, "## Favoritos")
		if #store.favorites == 0 then
			add_line(lines, actions, items, "- Sin favoritos guardados.")
		else
			for _, item in ipairs(store.favorites) do
				local current_item = item
				if item.kind == "adt" then
					add_line(lines, actions, items, "- " .. favorite_label(item), function()
						open_adt_row(current_item)
					end, { kind = "adt", row = current_item })
				else
					add_line(lines, actions, items, "- " .. favorite_label(item), function()
						state.query = current_item.query
						state.kind = state.all_types and "all" or infer_kind(state.query, {})
						state.rows = nil
						state.status = nil
						state.filter = nil
						state.section = "docs"
						record_history(state.query, state.kind)
						state.rerender(true)
					end, { kind = "query", query = current_item.query })
				end
			end
		end
	elseif section == "history" then
		add_line(lines, actions, items, "## Historial")
		if #store.history == 0 then
			add_line(lines, actions, items, "- Sin busquedas recientes.")
		else
			for _, item in ipairs(store.history) do
				local current_item = item
				add_line(lines, actions, items, "- " .. (item.query or "?"), function()
					state.query = current_item.query
					state.kind = state.all_types and "all" or infer_kind(state.query, {})
					state.rows = nil
					state.status = nil
					state.filter = nil
					state.section = "docs"
					record_history(state.query, state.kind)
					state.rerender(true)
				end, { kind = "query", query = current_item.query })
			end
		end
	end

	add_line(lines, actions, items, "")
	add_line(lines, actions, items, "Atajos: 1-4 secciones, o/<CR> abrir, m favorito, s buscar, / filtrar, c limpiar, r refrescar, q cerrar.")
	return lines, actions, items
end

local function set_lines(buf, lines)
	vim.bo[buf].modifiable = true
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].modifiable = false
end

local function url_under_cursor()
	local line = vim.api.nvim_get_current_line()
	local url = line:match("(https?://%S+)") or line:match("%((https?://[^%)]+)%)")
	return url and url:gsub("[%]%)}>,%.;:]+$", "") or nil
end

local function map_help_actions(buf, state, actions)
	actions = actions or {}
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true, desc = "SAP Help: cerrar" })

	local function run_line_action()
		local line = vim.api.nvim_win_get_cursor(0)[1]
		local line_actions = vim.b[buf].sap_help_actions or {}
		if line_actions[line] then
			line_actions[line]()
			return
		end
		local url = url_under_cursor()
		if url then
			open_url(url)
		end
	end

	vim.keymap.set("n", "o", run_line_action, { buffer = buf, desc = "SAP Help: abrir selección" })
	vim.keymap.set("n", "<CR>", run_line_action, { buffer = buf, desc = "SAP Help: abrir selección" })
	for i, section in ipairs(SECTION_ORDER) do
		vim.keymap.set("n", tostring(i), function()
			state.section = section
			actions.render()
		end, { buffer = buf, desc = "SAP Help: sección " .. SECTION_LABELS[section] })
	end
	if actions.refresh then
		vim.keymap.set("n", "r", actions.refresh, { buffer = buf, desc = "SAP Help: refrescar ADT" })
	end
	if actions.search then
		vim.keymap.set("n", "s", actions.search, { buffer = buf, desc = "SAP Help: buscar en SAP" })
	end
	if actions.filter then
		vim.keymap.set("n", "/", actions.filter, { buffer = buf, desc = "SAP Help: filtrar panel" })
	end
	if actions.clear_filter then
		vim.keymap.set("n", "c", actions.clear_filter, { buffer = buf, desc = "SAP Help: limpiar filtro" })
	end
	if actions.favorite then
		vim.keymap.set("n", "m", actions.favorite, { buffer = buf, desc = "SAP Help: marcar favorito" })
	end
end

local function show_panel(query, opts)
	opts = opts or {}
	local state = opts.state or {
		query = query,
		kind = opts.all_types and "all" or infer_kind(query, opts),
		rows = nil,
		status = nil,
		filter = nil,
		all_types = opts.all_types ~= false,
		section = opts.section or "docs",
	}
	state.query = clean_query(state.query or query)
	state.kind = state.all_types and "all" or infer_kind(state.query, { kind = state.kind })
	record_history(state.query, state.kind)
	local buf = opts.buf
	local function render(status)
		if status then
			state.status = status
		end
		local lines, line_actions, line_items = build_lines(state)
		set_lines(buf, lines)
		vim.b[buf].sap_help_actions = line_actions
		vim.b[buf].sap_help_items = line_items
	end
	local function refresh(force_live)
		render("consultando indice/ADT...")
		M.search_adt(state.query, {
			kind = state.kind,
			all_types = state.all_types,
			force_live = force_live or opts.force_live,
		}, function(rows, status)
			if vim.api.nvim_buf_is_valid(buf) then
				state.rows = rows
				state.status = status
				render(status)
			end
		end)
	end
	state.rerender = function(force_refresh)
		pcall(vim.api.nvim_buf_set_name, buf, "sap-help://" .. state.query)
		if force_refresh then
			refresh()
		else
			render()
		end
	end
	if not buf or not vim.api.nvim_buf_is_valid(buf) then
		buf = vim.api.nvim_create_buf(true, true)
		vim.bo[buf].buftype = "nofile"
		vim.bo[buf].bufhidden = "wipe"
		vim.bo[buf].swapfile = false
		vim.bo[buf].filetype = "markdown"
		pcall(vim.api.nvim_buf_set_name, buf, "sap-help://" .. query)
		vim.cmd("botright vertical split")
		vim.api.nvim_win_set_buf(0, buf)
		pcall(vim.api.nvim_win_set_width, 0, docs_config().panel_width or 72)
	end
	map_help_actions(buf, state, {
		render = render,
		refresh = function()
			refresh(true)
		end,
		search = function()
			vim.ui.input({ prompt = "Buscar en SAP Help/ADT: ", default = state.query }, function(input)
				input = clean_query(input or "")
				if input == "" then
					return
				end
				state.query = input
				state.kind = state.all_types and "all" or infer_kind(input, {})
				state.rows = nil
				state.status = nil
				state.filter = nil
				state.section = "docs"
				record_history(state.query, state.kind)
				pcall(vim.api.nvim_buf_set_name, buf, "sap-help://" .. input)
				show_panel(input, { buf = buf, state = state })
			end)
		end,
		filter = function()
			vim.ui.input({ prompt = "Filtrar resultados del panel: ", default = state.filter or "" }, function(input)
				if input == nil then
					return
				end
				state.filter = clean_query(input)
				render()
			end)
		end,
		clear_filter = function()
			state.filter = nil
			render()
		end,
		favorite = function()
			local line = vim.api.nvim_win_get_cursor(0)[1]
			local item = (vim.b[buf].sap_help_items or {})[line]
			if item and item.kind == "adt" then
				if favorite_row(item.row, state.query) then
					notify("Favorito ADT guardado: " .. item.row.name)
					render()
				end
				return
			end
			if favorite_query((item and item.query) or state.query) then
				notify("Busqueda guardada como favorita: " .. ((item and item.query) or state.query))
				render()
			end
		end,
	})
	refresh()
end

function M.panel_search()
	local buf = vim.api.nvim_get_current_buf()
	if vim.bo[buf].filetype == "markdown" and (vim.api.nvim_buf_get_name(buf) or ""):match("^sap%-help://") then
		vim.ui.input({ prompt = "Buscar en SAP Help/ADT: " }, function(input)
			input = clean_query(input or "")
			if input ~= "" then
				show_panel(input, { buf = buf, all_types = true })
			end
		end)
		return
	end
	M.panel("")
end

function M.panel(query, opts)
	query = clean_query(query ~= "" and query or cursor_symbol())
	if query == "" then
		notify("No hay simbolo o busqueda para documentar.", vim.log.levels.WARN)
		return
	end
	show_panel(query, opts)
end

function M.hover(query, opts)
	query = clean_query(query ~= "" and query or cursor_symbol())
	if query == "" then
		notify("No hay simbolo o busqueda para documentar.", vim.log.levels.WARN)
		return
	end
	local kind = infer_kind(query, opts)
	local hover_state = {
		query = query,
		kind = kind,
		rows = nil,
		status = "consultando ADT...",
		filter = nil,
		all_types = false,
		section = "docs",
	}
	local lines, line_actions, line_items = build_lines(hover_state)
	local buf, win = vim.lsp.util.open_floating_preview(lines, "markdown", {
		border = "rounded",
		focusable = true,
		max_width = 96,
		max_height = 28,
	})
	local function close()
		if vim.api.nvim_win_is_valid(win) then
			vim.api.nvim_win_close(win, true)
		end
	end
	vim.b[buf].sap_help_actions = line_actions
	vim.b[buf].sap_help_items = line_items
	hover_state.rerender = function() end
	map_help_actions(buf, hover_state, { render = function() end })
	vim.keymap.set("n", "q", close, { buffer = buf, nowait = true, desc = "SAP Help: cerrar" })
	pcall(vim.api.nvim_set_current_win, win)
	M.search_adt(query, { kind = kind }, function(rows, status)
		if vim.api.nvim_buf_is_valid(buf) then
			hover_state.rows = rows
			hover_state.status = status
			local updated, updated_actions, updated_items = build_lines(hover_state)
			set_lines(buf, updated)
			vim.b[buf].sap_help_actions = updated_actions
			vim.b[buf].sap_help_items = updated_items
		end
	end)
end

function M.open(query, opts)
	query = clean_query(query ~= "" and query or cursor_symbol())
	if query == "" then
		notify("No hay simbolo o busqueda para abrir.", vim.log.levels.WARN)
		return
	end
	local kind = infer_kind(query, opts)
	local links = official_links(query, kind)
	open_url(links[1] and links[1].url)
end

function M.search(query, opts)
	query = clean_query(query or "")
	local function run(q)
		q = clean_query(q)
		if q == "" then
			return
		end
		record_history(q, infer_kind(q, opts))
		M.search_adt(q, opts or {}, function(rows, status)
			local kind = infer_kind(q, opts)
			if #rows == 0 then
				notify(status or "Sin resultados ADT; abriendo panel con enlaces oficiales.", vim.log.levels.WARN)
				show_panel(q, { kind = kind })
				return
			end
			local links = official_links(q, kind)
			local items = {}
			for _, link in ipairs(links) do
				items[#items + 1] = { kind = "url", label = "Abrir " .. link.label, url = link.url }
			end
			for _, row in ipairs(rows) do
				items[#items + 1] = { kind = "adt", row = row }
			end
			vim.ui.select(items, {
				prompt = "SAP Help ADT (" .. q .. "):",
				format_item = function(item)
					if item.kind == "url" then
						return item.label
					end
					return result_label(item.row)
				end,
			}, function(choice)
				if not choice then
					return
				end
				if choice.kind == "url" then
					open_url(choice.url)
				else
					show_panel(choice.row.name, { kind = infer_kind(choice.row.name, opts) })
				end
			end)
		end)
	end
	if query ~= "" then
		run(query)
		return
	end
	vim.ui.input({ prompt = "Buscar documentacion SAP oficial: " }, run)
end

function M.validate_routes()
	if not adt_http.is_available() then
		notify("ADT no esta validado. Las URLs oficiales configurables estan disponibles como fallback.", vim.log.levels.WARN)
		return
	end
	M.search_adt("BAPI*", { kind = "function", max_results = 1 }, function(_, status)
		if status then
			notify(status, vim.log.levels.WARN)
		else
			notify("Ruta ADT quickSearch disponible: /sap/bc/adt/repository/informationsystem/search")
		end
	end)
end

M._test = {
	parse_search_body = parse_search_body,
	build_lines = build_lines,
	load_store = load_store,
	record_history = record_history,
	favorite_query = favorite_query,
	favorite_row = favorite_row,
	fgroup_from_uri = fgroup_from_uri,
	type_info = TYPE_INFO,
}

function M.setup()
	vim.api.nvim_create_user_command("SapHelp", function(a)
		M.hover(a.args)
	end, { nargs = "*", desc = "sap-nvim: ayuda SAP oficial en hover/popup" })
	vim.api.nvim_create_user_command("SapHelpPanel", function(a)
		M.panel(a.args)
	end, { nargs = "*", desc = "sap-nvim: ayuda SAP oficial en panel lateral" })
	vim.api.nvim_create_user_command("SapHelpPanelSearch", function()
		M.panel_search()
	end, { desc = "sap-nvim: buscar dentro del panel SAP Help" })
	vim.api.nvim_create_user_command("SapHelpOpen", function(a)
		M.open(a.args)
	end, { nargs = "*", desc = "sap-nvim: abrir busqueda oficial SAP en navegador" })
	vim.api.nvim_create_user_command("SapHelpSearch", function(a)
		M.search(a.args)
	end, { nargs = "*", desc = "sap-nvim: buscar documentacion/objetos SAP via ADT" })
	vim.api.nvim_create_user_command("SapHelpRoutes", M.validate_routes,
		{ desc = "sap-nvim: validar ruta ADT de ayuda/busqueda" })
	vim.api.nvim_create_user_command("SapHelpBrowser", M.browser_status,
		{ desc = "sap-nvim: diagnosticar lanzador de navegador para SAP Help" })
end

return M
