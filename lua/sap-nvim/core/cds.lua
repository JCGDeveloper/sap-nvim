-- lua/sap-nvim/core/cds.lua
local M = {}
local adt = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[sap-nvim CDS] " .. msg, level or vim.log.levels.INFO)
	end)
end

local function unxml(s)
	return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function is_exception(body)
	return body ~= nil and (body:find("<exc:exception", 1, true) or body:find("ExceptionResource", 1, true)) ~= nil
end

local function exc_message(body)
	if not body then
		return nil
	end
	local m = body:match("<message[^>]*>([^<]*)</message>")
	return m and unxml(m) or nil
end

local function scratch(lines, opts)
	opts = opts or {}
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	if opts.filetype then
		vim.bo[buf].filetype = opts.filetype
	end
	pcall(vim.api.nvim_buf_set_name, buf, opts.name or ("cds://" .. tostring(buf)))
	vim.bo[buf].modifiable = false
	vim.bo[buf].readonly = true
	vim.cmd(opts.vertical and "botright vsplit" or "botright split")
	vim.api.nvim_win_set_buf(0, buf)
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, nowait = true })
	vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = buf, nowait = true })
	return buf
end

function M.current_entity(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	-- Saneamiento CRLF total
	local function clean(s)
		return (s:upper():gsub("\r", ""):gsub("%s+", ""))
	end
	local meta = vim.b[bufnr].sap_obj
	if meta and meta.name and meta.name ~= "" then
		return clean(meta.name)
	end
	for _, l in ipairs(vim.api.nvim_buf_get_lines(bufnr, 0, 300, false)) do
		local n = l:match("[Dd]efine%s+root%s+view%s+entity%s+([%w_/]+)")
			or l:match("[Dd]efine%s+view%s+entity%s+([%w_/]+)")
			or l:match("[Dd]efine%s+abstract%s+entity%s+([%w_/]+)")
			or l:match("[Dd]efine%s+view%s+([%w_/]+)")
			or l:match("[Dd]efine%s+transient%s+view%s+entity%s+([%w_/]+)")
		if n then
			return clean(n)
		end
	end
	return nil
end

local function parse_parameters(bufnr)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local block = src:match("[Ww]ith%s+[Pp]arameters(.-)%f[%a][Aa]s%s+[Ss]elect")
		or src:match("[Ww]ith%s+[Pp]arameters(.-)[\n]%s*{")
	if not block then
		return {}
	end
	local params = {}
	for name in block:gmatch("([%w_]+)%s*:") do
		params[#params + 1] = name:upper()
	end
	return params
end

local function preview_request(bufnr, opts, cb)
	if not adt.is_available() then
		notify("Sin conexión SAP (config.yml).", vim.log.levels.WARN)
		return
	end
	local entity = opts.entity or M.current_entity(bufnr)
	if not entity then
		notify("No se detectó entidad CDS. Abre un .ddls o pasa el nombre.", vim.log.levels.WARN)
		return
	end
	local params = opts.params or parse_parameters(bufnr)
	local rows = opts.rows or 100

	local function fire(values)
		local body = ""
		if #params > 0 then
			local parts = {}
			for _, p in ipairs(params) do
				parts[#parts + 1] = p .. " = " .. (values[p] or "''")
			end
			body = "SELECT * FROM " .. entity .. "( " .. table.concat(parts, ", ") .. " )"
		end
		adt.request_async({
			method = "POST",
			path = "/sap/bc/adt/datapreview/ddic",
			query = { rowNumber = rows, ddicEntityName = entity },
			content_type = "text/plain",
			accept = "application/*",
			body = body,
		}, function(resp)
			vim.schedule(function()
				cb(resp, entity)
			end)
		end)
	end

	if #params > 0 then
		notify("La vista tiene parámetros: " .. table.concat(params, ", "))
		local values, i = {}, 0
		local function ask()
			i = i + 1
			if i > #params then
				fire(values)
				return
			end
			local p = params[i]
			vim.ui.input({ prompt = "Parámetro " .. p .. " = " }, function(v)
				if v == nil then
					notify("Preview cancelada.")
					return
				end
				values[p] = (v:match("^%-?%d+%.?%d*$") and v ~= "") and v or ("'" .. v:gsub("'", "''") .. "'")
				ask()
			end)
		end
		ask()
	else
		notify("Consultando " .. entity .. "...")
		fire({})
	end
end

local function column_values(ds)
	local vals, pos = {}, 1
	while true do
		local s = ds:find("<dataPreview:data", pos, true)
		if not s then
			break
		end
		local close = ds:find(">", s, true)
		if not close then
			break
		end
		if ds:sub(close - 1, close - 1) == "/" then
			vals[#vals + 1] = ""
			pos = close + 1
		else
			local e = ds:find("</dataPreview:data>", close, true)
			if not e then
				break
			end
			vals[#vals + 1] = unxml(ds:sub(close + 1, e - 1))
			pos = e + 1
		end
	end
	return vals
end

function M.parse_tabledata(body)
	local cols, data = {}, {}
	for block in body:gmatch("<dataPreview:columns>(.-)</dataPreview:columns>") do
		local name = block:match('dataPreview:name="([^"]*)"') or "?"
		local ds = block:match("<dataPreview:dataSet>(.-)</dataPreview:dataSet>") or ""
		cols[#cols + 1] = name
		data[#data + 1] = column_values(ds)
	end
	local nrows = 0
	for _, c in ipairs(data) do
		if #c > nrows then
			nrows = #c
		end
	end
	return cols, data, nrows
end

local function format_table(cols, data, nrows)
	local MAXW = 60
	local w = {}
	for i, name in ipairs(cols) do
		w[i] = #name
		for r = 1, nrows do
			local v = data[i][r] or ""
			if #v > w[i] then
				w[i] = #v
			end
		end
		if w[i] > MAXW then
			w[i] = MAXW
		end
	end
	local function pad(s, n)
		s = tostring(s or "")
		if #s > n then
			return s:sub(1, n)
		end
		return s .. string.rep(" ", n - #s)
	end
	local head, sep = {}, {}
	for i, name in ipairs(cols) do
		head[i] = pad(name, w[i])
		sep[i] = string.rep("-", w[i])
	end
	local out = { table.concat(head, " | "), table.concat(sep, "-+-") }
	for r = 1, nrows do
		local cells = {}
		for i = 1, #cols do
			cells[i] = pad(data[i][r] or "", w[i])
		end
		out[#out + 1] = table.concat(cells, " | ")
	end
	return out
end

function M.data_preview(opts)
	preview_request(vim.api.nvim_get_current_buf(), opts or {}, function(resp, entity)
		if not resp or resp == "" then
			notify("Respuesta vacía del servidor.", vim.log.levels.ERROR)
			return
		end
		if is_exception(resp) then
			notify("Error: " .. (exc_message(resp) or "preview rechazada"), vim.log.levels.ERROR)
			return
		end
		local cols, data, nrows = M.parse_tabledata(resp)
		if #cols == 0 then
			notify("La respuesta no contenía columnas.", vim.log.levels.WARN)
			return
		end
		local total = resp:match("<dataPreview:totalRows>(%d+)</dataPreview:totalRows>")
		local exec = resp:match("<dataPreview:queryExecutionTime>([%d%.]+)</dataPreview:queryExecutionTime>")
		local header = {
			string.format(
				"-- %s  ·  %s filas totales  ·  mostrando %d  ·  %s ms  ·  [q=cerrar, / busca]",
				entity,
				total or "?",
				nrows,
				exec and exec:match("^%d+%.%d?%d?") or "?"
			),
			"",
		}
		vim.list_extend(header, format_table(cols, data, nrows))
		scratch(header, { name = "cds-preview://" .. entity })
	end)
end

local function format_sql(sql, entity)
	local s = sql:gsub("%s+", " "):gsub("^%s+", "")
	local breaks = {
		"FROM",
		"INNER JOIN",
		"LEFT OUTER JOIN",
		"LEFT JOIN",
		"RIGHT OUTER JOIN",
		"RIGHT JOIN",
		"CROSS JOIN",
		"OUTER JOIN",
		"JOIN",
		"WHERE",
		"GROUP BY",
		"HAVING",
		"ORDER BY",
		"UNION ALL",
		"UNION",
		"INTO",
		"UP TO",
	}
	for _, k in ipairs(breaks) do
		local pat = "%s" .. k:gsub(" ", "%%s+") .. "%s"
		s = s:gsub(pat, "\n" .. k .. " ")
	end
	s = s:gsub("%sON%s", "\n    ON ")
	local out = {
		"-- SQL que ADT ejecuta para " .. entity .. "  (statement real, q=cerrar)",
		"-- Nota: es el OpenSQL push-down de ADT, no el plan HANA crudo.",
		"",
	}
	vim.list_extend(out, vim.split(s, "\n", { plain = true }))
	return out
end

function M.show_sql(opts)
	opts = opts or {}
	opts.rows = opts.rows or 1
	preview_request(vim.api.nvim_get_current_buf(), opts, function(resp, entity)
		if is_exception(resp) then
			notify("Error: " .. (exc_message(resp) or "sql"), vim.log.levels.ERROR)
			return
		end
		local sql = resp and resp:match("<dataPreview:executedQueryString>(.-)</dataPreview:executedQueryString>")
		if not sql or sql == "" then
			notify("La respuesta no incluyó el SQL ejecutado.", vim.log.levels.WARN)
			return
		end
		scratch(format_sql(unxml(sql), entity), { name = "cds-sql://" .. entity, filetype = "sql", vertical = true })
	end)
end

local function odata_template(base, client, service, entity, user)
	local svcroot = "{{base}}/sap/opu/odata/sap/{{service}}"
	return {
		"### Entorno OData generado de @OData.publish para " .. entity,
		"# Servicio asumido: " .. service .. "   (ajústalo si el nombre real difiere)",
		"@base = " .. base,
		"@service = " .. service,
		"@client = " .. client,
		"@user = " .. (user or "TU_USUARIO"),
		"@password = TU_PASSWORD",
		"",
		"### 1. Service document",
		"GET " .. svcroot .. "/?sap-client={{client}}",
		"Authorization: Basic {{user}} {{password}}",
		"Accept: application/json",
		"",
		"### 2. $metadata",
		"GET " .. svcroot .. "/$metadata?sap-client={{client}}",
		"Authorization: Basic {{user}} {{password}}",
		"",
		"### 3. Leer " .. entity .. " (top 10)",
		"GET " .. svcroot .. "/" .. entity .. "?$top=10&$format=json&sap-client={{client}}",
		"Authorization: Basic {{user}} {{password}}",
		"Accept: application/json",
	}
end

function M.odata_http(opts)
	opts = opts or {}
	local bufnr = vim.api.nvim_get_current_buf()
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	if not src:lower():find("@odata%.publish%s*:%s*true") then
		notify("No hay '@OData.publish: true' en el buffer.", vim.log.levels.WARN)
		return
	end
	local entity = M.current_entity(bufnr)
	if not entity then
		notify("No se detectó la entidad CDS.", vim.log.levels.WARN)
		return
	end
	local c = adt.creds()
	if not c then
		notify("Sin credenciales SAP (config.yml).", vim.log.levels.WARN)
		return
	end
	local service = (opts.service or (entity .. "_CDS")):upper()
	local lines = odata_template(c.base, c.client, service, entity, c.user)

	local buf = vim.api.nvim_create_buf(true, false)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].filetype = "http"
	vim.bo[buf].bufhidden = "hide"
	vim.bo[buf].swapfile = false
	pcall(vim.api.nvim_buf_set_name, buf, "odata-" .. entity:lower() .. ".http")
	vim.cmd("botright vsplit")
	vim.api.nvim_win_set_buf(0, buf)
	notify("Plantilla OData generada.")
end

local CURATED = {
	"AbapCatalog.sqlViewName",
	"AbapCatalog.sqlViewAppendName",
	"AbapCatalog.compiler.compareFilter",
	"AbapCatalog.preserveKey",
	"AccessControl.authorizationCheck",
	"ClientHandling.type",
	"ClientHandling.algorithm",
	"ClientDependent",
	"EndUserText.label",
	"EndUserText.quickInfo",
	"Metadata.allowExtensions",
	"Metadata.ignorePropagatedAnnotations",
	"ObjectModel.usageType.serviceQuality",
	"ObjectModel.usageType.sizeCategory",
	"ObjectModel.usageType.dataClass",
	"ObjectModel.semanticKey",
	"ObjectModel.representativeKey",
	"ObjectModel.dataCategory",
	"Semantics.amount.currencyCode",
	"Semantics.quantity.unitOfMeasure",
	"Semantics.currencyCode",
	"Semantics.unitOfMeasure",
	"Semantics.user.createdBy",
	"UI.headerInfo.typeName",
	"UI.headerInfo.typeNamePlural",
	"UI.lineItem",
	"UI.identification",
	"UI.selectionField",
	"UI.facet",
	"Consumption.valueHelpDefinition",
	"Consumption.filter",
	"Consumption.semanticObject",
	"Search.searchable",
	"OData.publish",
}
local annotation_cache

local function parse_annotations(body)
	local set, list = {}, {}
	local function add(name)
		if name and name:find("%.") and not set[name] then
			set[name] = true
			list[#list + 1] = name
		end
	end
	for n in body:gmatch('name="([%w%._]+)"') do
		add(n)
	end
	for n in body:gmatch('value="@([%w%._]+)"') do
		add(n)
	end
	return list
end

function M.annotation_proposals(prefix, cb)
	prefix = (prefix or ""):lower()
	local function deliver(catalog)
		local items = {}
		for _, a in ipairs(catalog) do
			if prefix == "" or a:lower():sub(1, #prefix) == prefix then
				items[#items + 1] = { word = a, kind = "annotation" }
			end
		end
		cb(items)
	end

	if annotation_cache then
		deliver(annotation_cache)
		return
	end
	deliver(CURATED)
	adt.request_async({
		method = "GET",
		path = "/sap/bc/adt/ddic/cds/annotation/definitions",
		accept = "application/vnd.sap.adt.cds.annotation.definitions.v1+xml, application/vnd.sap.adt.cds.annotation.definitions.v2+xml",
	}, function(body)
		local merged, seen = {}, {}
		for _, a in ipairs(CURATED) do
			if not seen[a] then
				seen[a] = true
				merged[#merged + 1] = a
			end
		end
		for _, a in ipairs(parse_annotations(body or "")) do
			if not seen[a] then
				seen[a] = true
				merged[#merged + 1] = a
			end
		end
		table.sort(merged)
		annotation_cache = merged
	end)
end

-- ── Completado de campos / fuentes CDS (como VSCode) ──────────────────────────
-- El endpoint /abapsource/codecompletion NO sirve para DDL (lanza ParameterValueInvalid).
-- VSCode resuelve el alias del FROM/JOIN y pide campos/fuentes a `ddicrepositoryaccess`.

-- Mapa alias->fuente leyendo los from/join del fuente CDS.
local function cds_alias_map(src)
	local map = {}
	for tbl, alias in src:gmatch("[Ff][Rr][Oo][Mm]%s+([%w_/]+)%s+[Aa][Ss]%s+([%w_/]+)") do
		map[alias:lower()] = tbl
	end
	for tbl, alias in src:gmatch("[Jj][Oo][Ii][Nn]%s+([%w_/]+)%s+[Aa][Ss]%s+([%w_/]+)") do
		map[alias:lower()] = tbl
	end
	-- from/join sin alias: la fuente es su propio "alias".
	for tbl in src:gmatch("[Ff][Rr][Oo][Mm]%s+([%w_/]+)") do map[tbl:lower()] = map[tbl:lower()] or tbl end
	for tbl in src:gmatch("[Jj][Oo][Ii][Nn]%s+([%w_/]+)") do map[tbl:lower()] = map[tbl:lower()] or tbl end
	return map
end

-- Query del endpoint ddicrepositoryaccess. OJO (igual que abap-adt-api/vscode):
--   CAMPOS de una fuente -> { requestScope = "all", path = "TABLA." }   (NO datasource=)
--   FUENTES por prefijo  -> { datasource = "PREFIJO*" }
local function ddic_fields_query(tbl)
	return { requestScope = "all", path = tbl .. "." }
end
local function ddic_sources_query(prefix)
	return { datasource = prefix .. "*" }
end

-- GET ddicrepositoryaccess con la query dada -> lista de nombres (adtcore:name).
local function ddic_access(query, cb)
	adt.request_async({
		method = "GET",
		path = "/sap/bc/adt/ddic/ddl/ddicrepositoryaccess",
		query = query,
		accept = "application/*",
	}, function(body)
		local names, seen = {}, {}
		for nm in (body or ""):gmatch('adtcore:name="([^"]*)"') do
			if nm ~= "" and not seen[nm] then
				seen[nm] = true
				names[#names + 1] = nm
			end
		end
		cb(names)
	end)
end

-- Completado en un buffer CDS en (line,col). Entrega items {word,kind} por cb.
--   alias.campo  -> campos de la fuente resuelta (kind "1")
--   from/join X  -> fuentes que empiezan por X    (kind "2")
function M.completion(bufnr, line, col, cb)
	local linetext = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	local before = linetext:sub(1, col)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

	-- 1) alias.campo -> campos de la fuente
	local alias, prefix = before:match("([%w_/]+)%.([%w_/]*)$")
	if alias then
		local tbl = cds_alias_map(src)[alias:lower()] or alias
		ddic_access(ddic_fields_query(tbl), function(names)
			local items, pl = {}, prefix:lower()
			for _, n in ipairs(names) do
				if n:lower() ~= tbl:lower() and (pl == "" or n:lower():sub(1, #pl) == pl) then
					items[#items + 1] = { word = n, kind = "1" }
				end
			end
			cb(items)
		end)
		return
	end

	-- 2) tras from/join -> nombres de fuentes
	local sprefix = before:match("[Ff][Rr][Oo][Mm]%s+([%w_/]+)$") or before:match("[Jj][Oo][Ii][Nn]%s+([%w_/]+)$")
	if sprefix then
		ddic_access(ddic_sources_query(sprefix), function(names)
			local items = {}
			for _, n in ipairs(names) do
				items[#items + 1] = { word = n, kind = "2" }
			end
			cb(items)
		end)
		return
	end

	cb({})
end

-- Diagnóstico: resuelve el contexto y devuelve (info, cuerpo_crudo) de ddicrepositoryaccess.
function M.completion_debug(bufnr, line, col, cb)
	local linetext = vim.api.nvim_buf_get_lines(bufnr, line - 1, line, false)[1] or ""
	local before = linetext:sub(1, col)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local info = { aliases = cds_alias_map(src) }
	local query
	local alias, prefix = before:match("([%w_/]+)%.([%w_/]*)$")
	if alias then
		info.kind, info.alias, info.prefix = "field", alias, prefix
		info.table = info.aliases[alias:lower()] or alias
		query = ddic_fields_query(info.table)
	else
		local sp = before:match("[Ff][Rr][Oo][Mm]%s+([%w_/]+)$") or before:match("[Jj][Oo][Ii][Nn]%s+([%w_/]+)$")
		if sp then
			info.kind = "source"
			query = ddic_sources_query(sp)
		end
	end
	info.query = query
	if not query then
		cb(info, "(sin contexto de campo/fuente bajo el cursor)")
		return
	end
	-- Síncrono por curl (sin daemon) para ver la verdad del servidor en el diagnóstico.
	local body = adt.request({
		method = "GET",
		path = "/sap/bc/adt/ddic/ddl/ddicrepositoryaccess",
		query = query,
		accept = "application/*",
	})
	cb(info, body or "(nil)")
end

local RAP_PATH = {
	ddls = "/sap/bc/adt/ddic/ddl/sources/%s",
	ddlx = "/sap/bc/adt/ddic/ddlx/sources/%s",
	dcl = "/sap/bc/adt/acm/dcl/sources/%s",
	bdef = "/sap/bc/adt/bo/behaviordefinitions/%s",
	srvd = "/sap/bc/adt/ddic/srvd/sources/%s",
}

function M.open_adt(kind, name, opts)
	opts = opts or {}
	local base = RAP_PATH[kind]
	if not base then
		notify("Tipo RAP no soportado: " .. tostring(kind), vim.log.levels.WARN)
		return
	end
	if not adt.is_available() then
		notify("Sin conexión SAP.", vim.log.levels.WARN)
		return
	end
	local uri = base:format(name:lower())
	notify("Abriendo " .. name:upper() .. " (" .. kind .. ") por ADT...")
	adt.request_async({ method = "GET", path = uri .. "/source/main", accept = "text/plain" }, function(body)
		vim.schedule(function()
			if adt.is_auth_error and adt.is_auth_error(body) then
				notify(
					"401 No autorizado al leer " .. name .. ". Contraseña/conexión incorrecta — usa :SapRelogin.",
					vim.log.levels.ERROR
				)
				return
			end
			if not body or body == "" or is_exception(body) then
				notify(
					"No se pudo leer " .. name .. ": " .. (exc_message(body) or "respuesta vacía"),
					vim.log.levels.ERROR
				)
				return
			end
			local dir = require("sap-nvim.core.source").cache_dir()
			local file = dir .. "/" .. name:lower() .. "." .. kind
			-- LIMPIEZA DE BASURA ^M Y RETORNOS DE CARRO ANTES DE GUARDAR
			local clean_body = body:gsub("\r", "")
			vim.fn.writefile(vim.split(clean_body, "\n", { plain = true }), file)
			vim.cmd("noswapfile edit! " .. vim.fn.fnameescape(file))
			local b = vim.api.nvim_get_current_buf()
			vim.bo[b].swapfile = false
			vim.b[b].sap_obj = { name = name:upper(), group = kind, uri = uri }
			-- Sin ftdetect propio para .ddls/.bdef/etc.: usamos filetype `abap`. Así se
			-- aplica el coloreado nativo (abap.vim trae Neovim; select/from/key/as/on… son
			-- keywords ABAP) sin depender de un parser treesitter de CDS, y se enganchan
			-- hover/gd/gr/completado y los keymaps (FileType abap).
			if vim.bo[b].filetype == "" then
				vim.bo[b].filetype = "abap"
			end
			if opts.line then
				pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, opts.col or 0 })
				vim.cmd("normal! zz")
			end
			notify(name:upper() .. " abierto (" .. kind .. ").")
		end)
	end)
end

function M.open_uri(uri, name, opts)
	uri = unxml(uri or "")
	local kind = (uri:find("/ddic/ddl/sources/", 1, true) and "ddls")
		or (uri:find("/ddic/ddlx/sources/", 1, true) and "ddlx")
		or (uri:find("/acm/dcl/sources/", 1, true) and "dcl")
		or (uri:find("/bo/behaviordefinitions/", 1, true) and "bdef")
		or (uri:find("/ddic/srvd/sources/", 1, true) and "srvd")
	if kind then
		M.open_adt(kind, name, opts)
		return
	end
	local group = (uri:find("/oo/classes/", 1, true) and "class")
		or (uri:find("/oo/interfaces/", 1, true) and "interface")
		or (uri:find("/dictionary/tables/", 1, true) and "table")
		or (uri:find("/ddic/tables/", 1, true) and "table")
		or (uri:find("/dictionary/structures/", 1, true) and "structure")
	if group then
		require("sap-nvim.core.source").open(name, group, opts)
		return
	end
	notify("No sé cómo abrir: " .. uri, vim.log.levels.WARN)
end

function M.resolve_datasource(name, cb)
	adt.request_async({
		method = "GET",
		path = "/sap/bc/adt/ddic/ddl/ddicrepositoryaccess",
		query = { datasource = name, uriRequired = "X" },
		accept = "application/*",
	}, function(body)
		local uri = body and body:match('adtcore:uri="([^"]*)"')
		local nm = body and body:match('adtcore:name="([^"]*)"')
		vim.schedule(function()
			if uri and uri ~= "" and uri ~= "not_used" then
				cb({ uri = unxml(uri), name = (nm and nm ~= "" and nm) or name })
			else
				cb(nil)
			end
		end)
	end)
end

local function collect_refs(bufnr)
	local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
	local refs, seen = {}, {}
	local function add(label, name, kind)
		if not name then
			return
		end
		name = name:gsub("%s", ""):upper()
		if name == "" or seen[name] then
			return
		end
		seen[name] = true
		refs[#refs + 1] = { label = string.format("%-26s %s", label, name), name = name, kind = kind }
	end
	for c in src:gmatch("[Ii]mplementation%s+in%s+class%s+([%w_/]+)") do
		add("Behavior class", c)
	end
	for c in src:gmatch("[Dd]efine%s+behavior%s+for%s+([%w_/]+)") do
		add("CDS view (behavior for)", c, "ddls")
	end
	for c in src:gmatch("[Dd]raft%s+table%s+([%w_/]+)") do
		add("Draft table", c)
	end
	for c in src:gmatch("[Aa]s%s+projection%s+on%s+([%w_/]+)") do
		add("Base view (projection)", c, "ddls")
	end
	for c in src:gmatch("[Aa]nnotate%s+[%w]+%s+([%w_/]+)") do
		add("Annotated view (ddlx)", c, "ddls")
	end
	for c in src:gmatch("[Ee]xpose%s+([%w_/]+)") do
		add("Exposed entity (srvd)", c, "ddls")
	end
	for c in src:gmatch("[Gg]rant%s+select%s+on%s+([%w_/]+)") do
		add("Protected view (dcl)", c, "ddls")
	end
	for c in src:gmatch("%f[%w][Ff]rom%s+([%w_/]+)") do
		add("Data source (from)", c)
	end
	for c in src:gmatch("[Aa]ssociation[^\n]-%sto%s+([%w_/]+)") do
		add("Association target", c)
	end
	return refs
end

function M.rap_graph()
	if not adt.is_available() then
		notify("Sin conexión SAP.", vim.log.levels.WARN)
		return
	end
	local bufnr = vim.api.nvim_get_current_buf()
	local refs = collect_refs(bufnr)
	if #refs == 0 then
		notify("No se encontraron referencias RAP/CDS en el buffer.", vim.log.levels.WARN)
		return
	end
	vim.ui.select(refs, {
		prompt = "Grafo RAP — saltar a:",
		format_item = function(r)
			return r.label
		end,
	}, function(choice)
		if not choice then
			return
		end
		M.resolve_datasource(choice.name, function(ref)
			if ref then
				M.open_uri(ref.uri, ref.name)
			elseif choice.kind then
				M.open_adt(choice.kind, choice.name)
			else
				require("sap-nvim.core.source").open(choice.name, "class", {})
			end
		end)
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("SapCdsPreview", function(a)
		M.data_preview({ entity = a.args ~= "" and a.args:upper() or nil })
	end, { desc = "CDS: previsualizar datos (text-first)", nargs = "?" })

	vim.api.nvim_create_user_command("SapCdsSql", function(a)
		M.show_sql({ entity = a.args ~= "" and a.args:upper() or nil })
	end, { desc = "CDS: ver el SQL que ejecuta SAP", nargs = "?" })

	vim.api.nvim_create_user_command("SapCdsOData", function()
		M.odata_http({})
	end, { desc = "CDS: generar entorno OData .http" })

	vim.api.nvim_create_user_command("SapCdsGraph", function()
		M.rap_graph()
	end, { desc = "RAP: saltar por el grafo (ddls/ddlx/dcl/bdef/srvd/clases)" })

	vim.api.nvim_create_user_command("SapCdsOpen", function(a)
		local kind, name = a.args:match("^(%S+)%s+(%S+)$")
		if not kind then
			name = a.args:match("^(%S+)$")
			if name then
				kind = "ddls"
			else
				vim.notify("[sap-nvim CDS] Uso: SapCdsOpen [ddls|ddlx|bdef|dcl|srvd] <NOMBRE>", vim.log.levels.WARN)
				return
			end
		end
		M.open_adt(kind:lower(), name)
	end, { desc = "RAP: abrir objeto por ADT directo", nargs = "+" })
end

return M
