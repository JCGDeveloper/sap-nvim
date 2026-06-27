local source = {}

function source.new(opts)
	return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
	local ft = vim.bo.filetype
	return ft == "abap" or ft == "cds" or ft == "acds" or ft == "abapcds" or ft == "ddl" or ft == "ddls"
end

function source:get_trigger_characters()
	return { ">", "-", "=", "~", "(", ",", ":", " ", "@", ".", "$" }
end

local Kind = vim.lsp.protocol.CompletionItemKind
-- AÑADIDO: Soporte explícito para "Funciones" y "Palabras clave"
local KIND_MAP = {
	["1"] = Kind.Variable,
	["2"] = Kind.Class,
	["3"] = Kind.Method,
	["4"] = Kind.Function,
	["6"] = Kind.Function, -- módulo de función (CALL FUNCTION)
	["52"] = Kind.Keyword,
}
local KIND_LABEL = {
	["1"] = "variable",
	["2"] = "clase/tipo",
	["3"] = "método",
	["4"] = "función",
	["6"] = "módulo func.",
	["52"] = "keyword",
}

function source:get_completions(ctx, callback)
	local col = ctx.cursor[2]
	local before = (ctx.line or ""):sub(1, col)

	local is_type_declaration = before:match("TYPE%s+REF%s+TO%s+[%w_]*$") ~= nil
	local member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil
	local call = before:match("[%(,]%s*$") ~= nil

	local annotation = before:match("@[%w%._]*$") ~= nil
	local cds_field = before:match("[%w_/]+%.[%w_/]*$") ~= nil
	local cds_anno_val = before:match("@[%w%._]+%s*:%s*['#]?[%w_#]*$") ~= nil
	-- Acceso a campo tras `-`: nombre normal (wa-campo) Y también tras una expresión de tabla
	-- o método: lt_rutas[ 1 ]-campo / get_struct( )-campo (el carácter previo es `]` o `)`).
	local struct_field = before:match("[%w_%>%]%)]%-[%w_]*$") ~= nil
	local bl = before:lower()
	local type_ctx = bl:match("%s+type%s+[%w_/]*$") ~= nil or bl:match("%s+like%s+[%w_/]*$") ~= nil

	local word = ""
	if cds_anno_val then
		word = before:match(":%s*(['#]?[%w_#]*)$") or ""
	elseif cds_field then
		word = before:match("%.([%w_/]*)$") or ""
	elseif struct_field then
		word = before:match("%-([%w_]*)$") or ""
	elseif annotation then
		word = before:match("@([%w%._]*)$") or ""
	else
		word = before:match("[%w_/%$]+$") or ""
	end

	if
		not member
		and not call
		and not is_type_declaration
		and not annotation
		and not cds_field
		and not cds_anno_val
		and not struct_field
		and not type_ctx
		and #word < 2
	then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = true })
		return function() end
	end

	local intel = require("sap-nvim.core.intel")
	local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
	local row = ctx.cursor[1]

	intel.proposals_async(bufnr, row, col, function(props)
		local items = {}
		local typed_len = #word
		local struct_prefix = struct_field and (before:match("([%w_<>]+%-)[%w_]*$") or "") or nil

		for _, p in ipairs(props or {}) do
			local plen = p.prefixlength or typed_len
			local sort = "50"
			if p.kind == "1" then
				sort = "00"
			elseif p.kind == "2" then
				sort = "10"
			elseif p.kind == "3" then
				sort = "20"
			elseif p.kind == "4" or p.kind == "6" then
				sort = "25"
			elseif p.kind == "52" then
				sort = "90"
			end
			local it = {
				label = p.word,
				kind = KIND_MAP[p.kind or ""] or Kind.Text,
				labelDetails = { description = KIND_LABEL[p.kind or ""] or "SAP" },
				insertText = p.word,
				filterText = p.word,
				sortText = sort .. "_" .. p.word,

				sap_resolve = {
					is_method = (p.kind == "3" and member),
					-- Métodos (3), funciones (4), MÓDULOS DE FUNCIÓN (6) y keywords (52) intentan
					-- expandir su patrón (EXPORTING/IMPORTING/...). Si no hay patrón, cae al nombre.
					needs_pattern = (p.kind == "3" or p.kind == "4" or p.kind == "6" or p.kind == "52"),
					bufnr = bufnr,
					row = row,
					start_col = ctx.cursor[2] - plen,
				},
			}

			if struct_field then
				it.filterText = struct_prefix .. p.word
				it.textEdit = {
					newText = p.word,
					range = {
						start = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] - typed_len },
						["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
					},
				}
			elseif plen > 0 then
				it.textEdit = {
					newText = p.word,
					range = {
						start = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] - plen },
						["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
					},
				}
			end

			items[#items + 1] = it
		end

		vim.schedule(function()
			callback({ items = items, is_incomplete_backward = true, is_incomplete_forward = true })
		end)
	end)
	return function() end
