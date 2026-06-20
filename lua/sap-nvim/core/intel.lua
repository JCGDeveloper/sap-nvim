-- sap-nvim.core.intel
-- "Inteligencia" tipo VSCode sobre el cliente ADT (core/adt_http)

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local objtype = require("sap-nvim.core.objtype")

-- ── UTILIDADES BÁSICAS ──────────────────────────────────────────────────────────

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function unxml(s)
	return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- Codificador URL exacto al encodeURIComponent de JavaScript (VSCode)
local function url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("[^%w_~%.%-]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Rango exacto de la palabra bajo el cursor (imprescindible para SAP ADT)
local function get_word_range(bufnr, row, col)
	local cstart, cend = col, col
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1]
	if line and #line > 0 then
		local cur = col + 1
		-- Patrón exacto de VSCode: incluye guiones (-) y virgulillas (~)
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

-- ── GESTIÓN DE URIs y CONTEXTO (INCLUDES) ───────────────────────────────────────

local ADT_URI = {
	class = "/sap/bc/adt/oo/classes/%s/source/main",
	interface = "/sap/bc/adt/oo/interfaces/%s/source/main",
	program = "/sap/bc/adt/programs/programs/%s/source/main",
	include = "/sap/bc/adt/programs/includes/%s/source/main",
	functiongroup = "/sap/bc/adt/functions/groups/%s/source/main",
	-- Soporte para Diccionario de Datos (Estilo VSCode)
	structure = "/sap/bc/adt/dictionary/structures/%s/source/main",
	table = "/sap/bc/adt/dictionary/tables/%s/source/main",
	dataelement = "/sap/bc/adt/dictionary/dataelements/%s/source/main",
	tabletype = "/sap/bc/adt/dictionary/tabletypes/%s/source/main",
	domain = "/sap/bc/adt/dictionary/domains/%s/source/main",
}

function M.object_uri(bufnr)
	local meta = vim.b[bufnr].sap_obj
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
	-- Estilo Marcello (VSCode): el uri va codificado, pero el ?context= no.
	return "?context=" .. url_encode(uri)
end

function M.change_include()
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sap_obj
	if not meta or meta.group ~= "include" then
		notify("El buffer actual no es un include.", vim.log.levels.WARN)
		return
	end
	local uris = M.main_programs(meta.name)
	if #uris == 0 then
		notify("El include no tiene programa principal asignado.", vim.log.levels.WARN)
		return
	end
	if #uris == 1 then
		mainprog_cache[meta.name:lower()] = uris[1]
		notify("Programa principal: " .. uris[1]:match("([^/]+)$"))
		return
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

-- ── COMPLETADO (AUTOCOMPLETE) ───────────────────────────────────────────────────

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
			if id and id ~= "" and id ~= "@end" then
				items[#items + 1] = { word = id, kind = kind }
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
	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = { uri = uri .. "%23start=" .. line .. "," .. col, signalCompleteness = "true" },
		content_type = "text/plain",
		body = src,
	})
	if not body or (not body:find("SCC_COMPLETION") and not body:find("codeCompletion")) then
		adt_http.reset_token()
		body = adt_http.request({
			method = "POST",
			path = "/sap/bc/adt/abapsource/codecompletion/proposal",
			query = { uri = uri .. "%23start=" .. line .. "," .. col, signalCompleteness = "true" },
			content_type = "text/plain",
			body = src,
		}) or ""
	end
	return M.parse(body)
end

function M.proposals_async(bufnr, line, col, cb)
	if not adt_http.is_available() then
		cb({})
		return
	end
	local uri = M.object_uri(bufnr)
	if not uri then
		cb({})
		return
	end
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local q = { uri = uri .. context_suffix(bufnr) .. "%23start=" .. line .. "," .. col, signalCompleteness = "true" }
	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/proposal",
		query = q,
		content_type = "text/plain",
		body = src,
	}, function(body)
		cb(M.parse(body))
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
		notify("ADT no disponible.", vim.log.levels.WARN)
		return
	end
	vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes("<C-x><C-o>", true, false, true), "n", false)
end

-- ── HIGHLIGHTS (Resaltado del símbolo actual) ───────────────────────────────────

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

-- ── GO-TO-DEFINITION / TYPE (Navegación Estilo VSCode) ──────────────────────────

