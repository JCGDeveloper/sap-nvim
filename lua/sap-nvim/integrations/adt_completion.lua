local source = {}

local function url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("[^%w_~%.%-]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

function source.new(opts)
	return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
	local ft = vim.bo.filetype
	return ft == "abap" or ft == "cds" or ft == "acds" or ft == "abapcds" or ft == "ddls"
end

function source:get_trigger_characters()
	return { ">", "-", "=", "~", "(", ",", ":", " ", "@", ".", "$" }
end

local Kind = vim.lsp.protocol.CompletionItemKind
-- AÑADIDO: Soporte explícito para "Funciones" y "Palabras clave"
local KIND_MAP =
	{ ["1"] = Kind.Variable, ["2"] = Kind.Class, ["3"] = Kind.Method, ["4"] = Kind.Function, ["52"] = Kind.Keyword }
local KIND_LABEL =
	{ ["1"] = "variable", ["2"] = "clase/tipo", ["3"] = "método", ["4"] = "función", ["52"] = "keyword" }

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
	local struct_field = before:match("[%w_%]%)]%-[%w_]*$") ~= nil
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
		local struct_prefix = struct_field and (before:match("([%w_]+%-)[%w_]*$") or "") or nil

		for _, p in ipairs(props or {}) do
			local plen = p.prefixlength or typed_len
			local it = {
				label = p.word,
				kind = KIND_MAP[p.kind or ""] or Kind.Text,
				labelDetails = { description = KIND_LABEL[p.kind or ""] or "SAP" },
				insertText = p.word,
				filterText = p.word,

				sap_resolve = {
					is_method = (p.kind == "3" and member),
					-- 🔥 MAGIA PURA: Permitimos que funciones (4) y keywords (52) intenten buscar snippet
					needs_pattern = (p.kind == "3" or p.kind == "4" or p.kind == "52"),
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

	local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	lines[row] = (lines[row] or ""):sub(1, start_col)
	local src = table.concat(lines, "\n")

	local ctx = ""
	local meta = vim.b[bufnr].sap_obj
	if meta and meta.group == "include" then
		local mps = intel.main_programs(meta.name)
		if mps and mps[1] then
			ctx = "?context=" .. url_encode(mps[1])
		end
	end

	local logical = uri .. ctx .. "%23start=" .. row .. "," .. start_col

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

			vim.api.nvim_buf_set_text(0, row0, from_col, row0, to_col, out)
			local last_row = row0 + (#out - 1)
			pcall(vim.api.nvim_win_set_cursor, 0, { last_row + 1, #(out[#out] or "") })
			callback()
		end)
	end)
end

return source
