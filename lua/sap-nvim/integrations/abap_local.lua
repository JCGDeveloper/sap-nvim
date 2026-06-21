-- sap-nvim.integrations.abap_local
-- Fuente blink.cmp LOCAL e INSTANTÁNEA (sin red): keywords ABAP (da->DATA) + las plantillas/
-- snippets de core/snippets.lua. Es lo que hace que el completado se sienta INMEDIATO como en
-- VSCode: estas propuestas NO consultan al servidor, se devuelven en el acto y blink las filtra
-- localmente. La fuente `sap_adt` (ADT) sigue aportando, async, los métodos/atributos/clases
-- del sistema (eso sí necesita el servidor).
--
-- R-A1 — Keywords CONTEXTUALES: además del set estático, detectamos en qué parte del código
-- está el cursor (definición de clase / firma de método / cuerpo de método / global) y
-- ofrecemos PRIORIZADOS los keywords propios de ese contexto (IMPORTING/EXPORTING/RETURNING
-- VALUE/CHANGING en una firma; METHODS/CLASS-METHODS/DATA en la sección de clase; etc.),
-- tal como hace Eclipse/ADT. La detección es heurística, pura y local (probada offline).
--
-- Registro en blink: provider "abap_local" (en la config del usuario), junto a "sap_adt".

local source = {}

function source.new(opts)
	return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
	if vim.bo.filetype ~= "abap" then
		return false
	end
	-- 🔥 FIX: Silenciar las keywords nativas de ABAP dentro de archivos CDS
	local ok, cds = pcall(require, "sap-nvim.core.cds")
	if ok and cds.is_cds_buf(0) then
		return false
	end
	return true
end

local Kind = vim.lsp.protocol.CompletionItemKind
local Fmt = vim.lsp.protocol.InsertTextFormat

-- ─── Detección de contexto (heurística, pura, testeada offline) ───────────────

local SCAN_LIMIT = 300 -- nº máx. de líneas que escaneamos hacia arriba (rendimiento)

local function code_only(line)
	local l = line or ""
	if l:match("^%s*%*") then
		return ""
	end -- comentario de línea completa
	local q = l:find('"') -- comentario inline (aprox)
	if q then
		l = l:sub(1, q - 1)
	end
	return l
end

-- Primer token del statement ABAP actual (sube hasta el '.' que cierra el anterior).
local function stmt_first_token(lines, row)
	local start = 1
	local limit = math.max(1, row - SCAN_LIMIT)
	for i = row - 1, limit, -1 do
		local c = code_only(lines[i]):gsub("%s+$", "")
		if c:match("%.%s*$") then
			start = i + 1
			break
		end
	end
	for i = start, row do
		local tok = code_only(lines[i]):match("^%s*([%a_][%w_%-]*)")
		if tok then
			return tok:lower()
		end
	end
	return nil
end

-- Devuelve: "method_sig" | "class_def" | "method_body" | "impl_between" | "global"
local function detect_context(lines, row)
	local first = stmt_first_token(lines, row)
	if first == "methods" or first == "class-methods" then
		return "method_sig"
	end
	local limit = math.max(1, row - SCAN_LIMIT)
	for i = row - 1, limit, -1 do
		local c = code_only(lines[i]):lower()
		if c:match("^%s*endmethod%f[^%w]") then
			return "impl_between"
		end
		if c:match("^%s*method%f[^%w_]") then
			return "method_body"
		end
		if c:match("endclass%f[^%w]") then
			return "global"
		end
		if c:match("class%f[^%w_].-implementation") then
			return "impl_between"
		end
		if c:match("class%f[^%w_].-definition") then
			return "class_def"
		end
	end
	return "global"
end

-- Exponer para tests / depuración (:lua =require'...'.detect_context(...)).
source._detect_context = detect_context

-- ─── Items por contexto ───────────────────────────────────────────────────────
-- Cada item: { label, insert (opcional, default=label), snippet=true (opcional) }.

local CONTEXT_ITEMS = {
	method_sig = {
		{ label = "IMPORTING" },
		{ label = "EXPORTING" },
		{ label = "CHANGING" },
		{ label = "RETURNING VALUE()", insert = "RETURNING VALUE(${1:rv_result}) TYPE ${2:type}", snippet = true },
		{ label = "RAISING" },
		{ label = "OPTIONAL" },
		{ label = "DEFAULT" },
		{ label = "PREFERRED PARAMETER" },
		{ label = "REDEFINITION" },
		{ label = "ABSTRACT" },
		{ label = "FINAL" },
	},
	class_def = {
		{ label = "PUBLIC SECTION." },
		{ label = "PROTECTED SECTION." },
		{ label = "PRIVATE SECTION." },
		{ label = "METHODS" },
		{ label = "CLASS-METHODS" },
		{ label = "DATA" },
		{ label = "CLASS-DATA" },
		{ label = "CONSTANTS" },
		{ label = "TYPES" },
		{ label = "INTERFACES" },
		{ label = "ALIASES" },
		{ label = "EVENTS" },
		{ label = "CLASS-EVENTS" },
	},
	impl_between = {
		{ label = "METHOD", insert = "METHOD ${1:name}.\n  $0\nENDMETHOD.", snippet = true },
	},
	method_body = {
		{ label = "DATA" },
		{ label = "CHECK" },
		{ label = "RETURN." },
		{ label = "RAISE EXCEPTION" },
		{ label = "MOVE-CORRESPONDING" },
		{ label = "LOOP AT", insert = "LOOP AT ${1:itab} INTO ${2:wa}.\n  $0\nENDLOOP.", snippet = true },
		{
			label = "READ TABLE",
			insert = "READ TABLE ${1:itab} INTO ${2:wa} WITH KEY ${3:k} = ${4:v}.",
			snippet = true,
		},
	},
	global = {},
}