local URI_PATTERNS = {
	{ "^/sap/bc/adt/oo/classes/([^/]+)", "class" },
	{ "^/sap/bc/adt/oo/interfaces/([^/]+)", "interface" },
	{ "^/sap/bc/adt/programs/includes/([^/]+)", "include" },
	{ "^/sap/bc/adt/programs/programs/([^/]+)", "program" },
	{ "^/sap/bc/adt/functions/groups/([^/]+)", "functiongroup" },
	-- Patrones modernos del Diccionario
	{ "^/sap/bc/adt/dictionary/structures/([^/]+)", "structure" },
	{ "^/sap/bc/adt/dictionary/tables/([^/]+)", "table" },
	{ "^/sap/bc/adt/dictionary/dataelements/([^/]+)", "dataelement" },
	{ "^/sap/bc/adt/dictionary/tabletypes/([^/]+)", "tabletype" },
	{ "^/sap/bc/adt/dictionary/domains/([^/]+)", "domain" },
	-- Patrones antiguos del Diccionario
	{ "^/sap/bc/adt/ddic/structures/([^/]+)", "structure" },
	{ "^/sap/bc/adt/ddic/tables/([^/]+)", "table" },
	{ "^/sap/bc/adt/ddic/dataelements/([^/]+)", "dataelement" },
	{ "^/sap/bc/adt/ddic/domains/([^/]+)", "domain" },
}

local function uri_to_object(uri)
	local path, frag = uri:match("^([^#]+)#?(.*)$")
	path = path or uri
	local line, col = (frag or ""):match("start=(%d+),(%d+)")
	for _, p in ipairs(URI_PATTERNS) do
		local name = path:match(p[1])
		if name then
			-- Añadimos raw_path para guardar la URL exacta de la tabla/estructura
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
			uri = uri .. ctx .. "%23start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend,
			filter = filter or "definition",
		},
		body = src,
	})
	if not body then
		return nil
	end
	local target = body:match('adtcore:uri="([^"]*)"')
	return target and uri_to_object(unxml(target)) or nil
end

function M.goto_definition(filter)
	if filter == true then
		filter = "typeDefinition"
	elseif not filter then
		filter = "definition"
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local row, col = unpack(vim.api.nvim_win_get_cursor(0))

	-- Intento 1: Buscar como definición normal
	local obj = M.definition_target(bufnr, row, col, filter)

	-- Intento 2 (Magia VSCode): Si no es una variable, a lo mejor es un Tipo del Diccionario (como ddshretval)
	if not obj and filter == "definition" then
		obj = M.definition_target(bufnr, row, col, "typeDefinition")
	end

	-- Fallback local: Si SAP no sabe qué es, te lleva a la línea de tu archivo donde lo creaste
	if not obj then
		vim.notify("SAP: Sin def. Buscando local...", vim.log.levels.INFO)
		pcall(vim.cmd, "normal! gD")
		return true
	end

	local meta = vim.b[bufnr].sap_obj
	if meta and meta.name:upper() == obj.name and obj.line then
		pcall(vim.api.nvim_win_set_cursor, 0, { obj.line, obj.col or 0 })
		vim.cmd("normal! zz")
	else
		require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
	end
	return true
end

-- ── HOVER SOURCE PREVIEW (Previsualizar código) ─────────────────────────────────

-- Traductor de tipos técnicos de SAP a lenguaje humano
local ADT_KIND_MAP = {
	["CLAS/I"] = "Importing",
	["INTF/I"] = "Importing",
	["CLAS/E"] = "Exporting",
	["INTF/E"] = "Exporting",
	["CLAS/C"] = "Changing",
	["INTF/C"] = "Changing",
	["CLAS/R"] = "Returning",
	["INTF/R"] = "Returning",
	["PROG/P"] = "Parameter",
	["PROG/S"] = "Select-Option",
}

local hover_win = nil

