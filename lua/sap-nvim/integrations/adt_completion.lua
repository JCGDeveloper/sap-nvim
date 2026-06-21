local source = {}

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
local KIND_MAP = { ["1"] = Kind.Variable, ["2"] = Kind.Class, ["3"] = Kind.Method, ["52"] = Kind.Keyword }
local KIND_LABEL = { ["1"] = "variable", ["2"] = "clase/tipo", ["3"] = "método", ["52"] = "keyword" }

function source:get_completions(ctx, callback)
	local col = ctx.cursor[2]
	local before = (ctx.line or ""):sub(1, col)

	local is_type_declaration = before:match("TYPE%s+REF%s+TO%s+[%w_]*$") ~= nil
	local member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil
	local call = before:match("[%(,]%s*$") ~= nil

	local annotation = before:match("@[%w%._]*$") ~= nil
	local cds_field = before:match("[%w_/]+%.[%w_/]*$") ~= nil
	local cds_anno_val = before:match("@[%w%._]+%s*:%s*['#]?[%w_#]*$") ~= nil
	-- ABAP: acceso a campo de estructura `wa-campo` (guion, NO `->`, y sin espacio antes del
	-- guion para no confundir con la resta `a - b`). El servidor ADT devuelve los campos.
	local struct_field = before:match("[%w_]%-[%w_]*$") ~= nil
	-- ABAP: tras `TYPE ` (o `LIKE `) sugerir tipos/tablas DDIC ya desde el espacio (como VSCode).
	-- Requiere espacio antes de `type`/`like` para no saltar con variables como `lv_type`.
	local bl = before:lower()
	local type_ctx = bl:match("%s+type%s+[%w_/]*$") ~= nil or bl:match("%s+like%s+[%w_/]*$") ~= nil

	-- 🔥 FIX: Le decimos a Blink EXACTAMENTE qué letras acabas de teclear
	-- para que sepa cómo filtrarlo y cómo reemplazarlo.
	local word = ""
	if cds_anno_val then
		word = before:match(":%s*(['#]?[%w_#]*)$") or ""
	elseif cds_field then
		word = before:match("%.([%w_/]*)$") or ""
	elseif struct_field then
		word = before:match("%-([%w_]*)$") or "" -- lo tecleado tras el guion de estructura
	elseif annotation then
		word = before:match("@([%w%._]*)$") or ""
	else
		-- 🔥 FIX: Añadimos %$ para que sepa borrarlo al insertar la palabra completa
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

		for _, p in ipairs(props) do
			-- Rango a reemplazar: el PREFIXLENGTH del servidor (como VSCode) si viene; si no,
			-- el heurístico de lo tecleado. Así `wa-campo`, namespaces `/x/` y `<fs>` van bien.
			local plen = p.prefixlength or typed_len
			local it = {
				label = p.word,
				kind = KIND_MAP[p.kind or ""] or Kind.Text,
				labelDetails = { description = KIND_LABEL[p.kind or ""] or "SAP" },
				source_name = "SAP",
				insertText = p.word,
				textEdit = {
					newText = p.word,
					range = {
						start = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] - plen },
						["end"] = { line = ctx.cursor[1] - 1, character = ctx.cursor[2] },
					},
				},
			}

			if p.kind == "3" and member then
				it.textEdit.newText = p.word .. "( $0 )"
				it.insertText = p.word .. "( $0 )"
				it.insertTextFormat = vim.lsp.protocol.InsertTextFormat.Snippet
			end

			items[#items + 1] = it
		end

		vim.schedule(function()
			callback({
				items = items,
				is_incomplete_backward = true,
				is_incomplete_forward = false,
			})
		end)
	end)
	return function() end
end

return source