local function build_context_items(ctx)
	local defs = CONTEXT_ITEMS[ctx] or {}
	local items = {}
	for idx, d in ipairs(defs) do
		items[#items + 1] = {
			label = d.label,
			insertText = d.insert or d.label,
			insertTextFormat = d.snippet and Fmt.Snippet or Fmt.PlainText,
			kind = d.snippet and Kind.Snippet or Kind.Keyword,
			labelDetails = { description = "ABAP · " .. ctx },
			-- Empuja estos por encima del set estático; sortText conserva el orden lógico.
			score_offset = 100,
			sortText = string.format("00_%02d_%s", idx, d.label),
			source_name = "ABAP",
		}
	end
	return items
end

-- ─── Set estático (keywords + snippets), cacheado ─────────────────────────────

local cache

local function build_static_items()
	if cache then
		return cache
	end
	local items = {}

	-- 1) Keywords ABAP (en MAYÚSCULAS), reutilizando la lista del formateador.
	local seen = {}
	local ok, fmt = pcall(require, "sap-nvim.core.formatter")
	for _, kw in ipairs((ok and fmt.keywords) or {}) do
		local u = kw:upper()
		if not seen[u] then
			seen[u] = true
			items[#items + 1] = {
				label = u,
				insertText = u,
				kind = Kind.Keyword,
				labelDetails = { description = "keyword" },
				source_name = "ABAP",
			}
		end
	end

	-- 2) Plantillas/snippets (se expanden con placeholders ${n}).
	local oks, snippets = pcall(require, "sap-nvim.core.snippets")
	if oks then
		for _, s in pairs(snippets) do
			if s.trig then
				items[#items + 1] = {
					label = s.trig,
					insertText = s.body:gsub("\\n", "\n"),
					insertTextFormat = Fmt.Snippet,
					kind = Kind.Snippet,
					labelDetails = { description = "snippet · " .. (s.name or "") },
					source_name = "ABAP",
				}
			end
		end
	end

	cache = items
	return items
end

-- ─── Variables dinámicas (R-D2) ───────────────────────────────────────────────
-- Expande $DATE/$AUTHOR/$OBJECT/$PACKAGE/... en los cuerpos de snippet, en el momento de
-- proponer (no en caché, para que $DATE/$TIME sean frescas). Solo copia los items que de
-- verdad contienen una variable dinámica; el resto se devuelven tal cual.
local function expand_dynamic(items, tctx)
	local tv = require("sap-nvim.core.template_vars")
	local out = {}
	for _, it in ipairs(items) do
		if it.insertText and it.insertText:find("%$%u") then
			local copy = {}
			for k, v in pairs(it) do
				copy[k] = v
			end
			copy.insertText = tv.expand(it.insertText, tctx)
			out[#out + 1] = copy
		else
			out[#out + 1] = it
		end
	end
	return out
end

-- ─── Entrada de blink ─────────────────────────────────────────────────────────

-- Devuelve los items contextuales (priorizados) + el set estático; blink filtra/ordena.
function source:get_completions(ctx, callback)
	local row
	if ctx and ctx.cursor and ctx.cursor[1] then
		row = ctx.cursor[1]
	else
		row = vim.api.nvim_win_get_cursor(0)[1]
	end
	local bufnr = (ctx and ctx.bufnr) or vim.api.nvim_get_current_buf()

	-- 🔥 FIX: Si el buffer es un CDS, SILENCIAMOS las keywords de ABAP
	local meta = vim.b[bufnr].sap_obj
	local CDS_G = { ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
	if meta and CDS_G[meta.group] then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
		return function() end
	end

	-- En contextos donde SOLO tienen sentido las propuestas del servidor (sap_adt), callamos
	-- los keywords ABAP para no taparlas: tras `wa-` (campo de estructura) y tras `TYPE `/`LIKE `
	-- (tipos/tablas DDIC). Los miembros `->`/`=>`/`~` ya los silencia el `enabled` de la config.
	do
		local col = (ctx and ctx.cursor and ctx.cursor[2]) or vim.api.nvim_win_get_cursor(0)[2]
		local before = (vim.api.nvim_get_current_line() or ""):sub(1, col)
		local bl = before:lower()
		if
			before:match("[%w_]%-[%w_]*$") -- wa-campo (estructura, no `->`)
			or bl:match("%s+type%s+[%w_/]*$")
			or bl:match("%s+like%s+[%w_/]*$")
		then
			callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = false })
			return function() end
		end
	end

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, row, false)
	local items = {}
	vim.list_extend(items, build_context_items(detect_context(lines, row)))
	vim.list_extend(items, build_static_items())

	local ok_tv, tctx = pcall(function()
		return require("sap-nvim.core.template_vars").context(bufnr)
	end)
	if ok_tv then
		items = expand_dynamic(items, tctx)
	end

	callback({ items = items, is_incomplete_backward = false, is_incomplete_forward = false })
	return function() end
end

return source
