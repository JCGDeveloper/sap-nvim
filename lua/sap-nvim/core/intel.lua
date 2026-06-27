local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local objtype = require("sap-nvim.core.objtype")

local SAP_FILETYPES = { abap = true, cds = true, acds = true, abapcds = true, ddl = true, ddls = true }
local function is_sap_ft(ft)
	return SAP_FILETYPES[ft or vim.bo.filetype] == true
end
M.is_sap_ft = is_sap_ft

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function unxml(s)
	if not s then
		return ""
	end
	return s:gsub("&lt;", "<")
		:gsub("&gt;", ">")
		:gsub("&quot;", '"')
		:gsub("&apos;", "'")
		:gsub("&#x0A;", "\n")
		:gsub("&#x0D;", "\r")
		:gsub("&#10;", "\n")
		:gsub("&#13;", "\r")
		:gsub("&amp;", "&")
end

local function get_word_range(bufnr, row, col)
	local cstart, cend = col, col
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
	if line and #line > 0 then
		local cur = col + 1
		if cur <= #line and line:sub(cur, cur):match("[%w_/~%-]") then
			local i = cur
			while i > 1 and line:sub(i - 1, i - 1):match("[%w_/~%-]") do
				i = i - 1
			end
			local j = cur
			while j < #line and line:sub(j + 1, j + 1):match("[%w_/~%-]") do
				j = j + 1
			end
			cstart = i - 1
			cend = j
		end
	end
	return cstart, cend
end