function M.hover()
	-- Anulamos LSP por defecto para que no estorbe
	vim.lsp.handlers["textDocument/hover"] = function() end

	if hover_win and vim.api.nvim_win_is_valid(hover_win) then
		vim.api.nvim_set_current_win(hover_win)
		return
	end

	local adt_http = require("sap-nvim.core.adt_http")
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
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	-- 1. Intentamos obtener la Documentación Oficial de SAP (ElementInfo)
	local req_params = {
		method = "POST",
		path = "/sap/bc/adt/abapsource/elementinfo",
		query = { uri = uri .. ctx .. "%23start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend },
		content_type = "text/plain",
		accept = "application/xml",
		body = src,
	}

	local body = adt_http.request(req_params)

	-- Refresco de Token si ha caducado
	if not body or not body:find("elementInfo") then
		adt_http.reset_token()
		body = adt_http.request(req_params)
	end

	local preview = {}

	-- Parseamos ElementInfo (Plan A: Funciones, Clases, Tablas estándar)
	if body and body:find("elementInfo") then
		local is_first = true
		local function unxml_local(s)
			return (s or "")
				:gsub("&lt;", "<")
				:gsub("&gt;", ">")
				:gsub("&quot;", '"')
				:gsub("&apos;", "'")
				:gsub("&amp;", "&")
		end

		for attrs in body:gmatch("<[%w_:]*elementInfo%s([^>]+)") do
			local name = attrs:match('adtcore:name="([^"]*)"')
			local desc = attrs:match('adtcore:description="([^"]*)"')
			local typ = attrs:match('adtcore:type="([^"]*)"')

			if name then
				name = unxml_local(name)
				desc = unxml_local(desc)
				typ = unxml_local(typ)

				if is_first then
					table.insert(preview, "### " .. name)
					if desc and desc ~= "" and desc ~= name then
						table.insert(preview, "*" .. desc .. "*")
					end
					table.insert(preview, "---")
					is_first = false
				else
					local item_text = "- **" .. name .. "**"
					if typ and ADT_KIND_MAP[typ] then
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

	-- 2. FALLBACK PLAN B: Clon visual de VSCode (Ahora con soporte para Tablas/DDIC)
	if #preview == 0 then
		local word = vim.fn.expand("<cword>")
		local target = M.definition_target(bufnr, row, col, "definition")
		local code_line = ""
		local def_name = ""
		local def_line = 0

		-- Función mágica: Lee hacia abajo buscando el punto (.) o llaves { } para el Diccionario
		local function extract_statement(lines_table, start_idx)
			local stmt = {}
			local in_braces = false
			-- Leemos hasta 50 líneas para asegurar que pillemos estructuras y tablas enteras
			for i = start_idx, math.min(start_idx + 50, #lines_table) do
				local l = lines_table[i] or ""
				table.insert(stmt, l)
				-- Limpiamos strings y comentarios para que no engañen al buscador
				local clean = l:gsub("'.-'", ""):gsub('".*', ""):gsub("^%*.*", "")

				if clean:match("{") then
					in_braces = true
				end
				if in_braces and clean:match("}") then
					break
				end
				if not in_braces and clean:match("%.") then
					break
				end
			end

			-- Alineamos el bloque a la izquierda
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
			-- CORRECCIÓN: Si es una tabla, SAP no da línea. Asumimos la línea 1.
			def_line = target.line or 1
			local current_meta = vim.b[bufnr].sap_obj

			-- Si está en el mismo archivo
			if current_meta and current_meta.name:upper() == target.name then
				local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
				code_line = extract_statement(lines, def_line)
			else
				-- Si está en otro archivo, usamos la ruta EXACTA que nos dio SAP
				if target.raw_path then
					local source_uri = target.raw_path
					-- CORRECCIÓN: Evitamos duplicar el /source/main si SAP ya nos lo ha dado
					if not source_uri:match("/source/main$") then
						source_uri = source_uri .. "/source/main"
					end

					local src_body = adt_http.request({ method = "GET", path = source_uri, accept = "text/plain" })
					if src_body then
						local lines = vim.split(src_body:gsub("\r", ""), "\n")
						code_line = extract_statement(lines, def_line)
					end
				end
			end
		else
			-- Búsqueda local por si es algo no guardado en SAP
			local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
			for i, l in ipairs(lines) do
				if
					l:lower():match("data:%s*" .. word:lower())
					or l:lower():match("types:%s*" .. word:lower())
					or l:lower():match("constants:%s*" .. word:lower())
				then
					def_line = i
					def_name = (vim.b[bufnr].sap_obj and vim.b[bufnr].sap_obj.name) or "Local File"
					code_line = extract_statement(lines, i)
					break
				end
			end
		end

		-- Renderizamos el clon exacto de VSCode
		if code_line ~= "" then
			table.insert(preview, "📦 **Definición:** `" .. word .. "`")
			table.insert(preview, "")
			table.insert(preview, "```abap\n" .. code_line .. "\n```")
			table.insert(preview, "")
			table.insert(preview, "*Defined in " .. def_name .. " (Line " .. def_line .. ")*")
		end
	end

	if #preview == 0 then
		vim.notify("SAP no devolvió información ni código.", vim.log.levels.WARN)
		return
	end

	-- Abrimos siempre en Markdown para que se vea bonito
	local float_buf, float_win = vim.lsp.util.open_floating_preview(preview, "markdown", {
		border = "rounded",
		focusable = true,
		max_width = 85,
		max_height = 25,
	})
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

-- ── REFERENCES (usageReferences): usos del símbolo con línea exacta y snippet ──
local USAGE_REQ = '<?xml version="1.0" encoding="UTF-8"?><usagereferences:usageReferenceRequest '
	.. 'xmlns:usagereferences="http://www.sap.com/adt/ris/usageReferences">'
	.. "<usagereferences:affectedObjects/></usagereferences:usageReferenceRequest>"

-- Función auxiliar para imitar a VSCode cuando SAP no tiene la variable (variables locales)
local function local_references_fallback()
	local word = vim.fn.expand("<cword>")
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local qf_list = {}

	for i, line in ipairs(lines) do
		-- Busca la palabra aislada
		if line:match("%f[%w_]" .. word .. "%f[^%w_]") then
			local col = line:find(word, 1, true)
			table.insert(qf_list, {
				bufnr = bufnr,
				lnum = i,
				col = col,
				text = vim.trim(line),
			})
		end
	end

	if #qf_list > 0 then
		vim.notify("Mostrando referencias locales (VSCode fallback)", vim.log.levels.INFO)
		vim.fn.setqflist(qf_list, "r")
		vim.cmd("copen") -- Abre el panel inferior estilo VSCode
	else
		vim.notify("Sin referencias globales ni locales.", vim.log.levels.WARN)
	end
end

function M.references()
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

	notify("Buscando referencias en SAP...")

	local body = adt_http.request({
		method = "POST",
		path = "/sap/bc/adt/repository/informationsystem/usageReferences",
		query = { uri = uri .. ctx .. "%23start=" .. row .. "," .. cstart .. ";end=" .. row .. "," .. cend },
		content_type = "application/vnd.sap.adt.repository.usagereferences.request.v1+xml",
		body = USAGE_REQ,
	})

	if not body or not body:find("usageReference") then
		-- En vez de rendirnos, actuamos como VSCode: buscamos en el texto local
		local_references_fallback()
		return
	end

	local refs = {}
	for obj_block in body:gmatch("<usageReferences:adtObject(.-)</usageReferences:adtObject>") do
		local obj_name = obj_block:match('adtcore:name="([^"]*)"')
		local obj_typ = obj_block:match('adtcore:type="([^"]*)"')

		for ref_block in obj_block:gmatch("<usageReferences:usageReference(.-)</usageReferences:usageReference>") do
			local ref_uri = ref_block:match('adtcore:uri="([^"]*)"')
			local snippet = ref_block:match("<usageReferences:snippet>([^<]*)</usageReferences:snippet>")

			if ref_uri then
				refs[#refs + 1] = {
					name = obj_name,
					typ = obj_typ or "",
					uri = unxml(ref_uri),
					snippet = unxml(snippet or ""),
				}
			end
		end
	end

	if #refs == 0 then
		local_references_fallback()
		return
	end

	vim.ui.select(refs, {
		prompt = "Referencias SAP (" .. #refs .. "):",
		format_item = function(r)
			local lnum = r.uri:match("start=(%d+)") or "?"
			return string.format("%-15s [Línea %-4s] %s", r.name, lnum, vim.trim(r.snippet))
		end,
	}, function(choice)
		if not choice then
			return
		end
		local obj = uri_to_object(choice.uri)
		if obj and obj.group then
			require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
		end
	end)
end

-- ── TYPE HIERARCHY (Super/Subtipos) ─────────────────────────────────────────────

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
			uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col,
			type = super and "superTypes" or "subTypes",
		},
		content_type = "text/plain",
		accept = "application/*",
		body = src,
	})

	if not body then
		notify("Sin jerarquía de tipos aquí.")
		return
	end
	if body:find("invalidMainProgram") then
		notify("Abre el programa principal (no el include) para ver la jerarquía.", vim.log.levels.WARN)
		return
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
		notify("Sin resultados.")
		return
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
			require("sap-nvim.core.source").open(obj.name, obj.group, { line = obj.line, col = obj.col })
		end
	end)