end

local function fetch_method_insertion(item, callback)
	if item.sap_snippet ~= nil then
		return callback(item.sap_snippet or nil)
	end
	-- Modificado para que no se bloquee solo a is_method, usa la nueva propiedad abierta
	if not item.sap_resolve or not item.sap_resolve.needs_pattern then
		item.sap_snippet = false
		return callback(nil)
	end

	local intel = require("sap-nvim.core.intel")
	local adt_http = require("sap-nvim.core.adt_http")

	local bufnr = item.sap_resolve.bufnr
	local row = item.sap_resolve.row
	local start_col = item.sap_resolve.start_col

	local uri = intel.object_uri(bufnr)
	if not uri then
		item.sap_snippet = false
		return callback(nil)
	end

	-- Ponemos el NOMBRE COMPLETO en el ancla y pedimos el patrón con el cursor al final del
	-- nombre. Los módulos de función (CALL FUNCTION 'X') NECESITAN el nombre en la fuente para
	-- resolver (truncar daba HTTP 400); a los métodos también les vale. Posición = ancla + nombre.
	local name = item.label
	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	lines[row] = (lines[row] or ""):sub(1, start_col) .. name
	local src = table.concat(lines, "\n")
	local pos_col = start_col + #name

	local ctx = ""
	local meta = vim.b[bufnr].sap_obj
	if meta and meta.group == "include" then
		local mps = intel.main_programs(meta.name)
		if mps and mps[1] then
			ctx = "?context=" .. mps[1]
		end
	end

	local logical = uri .. ctx .. "#start=" .. row .. "," .. pos_col

	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/abapsource/codecompletion/insertion",
		query = { uri = logical, patternKey = item.label:upper() },
		content_type = "application/*",
		body = src,
	}, function(body)
		if not body or body == "" or body:match("^%s*<") then
			item.sap_snippet = false
			return callback(nil)
		end
		item.sap_snippet = (body:gsub("\r", ""))
		callback(item.sap_snippet)
	end)
end

function source:resolve(item, callback)
	if not item.sap_resolve or not item.sap_resolve.needs_pattern then
		return callback(item)
	end
	fetch_method_insertion(item, function()
		callback(item)
	end)
end

function source:execute(ctx, item, callback, default_implementation)
	callback = callback or function() end
	-- Ampliamos el filtro para dejar pasar el Snippet
	if not item.sap_resolve or not item.sap_resolve.needs_pattern then
		if default_implementation then
			default_implementation()
		end
		return callback()
	end

	fetch_method_insertion(item, function(text)
		vim.schedule(function()
			local cur = vim.api.nvim_win_get_cursor(0)
			local row0 = item.sap_resolve.row - 1
			if not text or (cur[1] - 1) ~= row0 then
				if default_implementation then
					default_implementation()
				end
				return callback()
			end

			local from_col = item.sap_resolve.start_col
			local to_col = math.max(from_col, cur[2])

			local out = vim.split(text, "\n", { plain = true })
			while #out > 1 and out[#out] == "" do
				table.remove(out)
			end

			-- Módulo de función: el patrón cierra con comilla (NAME'). Si justo tras el cursor ya
			-- hay una comilla (la de cierre del literal), la consumimos para no duplicarla.
			local cur_line = vim.api.nvim_buf_get_lines(0, row0, row0 + 1, false)[1] or ""
			if out[1] and out[1]:sub(-1) == "'" and cur_line:sub(to_col + 1, to_col + 1) == "'" then
				to_col = to_col + 1
			end

			vim.api.nvim_buf_set_text(0, row0, from_col, row0, to_col, out)
			local last_row = row0 + (#out - 1)
			pcall(vim.api.nvim_win_set_cursor, 0, { last_row + 1, #(out[#out] or "") })
			callback()
		end)
	end)
end

return source