local function local_abap_field_proposals(bufnr, line, col)
	local linetext = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	local before = linetext:sub(1, col)
	local owner, prefix = before:match("([%w_<>]+)%-([%w_]*)$")
	if not owner then
		return {}
	end

	local owner_key = owner:gsub("[<>]", ""):lower()
	local pl = (prefix or ""):lower()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local type_fields, var_type, table_row_type = {}, {}, {}

	local cur_type
	for _, raw in ipairs(lines) do
		local l = raw:gsub("\".*$", "")
		local begin_type = l:match("^[Tt][Yy][Pp][Ee][Ss]:?%s+[Bb][Ee][Gg][Ii][Nn]%s+[Oo][Ff]%s+([%w_]+)")
		if begin_type then
			cur_type = begin_type:lower()
			type_fields[cur_type] = type_fields[cur_type] or {}
		elseif cur_type and l:lower():match("end%s+of%s+" .. vim.pesc(cur_type)) then
			cur_type = nil
		elseif cur_type then
			local fld = l:match("^%s*([%w_]+)%s+[%w%-]*[Tt][Yy][Pp][Ee]")
				or l:match("^%s*([%w_]+)%s+[%w%-]*[Ll][Ii][Kk][Ee]")
			if fld and fld:lower() ~= "include" then
				type_fields[cur_type][#type_fields[cur_type] + 1] = fld
			end
		end

		for v, t in l:gmatch("[Dd][Aa][Tt][Aa]:?%s+([%w_]+)%s+[%w%-]*[Tt][Yy][Pp][Ee]%s+([%w_]+)") do
			var_type[v:lower()] = t:lower()
		end
		for v, t in l:gmatch("[Ff][Ii][Ee][Ll][Dd]%-[Ss][Yy][Mm][Bb][Oo][Ll][Ss]:?%s+<([%w_]+)>%s+[%w%-]*[Tt][Yy][Pp][Ee]%s+([%w_]+)") do
			var_type[v:lower()] = t:lower()
		end
		for v, t in l:gmatch("[Dd][Aa][Tt][Aa]:?%s+([%w_]+)%s+[%w%-]*[Tt][Yy][Pp][Ee]%s+[%w%s]*[Tt][Aa][Bb][Ll][Ee]%s+[Oo][Ff]%s+([%w_]+)") do
			table_row_type[v:lower()] = t:lower()
			var_type[v:lower()] = t:lower()
		end
		for tab, fs in l:gmatch("[Ll][Oo][Oo][Pp]%s+[Aa][Tt]%s+([%w_]+)%s+.-[Aa][Ss][Ss][Ii][Gg][Nn][Ii][Nn][Gg]%s+<([%w_]+)>") do
			local row_type = table_row_type[tab:lower()]
			if row_type then
				var_type[fs:lower()] = row_type
			end
		end
	end

	local typ = var_type[owner_key] or table_row_type[owner_key]
	local fields = typ and type_fields[typ] or nil
	if not fields or #fields == 0 then
		return {}
	end
	local out = {}
	for _, f in ipairs(fields) do
		if pl == "" or f:lower():sub(1, #pl) == pl then
			out[#out + 1] = { word = f:upper(), kind = "1", prefixlength = #prefix }
		end
	end
	return out
end

local ADT_URI = {
	class = "/sap/bc/adt/oo/classes/%s/source/main",
	interface = "/sap/bc/adt/oo/interfaces/%s/source/main",
	program = "/sap/bc/adt/programs/programs/%s/source/main",
	include = "/sap/bc/adt/programs/includes/%s/source/main",
	functiongroup = "/sap/bc/adt/functions/groups/%s/source/main",
	structure = "/sap/bc/adt/ddic/structures/%s/source/main",
	table = "/sap/bc/adt/ddic/tables/%s/source/main",
	dataelement = "/sap/bc/adt/ddic/dataelements/%s/source/main",
	tabletype = "/sap/bc/adt/ddic/tabletypes/%s/source/main",
	domain = "/sap/bc/adt/ddic/domains/%s/source/main",
	ddl = "/sap/bc/adt/ddic/ddl/sources/%s/source/main",
	ddls = "/sap/bc/adt/ddic/ddl/sources/%s/source/main",
	ddlx = "/sap/bc/adt/ddic/ddlx/sources/%s/source/main",
	dcl = "/sap/bc/adt/acm/dcl/sources/%s/source/main",
	bdef = "/sap/bc/adt/bo/behaviordefinitions/%s/source/main",
	srvd = "/sap/bc/adt/ddic/srvd/sources/%s/source/main",
	acds = "/sap/bc/adt/ddic/ddl/sources/%s/source/main",
	abapcds = "/sap/bc/adt/ddic/ddl/sources/%s/source/main",
}

function M.object_uri(bufnr)
	local meta = vim.b[bufnr].sap_obj
	if meta and meta.uri and meta.uri ~= "" then
		local uri = meta.uri:gsub("/source/main$", "")
		return uri .. "/source/main"
	end
	local group = meta and meta.group or objtype.group(vim.api.nvim_buf_get_name(bufnr))
	local name = meta and meta.name or objtype.name(vim.api.nvim_buf_get_name(bufnr))
	if meta and meta.group == "functionmodule" and meta.fgroup then
		return "/sap/bc/adt/functions/groups/"
			.. meta.fgroup:lower()
			.. "/fmodules/"
			.. meta.name:lower()
			.. "/source/main"
	end
	local tmpl = group and ADT_URI[group]
	if not tmpl or not name or name == "" then
		return nil
	end
	return tmpl:format(name:lower())
end

local mainprog_cache = {}

function M.main_programs(incname)
	local body = adt_http.request({
		method = "GET",
		path = "/sap/bc/adt/programs/includes/" .. incname:lower() .. "/mainprograms",
		accept = "application/*",
	})
	local uris = {}
	for u in (body or ""):gmatch('adtcore:uri="([^"]*)"') do
		uris[#uris + 1] = u
	end
	return uris
end

local function context_suffix(bufnr)
	local meta = vim.b[bufnr].sap_obj
	if not meta or meta.group ~= "include" then
		return ""
	end
	local key = meta.name:lower()
	if mainprog_cache[key] == nil then
		local uris = M.main_programs(meta.name)
		mainprog_cache[key] = uris[1] or false
	end
	local uri = mainprog_cache[key]
	if not uri then
		return ""
	end
	return "?context=" .. uri
end

function M.change_include()
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sap_obj
	if not meta or meta.group ~= "include" then
		return notify("El buffer actual no es un include.", vim.log.levels.WARN)
	end
	local uris = M.main_programs(meta.name)
	if #uris == 0 then
		return notify("El include no tiene programa principal asignado.", vim.log.levels.WARN)
	end
	if #uris == 1 then
		mainprog_cache[meta.name:lower()] = uris[1]
		return notify("Programa principal: " .. uris[1]:match("([^/]+)$"))
	end
	vim.ui.select(uris, {
		prompt = "Programa principal del include:",
		format_item = function(u)
			return u:match("([^/]+)$")
		end,
	}, function(choice)
		if choice then
			mainprog_cache[meta.name:lower()] = choice
			notify("Programa principal: " .. choice:match("([^/]+)$"))
		end
	end)
end

function M.parse(body)
	local items = {}
	if not body then
		return items
	end

	for name, typ in body:gmatch('<abapsource:codeCompletion[^>]-adtcore:name="([^"]*)"[^>]-adtcore:type="([^"]*)"') do
		items[#items + 1] = { word = name, kind = typ }
	end
	if #items == 0 then
		for typ, name in body:gmatch('<abapsource:codeCompletion[^>]-adtcore:type="([^"]*)"[^>]-adtcore:name="([^"]*)"') do
			items[#items + 1] = { word = name, kind = typ }
		end
	end
	if #items == 0 then
		for name, kind in body:gmatch('<scc:codeCompletionProposal[^>]-scc:identifier="([^"]*)"[^>]-scc:kind="([^"]*)"') do
			items[#items + 1] = { word = name, kind = kind }
		end
	end
	if #items == 0 then
		for block in body:gmatch("<SCC_COMPLETION>(.-)</SCC_COMPLETION>") do
			local id = block:match("<IDENTIFIER>([^<]*)</IDENTIFIER>")
			local kind = block:match("<KIND>([^<]*)</KIND>")
			local plen = tonumber(block:match("<PREFIXLENGTH>([^<]*)</PREFIXLENGTH>"))

			local pattern = block:match("<PATTERN>(.-)</PATTERN>")
			if pattern then
				local cdata = pattern:match("<!%[CDATA%[(.-)%]%]>")
				if cdata then
					pattern = cdata
				end
				pattern = unxml(pattern)
			end

			if id and id ~= "" and id ~= "@end" then
				items[#items + 1] = { word = id, kind = kind, prefixlength = plen, pattern = pattern }
			end
		end
	end
	return items
end

function M.proposals(bufnr, line, col)
	if not adt_http.is_available() then
		return {}
	end
	local uri = M.object_uri(bufnr)
	if not uri then
		return {}
	end
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local q = { uri = uri .. "#start=" .. line .. "," .. col, signalCompleteness = "true", getPattern = "true" }
	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = q,
		content_type = "text/plain",
		body = src,
	})
	if not body or (not body:find("SCC_COMPLETION") and not body:find("codeCompletion")) then
		adt_http.reset_token()
		body = adt_http.request({
			method = "POST",
			path = "/sap/bc/adt/abapsource/codecompletion/proposal",
			query = q,
			content_type = "text/plain",
			body = src,
		}) or ""
	end
	return M.parse(body)
end

function M.proposals_async(bufnr, line, col, cb)
	if not adt_http.is_available() then
		return cb({})
	end
	local linetext = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	local before = linetext:sub(1, col)

	local ok_cds, cds = pcall(require, "sap-nvim.core.cds")
	local is_cds_file = ok_cds and cds.is_cds_buf(bufnr)

	if is_cds_file or is_sap_ft(vim.bo.filetype) and vim.bo.filetype ~= "abap" then
		cds.completion(bufnr, line, col, function(items)
			cb(items or {})
		end)
		return
	end

	if before:match("@[%w%._]*$") then
		local prefix = before:match("@([%w%._]*)$") or ""
		require("sap-nvim.core.cds").annotation_proposals(prefix, function(items)
			cb(items or {})
		end)
		return
	end

	local before_lower = before:lower()
	local is_type = before_lower:match("type%s+ref%s+to%s+([%w_]*)$")

	if is_type then
		require("sap-nvim.core.adt").fetch_objects(is_type .. "*", function(results, err)
			local items = {}
			if results then
				for _, res in ipairs(results) do
					local name = res:match("|%s*([^%s|]+)")
					if name and name ~= "Name" then
						items[#items + 1] = { word = name, kind = "2" }
					end
				end
			end
			table.sort(items, function(a, b)
				return a.word < b.word
			end)
			cb(items)
		end)
		return
	end

	local uri = M.object_uri(bufnr)
	if not uri then
		return cb(local_abap_field_proposals(bufnr, line, col))
	end
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	-- 🔥 FIX: Usamos el content_type adecuado que fuerza la recarga del AST en SAP
	local q = {
		uri = uri .. context_suffix(bufnr) .. "#start=" .. line .. "," .. col,
		signalCompleteness = "true",
		getPattern = "true",
	}

	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = q,
		content_type = "application/vnd.sap.adt.abapsource.codecompletion.proposal.v3+xml", -- Asegura parsing estricto
		body = src,
	}, function(body)
		-- Fallback de seguridad al content_type básico si el v3 falla
		if not body or body == "" or body:match("Unsupported Media Type") then
			adt_http.request_async({
				method = "POST",
				path = "/sap/bc/adt/abapsource/codecompletion/proposal",
				query = q,
				content_type = "application/*",
				body = src,
			}, function(body2)
				local parsed = M.parse(body2)
				if #parsed == 0 then
					parsed = local_abap_field_proposals(bufnr, line, col)
				end
				cb(parsed)
			end)
			return
		end
		local parsed = M.parse(body)
		if #parsed == 0 then
			parsed = local_abap_field_proposals(bufnr, line, col)
		end
		cb(parsed)
	end)
end

function M.omnifunc(findstart, base)
	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	if findstart == 1 then
		local linetext = vim.api.nvim_get_current_line()
		local s = col
		while s > 0 and linetext:sub(s, s):match("[%w_]") do
			s = s - 1
		end
		return s
	end
	local items = M.proposals(bufnr, row, col)
	local out = {}
	local needle = (base or ""):lower()
	for _, it in ipairs(items) do
		if needle == "" or it.word:lower():sub(1, #needle) == needle then
			out[#out + 1] = { word = it.word, menu = "[SAP]" }
		end
	end
	return out
end

function M.complete()
	if not adt_http.is_available() then
		return notify("ADT no disponible.", vim.log.levels.WARN)
	end
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
end

function M.complete_debug()
	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local before = vim.api.nvim_get_current_line():sub(1, col)
	local meta = vim.b[bufnr].sap_obj
	local uri = M.object_uri(bufnr)
	local out = {}
	local function add(s)
		out[#out + 1] = s
	end
	add("== sap-nvim · diagnóstico de completado ==")
	add("filetype  : " .. vim.bo[bufnr].filetype)
	add("sap_obj   : " .. vim.inspect(meta))
	add("object_uri: " .. tostring(uri))
	add("cursor    : línea " .. row .. ", col " .. col)
	add("antes     : '" .. before .. "'")
	add("adt avail : " .. tostring(adt_http.is_available()))

	local function show()
		local flat = {}
		for _, s in ipairs(out) do
			for _, l in ipairs(vim.split(tostring(s):gsub("\r", ""), "\n", { plain = true })) do
				flat[#flat + 1] = l
			end
		end
		local buf = vim.api.nvim_create_buf(false, true)
		vim.api.nvim_buf_set_lines(buf, 0, -1, false, flat)
		vim.bo[buf].bufhidden = "wipe"
		vim.cmd("botright split")
		vim.api.nvim_win_set_buf(0, buf)
	end

	local CDS_G = { ddl = true, ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
	if meta and CDS_G[meta.group] then
		add("ruta      : CDS (ddicrepositoryaccess)")
		require("sap-nvim.core.cds").completion_debug(bufnr, row, col, function(info, body)
			vim.schedule(show)
		end)
		return
	end

	if not uri then
		return show()
	end

	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = { uri = uri .. "#start=" .. row .. "," .. col, signalCompleteness = "true", getPattern = "true" },
		content_type = "text/plain",
		body = src,
	}) or ""
	local items = M.parse(body)
	add("propuestas (SYNC text/plain): " .. #items)
	for i = 1, math.min(#items, 10) do
		add("  · " .. tostring(items[i].word) .. "  [kind " .. tostring(items[i].kind) .. "]")
	end
	M.proposals_async(bufnr, row, col, function(aitems)
		add("")
		add("propuestas (ASYNC = ruta de blink): " .. #(aitems or {}))
		for i = 1, math.min(#(aitems or {}), 10) do
			add(
				"  · "
					.. tostring(aitems[i].word)
					.. "  [kind "
					.. tostring(aitems[i].kind)
					.. " · plen "
					.. tostring(aitems[i].prefixlength)
					.. "]"
			)
		end
		vim.schedule(show)
	end)
end

local HL_NS = vim.api.nvim_create_namespace("sap_nvim_doc_highlight")
function M.clear_highlight(bufnr)
	vim.api.nvim_buf_clear_namespace(bufnr or vim.api.nvim_get_current_buf(), HL_NS, 0, -1)
end

function M.document_highlight()
	local bufnr = vim.api.nvim_get_current_buf()
	M.clear_highlight(bufnr)
	local word = vim.fn.expand("<cword>")
	if not word or #word < 3 then
		return
	end
	local plain = word:lower():gsub("[%-%.%+%[%]%(%)%$%^%%%?%*]", "%%%1")
	local pat = "%f[%w_]" .. plain .. "%f[^%w_]"
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	for i, l in ipairs(lines) do
		local low, s = l:lower(), 1
		while true do
			local a, b = low:find(pat, s)
			if not a then
				break
			end
			pcall(
				vim.api.nvim_buf_set_extmark,
				bufnr,
				HL_NS,
				i - 1,
				a - 1,
				{ end_col = b, hl_group = "LspReferenceText" }
			)
			s = b + 1
		end
	end
end

local URI_PATTERNS = {
	{ "^/sap/bc/adt/oo/classes/([^/]+)", "class" },
	{ "^/sap/bc/adt/oo/interfaces/([^/]+)", "interface" },
	{ "^/sap/bc/adt/programs/includes/([^/]+)", "include" },
	{ "^/sap/bc/adt/programs/programs/([^/]+)", "program" },
	{ "^/sap/bc/adt/functions/groups/([^/]+)", "functiongroup" },
	{ "^/sap/bc/adt/dictionary/structures/([^/]+)", "structure" },
	{ "^/sap/bc/adt/dictionary/tables/([^/]+)", "table" },
	{ "^/sap/bc/adt/dictionary/dataelements/([^/]+)", "dataelement" },
	{ "^/sap/bc/adt/dictionary/tabletypes/([^/]+)", "tabletype" },
	{ "^/sap/bc/adt/dictionary/domains/([^/]+)", "domain" },
	{ "^/sap/bc/adt/ddic/structures/([^/]+)", "structure" },
	{ "^/sap/bc/adt/ddic/tables/([^/]+)", "table" },
	{ "^/sap/bc/adt/ddic/dataelements/([^/]+)", "dataelement" },
	{ "^/sap/bc/adt/ddic/domains/([^/]+)", "domain" },
	{ "^/sap/bc/adt/ddic/ddl/sources/([^/]+)", "ddls" },
	{ "^/sap/bc/adt/ddic/ddlx/sources/([^/]+)", "ddlx" },
	{ "^/sap/bc/adt/acm/dcl/sources/([^/]+)", "dcl" },
	{ "^/sap/bc/adt/bo/behaviordefinitions/([^/]+)", "bdef" },
	{ "^/sap/bc/adt/ddic/srvd/sources/([^/]+)", "srvd" },
}

local function uri_to_object(uri)
	local path, frag = uri:match("^([^#]+)#?(.*)$")
	path = path or uri
	local line, col = (frag or ""):match("start=(%d+),(%d+)")
	for _, p in ipairs(URI_PATTERNS) do
		local name = path:match(p[1])
		if name then
			return { group = p[2], name = name:upper(), line = tonumber(line), col = tonumber(col), raw_path = path }
		end
	end
	return nil
end

function M.definition_target(bufnr, row, col, filter)
	if not adt_http.is_available() then
		return nil
	end
	local uri = M.object_uri(bufnr)
	if not uri then
		return nil
	end
	local cstart, cend = get_word_range(bufnr, row, col)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local ctx = context_suffix(bufnr)

	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/navigation/target",
		query = {
			uri = uri .. ctx .. "#start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend,
			filter = filter or "definition",
		},
		content_type = "text/plain",
		body = src,
	})
	local target = body and body:match('adtcore:uri="([^"]*)"')

	if not target or target == "" then
		local word = vim.fn.expand("<cword>")
		if word and word ~= "" then
			local fb_body = adt_http.request({
				method = "GET",
				path = "/sap/bc/adt/ddic/ddl/ddicrepositoryaccess",
				query = { datasource = word, uriRequired = "X" },
				accept = "application/*",
			})
			if fb_body then
				target = fb_body:match('adtcore:uri="([^"]*)"')
			end
		end
	end
	return (target and target ~= "" and target ~= "not_used") and uri_to_object(unxml(target)) or nil
end

function M.goto_definition(filter)
	if filter == true then
		filter = "typeDefinition"
	end
	filter = filter or "definition"

	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local meta = vim.b[bufnr].sap_obj
	local word = vim.fn.expand("<cword>")

	local function search_ddic(w)
		if not w or w == "" then
			return nil
		end
		local body = adt_http.request({
			method = "GET",
			path = "/sap/bc/adt/ddic/ddl/ddicrepositoryaccess",
			query = { datasource = w, uriRequired = "X" },
			accept = "application/*",
		})
		local target = body and body:match('adtcore:uri="([^"]*)"')
		if target and target ~= "" and target ~= "not_used" then
			return uri_to_object(unxml(target))
		end
		return nil
	end

	local obj = M.definition_target(bufnr, row, col, filter)
	local is_exact_same_line = (obj and meta and obj.name == meta.name:upper() and obj.line == row)

	if not obj or is_exact_same_line then
		local ddic_obj = search_ddic(word)
		if ddic_obj then
			obj = ddic_obj
		end
	end

	if not obj then
		vim.notify("SAP: Sin def remota. Buscando local...", vim.log.levels.INFO)
		pcall(vim.cmd, "normal! gD")
		return true
	end

	if meta and meta.name:upper() == obj.name and obj.line then
		if obj.line ~= row then
			pcall(vim.api.nvim_win_set_cursor, 0, { obj.line, obj.col or 0 })
			vim.cmd("normal! zz")
		else
			pcall(vim.cmd, "normal! gD")
		end
	else
		local cds_groups = { ddl = true, ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
		if cds_groups[obj.group] then
			require("sap-nvim.core.cds").open_adt(obj.group, obj.name, { line = obj.line, col = obj.col })
		else
			require("sap-nvim.core.source").open(obj.name:upper(), obj.group, { line = obj.line, col = obj.col })
		end
	end
	return true
end

function M.hover()
	vim.lsp.handlers["textDocument/hover"] = function() end
	if hover_win and vim.api.nvim_win_is_valid(hover_win) then
		return vim.api.nvim_set_current_win(hover_win)
	end
	if not adt_http.is_available() then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local uri = M.object_uri(bufnr)
	if not uri then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local cstart, cend = get_word_range(bufnr, row, col)
	local ctx = context_suffix(bufnr)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\r\n")

	local req_params = {
		method = "POST",
		path = "/sap/bc/adt/abapsource/elementinfo",
		query = { uri = uri .. ctx .. "#start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend },
		content_type = "text/plain",
		accept = "application/xml",
		body = src,
	}
	local body = adt_http.request(req_params)
	if not body or not body:find("elementInfo") then
		adt_http.reset_token()
		body = adt_http.request(req_params)
	end

	local target = nil
	if not body or not body:find("elementInfo") then
		target = M.definition_target(bufnr, row, col, "definition")
		if target and target.raw_path then
			local obj_uri = target.raw_path:gsub("/source/main.*", "")
			body = adt_http.request({
				method = "POST",
				path = "/sap/bc/adt/abapsource/elementinfo",
				query = { uri = obj_uri },
				content_type = "text/plain",
				accept = "application/xml",
				body = "",
			})
		end
	end

	local preview = {}
	if body and body:find("elementInfo") then
		local is_first = true
		for attrs in body:gmatch("<[%w_:]*elementInfo%s([^>]+)") do
			local name = attrs:match('adtcore:name="([^"]*)"')
			local desc = attrs:match('adtcore:description="([^"]*)"')
			local typ = attrs:match('adtcore:type="([^"]*)"')
			if name then
				name, desc, typ = unxml(name), unxml(desc), unxml(typ)
				if is_first then
					table.insert(preview, "### " .. name)
					if desc and desc ~= "" and desc ~= name then
						table.insert(preview, "*" .. desc .. "*")
					end
					table.insert(preview, "---")
					is_first = false
				else
					local item_text = "- **" .. name .. "**"
					if typ and ADT_KIND_MAP and ADT_KIND_MAP[typ] then
						item_text = item_text .. " `[" .. ADT_KIND_MAP[typ] .. "]`"
					end
					if desc and desc ~= "" and desc ~= name then
						item_text = item_text .. ": " .. desc
					end
					table.insert(preview, item_text)
				end
			end
		end
	end

	if #preview == 0 then
		local word = vim.fn.expand("<cword>")
		if not target then
			target = M.definition_target(bufnr, row, col, "definition")
		end
		local code_line, def_name, def_line = "", "", 0

		local function extract_statement(lines_table, start_idx, group)
			local stmt, in_braces = {}, false
			local is_ddic = (group == "table" or group == "structure" or group == "ddl" or group == "ddls")
			for i = start_idx, math.min(start_idx + (is_ddic and 50 or 50), #lines_table) do
				local l = lines_table[i] or ""
				table.insert(stmt, l)
				local clean = l:gsub("'.-'", ""):gsub('".*', ""):gsub("^%*.*", ""):gsub("//.*", "")
				if clean:match("{") then
					in_braces = true
				end
				if in_braces and clean:match("}") then
					break
				end
				if not in_braces and not is_ddic and (clean:match("%.") or clean:match(";")) then
					break
				end
			end
			local min_ind = nil
			for _, l in ipairs(stmt) do
				if vim.trim(l) ~= "" then
					local ind = #(l:match("^%s*") or "")
					if not min_ind or ind < min_ind then
						min_ind = ind
					end
				end
			end
			local res = {}
			for _, l in ipairs(stmt) do
				table.insert(res, l:sub((min_ind or 0) + 1))
			end
			return table.concat(res, "\n")
		end

		if target then
			def_name = target.name
			def_line = target.line or 1
			local current_meta = vim.b[bufnr].sap_obj
			if current_meta and current_meta.name:upper() == target.name then
				local current_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				code_line = extract_statement(current_lines, def_line, target.group)
			else
				if target.raw_path then
					local source_uri = target.raw_path
					if not source_uri:match("/source/main$") then
						source_uri = source_uri .. "/source/main"
					end
					local src_body = adt_http.request({ method = "GET", path = source_uri, accept = "text/plain" })
					if src_body then
						local source_lines = vim.split(src_body:gsub("\r", ""), "\n")
						code_line = extract_statement(source_lines, def_line, target.group)
					end
				end
			end
		else
			local local_lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			for i, l in ipairs(local_lines) do
				if
					l:lower():match("data:%s*" .. word:lower())
					or l:lower():match("types:%s*" .. word:lower())
					or l:lower():match("constants:%s*" .. word:lower())
				then
					def_line = i
					def_name = (vim.b[bufnr].sap_obj and vim.b[bufnr].sap_obj.name) or "Local File"
					code_line = extract_statement(local_lines, i, "local")
					break
				end
			end
		end
		if code_line ~= "" then
			table.insert(preview, "📦 **Definición:** `" .. word .. "`")
			table.insert(preview, "")
			table.insert(preview, "```abap\n" .. code_line .. "\n```")
			table.insert(preview, "")
			table.insert(preview, "*Defined in " .. def_name .. " (Line " .. def_line .. ")*")
		end
	end

	if #preview == 0 then
		return vim.notify("SAP no devolvió información ni código.", vim.log.levels.WARN)
	end
	local float_buf, float_win = vim.lsp.util.open_floating_preview(
		preview,
		"markdown",
		{ border = "rounded", focusable = true, max_width = 85, max_height = 25 }
	)
	hover_win = float_win
	vim.keymap.set("n", "q", function()
		if hover_win and vim.api.nvim_win_is_valid(hover_win) then
			vim.api.nvim_win_close(hover_win, true)
			hover_win = nil
		end
	end, { buffer = float_buf })
	vim.api.nvim_create_autocmd("WinClosed", {
		pattern = tostring(float_win),
		once = true,
		callback = function()
			hover_win = nil
		end,
	})
end

local USAGE_REQ =
	'<?xml version="1.0" encoding="UTF-8"?><usagereferences:usageReferenceRequest xmlns:usagereferences="http://www.sap.com/adt/ris/usageReferences"><usagereferences:affectedObjects/></usagereferences:usageReferenceRequest>'

local function local_references_fallback()
	local word = vim.fn.expand("<cword>")
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local qf_list = {}
	for i, line in ipairs(lines) do
		if line:match("%f[%w_]" .. word .. "%f[^%w_]") then
			local col = line:find(word, 1, true)
			table.insert(qf_list, { bufnr = bufnr, lnum = i, col = col, text = vim.trim(line) })
		end
	end
	if #qf_list > 0 then
		vim.notify("[sap-nvim] Mostrando referencias locales (VSCode fallback)", vim.log.levels.INFO)
		vim.fn.setqflist(qf_list, "r")
		vim.cmd("copen")
	else
		vim.notify("[sap-nvim] Sin referencias globales ni locales.", vim.log.levels.WARN)
	end
end

function M.references()
	if local_references_fallback == nil then
		return vim.notify("CRÍTICO: local_references_fallback es NIL.", vim.log.levels.ERROR)
	end
	if not adt_http.is_available() then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local uri = M.object_uri(bufnr)
	if not uri then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local cstart, cend = get_word_range(bufnr, row, col)
	local ctx = context_suffix(bufnr)

	local target_uri = uri .. ctx .. "#start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend

	local function parse_and_show(body)
		if not body or body == "" then
			return local_references_fallback()
		end
		local refs = {}
		for block in body:gmatch("<usageReferences:referencedObject(.-)</usageReferences:referencedObject>") do
			local ref_uri = block:match('uri="([^"]*)"')
			local name = block:match('adtcore:name="([^"]*)"')
			local typ = block:match('adtcore:type="([^"]*)"')
			local descr = block:match('adtcore:description="([^"]*)"')
			if ref_uri and name then
				refs[#refs + 1] = { name = name, typ = typ or "", uri = unxml(ref_uri), snippet = descr or "" }
			end
		end
		if #refs == 0 then
			for obj_block in body:gmatch("<usageReferences:adtObject(.-)</usageReferences:adtObject>") do
				local obj_name = obj_block:match('adtcore:name="([^"]*)"')
				local obj_typ = obj_block:match('adtcore:type="([^"]*)"')
				for ref_block in
					obj_block:gmatch("<usageReferences:usageReference(.-)</usageReferences:usageReference>")
				do
					local ref_uri = ref_block:match('adtcore:uri="([^"]*)"')
					local snippet = ref_block:match("<usageReferences:snippet>([^<]*)</usageReferences:snippet>")
					if ref_uri then
						refs[#refs + 1] = {
							name = obj_name or "?",
							typ = obj_typ or "",
							uri = unxml(ref_uri),
							snippet = unxml(snippet or ""),
						}
					end
				end
			end
		end
		if #refs == 0 then
			return local_references_fallback()
		end

		local seen, unique = {}, {}
		for _, r in ipairs(refs) do
			local key = (r.uri or "") .. "|" .. (r.name or "")
			if not seen[key] then
				seen[key] = true
				unique[#unique + 1] = r
			end
		end
		refs = unique
		table.sort(refs, function(a, b)
			return (a.name or "") < (b.name or "")
		end)

		vim.notify(string.format("[sap-nvim] %d referencias encontradas", #refs), vim.log.levels.INFO)
		vim.ui.select(refs, {
			prompt = "Referencias SAP (" .. #refs .. "):",
			format_item = function(r)
				return string.format("%-45s %-12s %s", r.name or "", r.typ or "", r.snippet or "")
			end,
		}, function(choice)
			if not choice then
				return
			end
			local obj = uri_to_object(choice.uri)
			if obj and obj.group then
				local cds_groups = { ddl = true, ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
				if cds_groups[obj.group] then
					require("sap-nvim.core.cds").open_adt(obj.group, obj.name, { line = obj.line, col = obj.col })
				else
					require("sap-nvim.core.source").open(
						obj.name:upper(),
						obj.group,
						{ line = obj.line, col = obj.col }
					)
				end
			end
		end)
	end

	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/repository/informationsystem/usageReferences",
		query = { uri = target_uri },
		content_type = "application/vnd.sap.adt.repository.usagereferences.request.v1+xml",
		body = USAGE_REQ,
	}, function(body)
		vim.schedule(function()
			if body and body:find("usageReference") then
				parse_and_show(body)
			else
				local target = M.definition_target(bufnr, row, col, "definition")
				if target and target.raw_path then
					local obj_uri = target.raw_path:gsub("/source/main.*", "")
					adt_http.request_async({
						method = "POST",
						path = "/sap/bc/adt/repository/informationsystem/usageReferences",
						query = { uri = obj_uri },
						content_type = "application/vnd.sap.adt.repository.usagereferences.request.v1+xml",
						body = USAGE_REQ,
					}, function(body2)
						vim.schedule(function()
							parse_and_show(body2)
						end)
					end)
				else
					local_references_fallback()
				end
			end
		end)
	end)
end

function M.type_hierarchy(super)
	if not adt_http.is_available() then
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local uri = M.object_uri(bufnr)
	if not uri then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	notify((super and "Buscando supertipos" or "Buscando subtipos") .. "...")
	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/abapsource/typehierarchy",
		query = {
			uri = uri .. context_suffix(bufnr) .. "#start=" .. row .. "," .. col,
			type = super and "superTypes" or "subTypes",
		},
		content_type = "text/plain",
		accept = "application/*",
		body = src,
	})
	if not body then
		return notify("Sin jerarquía de tipos aquí.")
	end
	if body:find("invalidMainProgram") then
		return notify("Abre el programa principal (no el include) para ver la jerarquía.", vim.log.levels.WARN)
	end
	local origin = body:match('<origin[^>]-typeName="([^"]*)"')
	local refs, seen = {}, {}
	for tag in body:gmatch("<entry%s[^>]->") do
		local name = tag:match('adtcore:name="([^"]*)"')
		local typ = tag:match('adtcore:type="([^"]*)"')
		local nav = tag:match('adtcore:uri="([^"]*)"')
		if name and name ~= "" and name ~= origin then
			local key = name .. "|" .. (typ or "")
			if not seen[key] then
				seen[key] = true
				refs[#refs + 1] = { name = name, typ = typ or "", uri = nav and unxml(nav) or nil }
			end
		end
	end
	if #refs == 0 then
		return notify("Sin resultados.")
	end
	vim.ui.select(refs, {
		prompt = (super and "Supertipos" or "Subtipos") .. " (" .. #refs .. "):",
		format_item = function(r)
			return string.format("%-10s %s", r.typ or "", r.name or "")
		end,
	}, function(choice)
		if not choice then
			return
		end
		local obj = choice.uri and uri_to_object(choice.uri) or nil
		if obj and obj.group then
			local cds_groups = { ddl = true, ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
			if cds_groups[obj.group] then
				require("sap-nvim.core.cds").open_adt(obj.group, obj.name, { line = obj.line, col = obj.col })
			else
				require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
			end
		end
	end)
end

local CHECK_NS = vim.api.nvim_create_namespace("sap_nvim_adt_check")
local function b64(s)
	if vim.base64 and vim.base64.encode then
		return vim.base64.encode(s)
	end
	return vim.fn.system({ "base64", "-w0" }, s):gsub("%s+$", "")
end

function M.check_syntax(bufnr, cb)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not adt_http.is_available() or not vim.api.nvim_buf_is_valid(bufnr) then
		if cb then
			cb({})
		end
		return
	end
	local source_uri = M.object_uri(bufnr)
	if not source_uri then
		if cb then
			cb({})
		end
		return
	end
	local obj_uri = source_uri:gsub("/source/main$", "")
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local xml = '<?xml version="1.0" encoding="UTF-8"?><chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" xmlns:adtcore="http://www.sap.com/adt/core"><chkrun:checkObject adtcore:uri="'
		.. obj_uri
		.. context_suffix(bufnr)
		.. '" chkrun:version="inactive"><chkrun:artifacts><chkrun:artifact chkrun:contentType="text/plain; charset=utf-8" chkrun:uri="'
		.. source_uri
		.. '"><chkrun:content>'
		.. b64(src)
		.. "</chkrun:content></chkrun:artifact></chkrun:artifacts></chkrun:checkObject></chkrun:checkObjectList>"
	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/checkruns",
		query = { reporters = "abapCheckRun" },
		content_type = "application/vnd.sap.adt.checkobjects+xml",
		body = xml,
	}, function(body)
		if not body then
			return
		end
		local diags = {}
		for msg in body:gmatch("<chkrun:checkMessage([^>]*)>") do
			local uri = msg:match('chkrun:uri="([^"]*)"')
			local typ = msg:match('chkrun:type="([^"]*)"')
			local text = msg:match('chkrun:shortText="([^"]*)"')
			local line, col = (uri or ""):match("start=(%d+),(%d+)")
			local msg_base = (uri or ""):gsub("#.*$", ""):gsub("/source/main$", "")
			local same_object = uri and (
				msg_base == obj_uri
				or msg_base:find(obj_uri, 1, true)
				or obj_uri:find(msg_base, 1, true)
			)
			if same_object then
				local sev = vim.diagnostic.severity.INFO
				if typ == "E" then
					sev = vim.diagnostic.severity.ERROR
				elseif typ == "W" then
					sev = vim.diagnostic.severity.WARN
				end
				diags[#diags + 1] = {
					lnum = line and math.max(0, tonumber(line) - 1) or 0,
					col = tonumber(col) or 0,
					message = unxml(text or "syntax"),
					severity = sev,
					source = "SAP",
				}
			end
		end
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(bufnr) then
				vim.diagnostic.set(CHECK_NS, bufnr, diags)
			end
			if cb then
				cb(diags)
			end
		end)
	end)
end

-- Lista de errores del check de SAP estilo panel "Problems" de VSCode: corre el check y, si
-- hay errores, abre una loclist navegable (fichero/línea/mensaje; :lne/:lp para saltar). Si no
-- hay, avisa y cierra la lista.
function M.check_list()
	M.check_syntax(nil, function(diags)
		if not diags or #diags == 0 then
			notify("Sin errores de sintaxis (SAP) ✅")
			pcall(vim.cmd, "lclose")
			return
		end
		pcall(vim.diagnostic.setloclist, { namespace = CHECK_NS, open = true, title = "SAP syntax check" })
	end)
end

function M.diag()
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sap_obj
	local uri = M.object_uri(bufnr)
	notify(table.concat({
		"── sap-nvim diag ──",
		"filetype      : " .. vim.bo[bufnr].filetype,
		"vim.b.sap_obj : " .. (meta and ("name=" .. tostring(meta.name) .. " group=" .. tostring(meta.group)) or "NIL"),
		"URI ADT       : " .. (uri or "NIL"),
		"ADT disponible: " .. tostring(adt_http.is_available()),
	}, "\n"))
end

function M.daemon_test()
	local bufnr = vim.api.nvim_get_current_buf()
	local uri = M.object_uri(bufnr)
	if not uri then
		return
	end
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	adt_http.daemon_self_test({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = { uri = uri .. context_suffix(bufnr) .. "#start=" .. row .. "," .. col, signalCompleteness = "true" },
		content_type = "text/plain",
		body = src,
	}, function(body, info)
		notify("Daemon respondido en: " .. tostring(info))
	end)
end

function M.setup()
	pcall(vim.diagnostic.config, { update_in_insert = true }, CHECK_NS)
	local original_hover = vim.lsp.buf.hover
	vim.lsp.buf.hover = function()
		if is_sap_ft(vim.bo.filetype) then
			require("sap-nvim.core.intel").hover()
		else
			if original_hover then
				original_hover()
			end
		end
	end
	vim.api.nvim_create_user_command("SapDaemonTest", M.daemon_test, { desc = "sap-nvim: Probar daemon" })
	vim.api.nvim_create_user_command("SapDiag", M.diag, { desc = "sap-nvim: Diagnóstico" })
	vim.api.nvim_create_user_command(
		"SapSetMainProgram",
		M.change_include,
		{ desc = "sap-nvim: Fijar programa principal" }
	)
	vim.api.nvim_create_user_command("SapComplete", M.complete, { desc = "sap-nvim: Completado ADT" })
	vim.api.nvim_create_user_command("SapCheck", function()
		M.check_list() -- check de SAP + lista de errores navegable (estilo VSCode)
	end, { desc = "sap-nvim: Syntax check de SAP + lista de errores" })

	-- Check REAL de SAP al GUARDAR un objeto remoto (como VSCode/Eclipse): diagnósticos con
	-- contexto completo del sistema. Refresca la loclist si está abierta.
	local check_grp = vim.api.nvim_create_augroup("sap_nvim_sapcheck", { clear = true })
	vim.api.nvim_create_autocmd("BufWritePost", {
		group = check_grp,
		pattern = { "*.abap", "*.cls", "*.intf", "*.prog", "*.tabl", "*.stru", "*.dtel", "*.dome", "*.ddls", "*.ddl", "*.dcl", "*.bdef", "*.ddlx", "*.srvd" },
		callback = function(ev)
			if vim.b[ev.buf] and vim.b[ev.buf].sap_obj then
				M.check_syntax(ev.buf, function()
					-- si hay una loclist abierta, la mantenemos al día
					if vim.fn.getloclist(0, { winid = 0 }).winid ~= 0 then
						pcall(vim.diagnostic.setloclist, { namespace = CHECK_NS, open = false })
					end
				end)
			end
		end,
	})
	vim.api.nvim_create_user_command("SapHover", M.hover, { desc = "sap-nvim: Hover ADT" })
	vim.api.nvim_create_user_command("SapReferences", M.references, { desc = "sap-nvim: Referencias" })
	vim.api.nvim_create_user_command("SapGotoDef", function()
		M.goto_definition("definition")
	end, { desc = "sap-nvim: Ir a definición" })
	vim.api.nvim_create_user_command("SapGotoType", function()
		M.goto_definition("typeDefinition")
	end, { desc = "sap-nvim: Ir al tipo" })
	vim.api.nvim_create_user_command("SapGotoImpl", function()
		if not M.goto_definition("implementation") then
			vim.notify("Sin implementación.", vim.log.levels.WARN)
		end
	end, { desc = "sap-nvim: Ir a impl." })
	vim.api.nvim_create_user_command("SapTypeHierarchy", function()
		M.type_hierarchy(false)
	end, { desc = "sap-nvim: Subtipos" })
	vim.api.nvim_create_user_command("SapSuperTypes", function()
		M.type_hierarchy(true)
	end, { desc = "sap-nvim: Supertipos" })

	local g = vim.api.nvim_create_augroup("sap_nvim_intel_ft", { clear = true })
	vim.api.nvim_create_autocmd("LspAttach", {
		group = g,
		callback = function(ev)
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(ev.buf) and is_sap_ft(vim.bo[ev.buf].filetype) then
					pcall(vim.keymap.del, "n", "K", { buffer = ev.buf })
					vim.keymap.set("n", "K", "<cmd>SapHover<CR>", { buffer = ev.buf, desc = "SAP Hover" })
					vim.keymap.set("n", "gr", "<cmd>SapReferences<CR>", { buffer = ev.buf, desc = "SAP Referencias" })
					vim.keymap.set("n", "gd", "<cmd>SapGotoDef<CR>", { buffer = ev.buf, desc = "SAP Definición" })
				end
			end, 1000)
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "abap", "cds", "acds", "abapcds", "ddl", "ddls" },
		group = g,
		callback = function(ev)
			local b = ev.buf
			vim.bo[b].omnifunc = "v:lua.require'sap-nvim.core.intel'.omnifunc"
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(b) then
					pcall(vim.keymap.del, "n", "K", { buffer = b })
					vim.keymap.set("n", "K", "<cmd>SapHover<CR>", { buffer = b, desc = "SAP Hover" })
					vim.keymap.set("n", "gr", "<cmd>SapReferences<CR>", { buffer = b, desc = "SAP Referencias" })
					vim.keymap.set("n", "gd", "<cmd>SapGotoDef<CR>", { buffer = b, desc = "SAP Definición" })
				end
			end, 500)
			vim.api.nvim_create_autocmd("CursorHold", {
				buffer = b,
				callback = function()
					pcall(M.document_highlight)
				end,
			})
			vim.api.nvim_create_autocmd("CursorMoved", {
				buffer = b,
				callback = function()
					M.clear_highlight(b)
				end,
			})
			if vim.b[b].sap_obj then
				pcall(function()
					require("sap-nvim.core.adt_http").warmup()
				end)
				M.check_syntax(b)
			end
			-- AQUÍ ESTÁ LA MAGIA: Solo comprueba la sintaxis al guardar, no en cada tecla
			vim.api.nvim_create_autocmd("BufWritePost", {
				buffer = b,
				callback = function()
					if vim.b[b].sap_obj then
						M.check_syntax(b)
					end
				end,
			})
		end,
	})
end

return M