end

-- ── SYNTAX CHECK EN VIVO ────────────────────────────────────────────────────────

local CHECK_NS = vim.api.nvim_create_namespace("sap_nvim_adt_check")

local function b64(s)
	if vim.base64 and vim.base64.encode then
		return vim.base64.encode(s)
	end
	return vim.fn.system({ "base64", "-w0" }, s):gsub("%s+$", "")
end

function M.check_syntax(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	if not adt_http.is_available() or not vim.api.nvim_buf_is_valid(bufnr) then
		return
	end
	local source_uri = M.object_uri(bufnr)
	if not source_uri then
		return
	end
	local obj_uri = source_uri:gsub("/source/main$", "")
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	local xml = '<?xml version="1.0" encoding="UTF-8"?><chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" xmlns:adtcore="http://www.sap.com/adt/core">'
		.. '<chkrun:checkObject adtcore:uri="'
		.. obj_uri
		.. context_suffix(bufnr)
		.. '" chkrun:version="inactive">'
		.. '<chkrun:artifacts><chkrun:artifact chkrun:contentType="text/plain; charset=utf-8" chkrun:uri="'
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
			if line and uri and uri:find(obj_uri, 1, true) then
				local sev = vim.diagnostic.severity.INFO
				if typ == "E" then
					sev = vim.diagnostic.severity.ERROR
				elseif typ == "W" then
					sev = vim.diagnostic.severity.WARN
				end
				diags[#diags + 1] = {
					lnum = math.max(0, tonumber(line) - 1),
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
		end)
	end)
