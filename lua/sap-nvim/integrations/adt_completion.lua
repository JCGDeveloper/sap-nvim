-- lua/sap-nvim/integrations/adt_completion.lua
-- Fuente blink.cmp que muestra AUTOMÁTICAMENTE el completado ABAP vía ADT
-- (core/intel.proposals_async): métodos/atributos y nombres de clases/variables.

local source = {}

function source.new(opts)
	return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
	return vim.bo.filetype == "abap"
end

-- Tras escribir estos caracteres, blink dispara la fuente.
-- Añadidos "-" y "=" para que lea las flechas al instante.
function source:get_trigger_characters()
	return { ">", "-", "=", "~", "(", "," }
end

local Kind = vim.lsp.protocol.CompletionItemKind

-- KIND de ADT -> icono de completado.
local KIND_MAP = {
	["1"] = Kind.Variable,
	["2"] = Kind.Class,
	["3"] = Kind.Method,
	["52"] = Kind.Keyword,
}

-- Etiqueta de tipo mostrada como "detalle" del item
local KIND_LABEL = {
	["1"] = "variable",
	["2"] = "clase/tipo",
	["3"] = "método",
	["52"] = "keyword",
}

function source:get_completions(ctx, callback)
	local col = ctx.cursor[2]
	local before = (ctx.line or ""):sub(1, col)

	local member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil
	local call = before:match("[%(,]%s*$") ~= nil
	local word = before:match("[%w_/][%w_/]*$")

	if not member and not call and (not word or #word < 2) then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = true })
		return function() end
	end

	local intel = require("sap-nvim.core.intel")
	local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()
	local row = ctx.cursor[1]

	local Fmt = vim.lsp.protocol.InsertTextFormat

	intel.proposals_async(bufnr, row, col, function(props)
		local items = {}
		for _, p in ipairs(props) do
			local it = {
				label = p.word,
				insertText = p.word,
				-- Aseguramos que el Kind nunca sea nil para que Blink no lo descarte
				kind = KIND_MAP[p.kind or ""] or Kind.Text,
				labelDetails = { description = KIND_LABEL[p.kind or ""] or "SAP" },
				source_name = "SAP",
			}

			if p.kind == "3" and member then
				it.insertText = p.word .. "( $0 )"
				it.insertTextFormat = Fmt.Snippet
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