end

local check_timers = {}
local function schedule_check(bufnr)
	local t = check_timers[bufnr]
	if t then
		t:stop()
		pcall(t.close, t)
	end
	local nt = vim.loop.new_timer()
	check_timers[bufnr] = nt
	nt:start(
		900,
		0,
		vim.schedule_wrap(function()
			check_timers[bufnr] = nil
			M.check_syntax(bufnr)
		end)
	)
end

-- ── DIAGNÓSTICOS Y TESTEO ───────────────────────────────────────────────────────

function M.diag()
	local bufnr = vim.api.nvim_get_current_buf()
	local meta = vim.b[bufnr].sap_obj
	local uri = M.object_uri(bufnr)
	local out = {
		"── sap-nvim diag ──",
		"filetype      : " .. vim.bo[bufnr].filetype,
		"vim.b.sap_obj : " .. (meta and ("name=" .. tostring(meta.name) .. " group=" .. tostring(meta.group)) or "NIL"),
		"URI ADT       : " .. (uri or "NIL"),
		"ADT disponible: " .. tostring(adt_http.is_available()),
	}
	notify(table.concat(out, "\n"))
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
		query = { uri = uri .. context_suffix(bufnr) .. "%23start=" .. row .. "," .. col, signalCompleteness = "true" },
		content_type = "text/plain",
		body = src,
	}, function(body, info)
		notify("Daemon respondido en: " .. tostring(info))
	end)
end

-- ── SETUP Y AUTOCOMANDOS ────────────────────────────────────────────────────────

function M.setup()
	pcall(vim.diagnostic.config, { update_in_insert = true }, CHECK_NS)

	-- 🔥 LA OPCIÓN NUCLEAR ANTI-LAZYVIM 🔥
	-- Secuestramos la función base del LSP de Neovim.
	-- Si LazyVim llama al hover nativo, nosotros decidimos qué hacer.
	local original_hover = vim.lsp.buf.hover
	vim.lsp.buf.hover = function()
		if vim.bo.filetype == "abap" then
			require("sap-nvim.core.intel").hover()
		else
			if original_hover then
				original_hover()
			end
		end
	end

	-- Comandos de usuario
	vim.api.nvim_create_user_command("SapDaemonTest", function()
		M.daemon_test()
	end, { desc = "sap-nvim: Probar daemon" })
	vim.api.nvim_create_user_command("SapDiag", function()
		M.diag()
	end, { desc = "sap-nvim: Diagnóstico" })
	vim.api.nvim_create_user_command("SapSetMainProgram", function()
		M.change_include()
	end, { desc = "sap-nvim: Fijar programa principal" })
	vim.api.nvim_create_user_command("SapComplete", function()
		M.complete()
	end, { desc = "sap-nvim: Completado ADT" })
	vim.api.nvim_create_user_command("SapCheck", function()
		M.check_syntax()
	end, { desc = "sap-nvim: Syntax check" })
	vim.api.nvim_create_user_command("SapHover", function()
		M.hover()
	end, { desc = "sap-nvim: Hover ADT" })
	vim.api.nvim_create_user_command("SapReferences", function()
		M.references()
	end, { desc = "sap-nvim: Referencias" })
	vim.api.nvim_create_user_command("SapGotoType", function()
		M.goto_definition("typeDefinition")
	end, { desc = "sap-nvim: Ir al tipo" })
	vim.api.nvim_create_user_command("SapGotoImpl", function()
		if not M.goto_definition("implementation") then
			vim.notify("Sin implementación.", vim.log.levels.WARN)
		end
	end, { desc = "sap-nvim: Ir a implementación" })
	vim.api.nvim_create_user_command("SapTypeHierarchy", function()
		M.type_hierarchy(false)
	end, { desc = "sap-nvim: Subtipos" })
	vim.api.nvim_create_user_command("SapSuperTypes", function()
		M.type_hierarchy(true)
	end, { desc = "sap-nvim: Supertipos" })

	-- Resto de atajos (gd, gr, etc.) que no suelen dar tanta guerra como la K
	local function enforce_maps(b)
		vim.schedule(function()
			if vim.api.nvim_buf_is_valid(b) and vim.bo[b].filetype == "abap" then
				vim.keymap.set("n", "gr", function()
					require("sap-nvim.core.intel").references()
				end, { buffer = b, desc = "ABAP: Referencias ADT" })
				vim.keymap.set("n", "gd", function()
					require("sap-nvim.core.intel").goto_definition("definition")
				end, { buffer = b, desc = "ABAP: Ir a Definición" })
				vim.keymap.set("n", "gy", function()
					require("sap-nvim.core.intel").goto_definition("typeDefinition")
				end, { buffer = b, desc = "ABAP: Ir al tipo" })
				vim.keymap.set("n", "gI", function()
					require("sap-nvim.core.intel").goto_definition("implementation")
				end, { buffer = b, desc = "ABAP: Ir a impl" })
			end
		end)
	end

	local g = vim.api.nvim_create_augroup("sap_nvim_intel_ft", { clear = true })

	-- EL MARTILLO ANTI-LAZYVIM: Esperamos 1 segundo entero a que LazyVim/Noice
	-- terminen de cargar sus cosas del LSP, y les pisamos la tecla con comandos crudos.
	vim.api.nvim_create_autocmd("LspAttach", {
		group = g,
		callback = function(ev)
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(ev.buf) and vim.bo[ev.buf].filetype == "abap" then
					pcall(vim.keymap.del, "n", "K", { buffer = ev.buf })
					-- Usamos <cmd> en vez de función Lua para que Noice no lo intercepte
					vim.keymap.set("n", "K", "<cmd>SapHover<CR>", { buffer = ev.buf, desc = "SAP Hover" })
					vim.keymap.set("n", "gr", "<cmd>SapReferences<CR>", { buffer = ev.buf, desc = "SAP Referencias" })
					vim.keymap.set("n", "gd", "<cmd>SapGotoDef<CR>", { buffer = ev.buf, desc = "SAP Definición" })
				end
			end, 1000) -- 1000ms de retraso estratégico
		end,
	})

	vim.api.nvim_create_autocmd("FileType", {
		pattern = "abap",
		group = g,
		callback = function(ev)
			local b = ev.buf
			vim.bo[b].omnifunc = "v:lua.require'sap-nvim.core.intel'.omnifunc"

			-- Aplicamos también al abrir el archivo, por si no hay LSP
			vim.defer_fn(function()
				if vim.api.nvim_buf_is_valid(b) then
					pcall(vim.keymap.del, "n", "K", { buffer = b })
					vim.keymap.set("n", "K", "<cmd>SapHover<CR>", { buffer = b, desc = "SAP Hover" })
					vim.keymap.set("n", "gr", "<cmd>SapReferences<CR>", { buffer = b, desc = "SAP Referencias" })
					vim.keymap.set("n", "gd", "<cmd>SapGotoDef<CR>", { buffer = b, desc = "SAP Definición" })
				end
			end, 500)

			-- Resto de la inicialización de sintaxis
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

			vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
				buffer = b,
				callback = function()
					if vim.b[b].sap_obj then
						schedule_check(b)
					end
				end,
			})
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
