-- lua/sap-nvim/integrations/adt_completion.lua
local source = {}

function source.new(opts)
	return setmetatable({ opts = opts or {} }, { __index = source })
end

function source:enabled()
	local ft = vim.bo.filetype
	-- ABAP + variantes de CDS según el plugin de sintaxis del usuario.
	return ft == "abap" or ft == "cds" or ft == "acds" or ft == "abapcds" or ft == "ddls"
end

function source:get_trigger_characters()
	-- ":" y " " disparan tras TYPE REF TO; "@" las anotaciones CDS; "." los campos tras un
	-- alias (CDS: `B.`), y "[" dentro de los corchetes de asociación. En ABAP el gate ignora
	-- "." / "[" (no consultan al servidor), así que añadirlos no mete ruido.
	return { ">", "-", "=", "~", "(", ",", ":", " ", "@", ".", "[" }
end

local Kind = vim.lsp.protocol.CompletionItemKind
local KIND_MAP = { ["1"] = Kind.Variable, ["2"] = Kind.Class, ["3"] = Kind.Method, ["52"] = Kind.Keyword }
local KIND_LABEL = { ["1"] = "variable", ["2"] = "clase/tipo", ["3"] = "método", ["52"] = "keyword" }

function source:get_completions(ctx, callback)
	local col = ctx.cursor[2]
	local before = (ctx.line or ""):sub(1, col)
	local bufnr = ctx.bufnr or vim.api.nvim_get_current_buf()

	-- CDS/RAP se editan con filetype `abap`, pero el objeto trae group ddls/ddlx/dcl/bdef/srvd.
	local meta = vim.b[bufnr].sap_obj
	local CDS_GROUPS = { ddls = true, ddlx = true, dcl = true, bdef = true, srvd = true }
	local is_cds = meta ~= nil and CDS_GROUPS[meta.group] == true
	local manual = ctx.trigger ~= nil and ctx.trigger.kind == "manual"

	local is_type_declaration = before:match("TYPE%s+REF%s+TO%s+[%w_]*$") ~= nil
	local member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil
	local call = before:match("[%(,]%s*$") ~= nil
	local annotation = before:match("@[%w%._]*$") ~= nil
	local word = before:match("[%w_/][%w_/]*$")

	-- ¿Pedimos propuestas al servidor ADT?
	local ask
	if manual then
		ask = true -- Ctrl-Space (como en Eclipse): pregunta SIEMPRE al servidor.
	elseif is_cds then
		-- En CDS deja decidir al servidor: campos tras `alias.`, valores de anotación tras
		-- `:`, dentro de corchetes `[ ... ]`, o cualquier palabra empezada.
		ask = word ~= nil or member or call or annotation
			or before:match("[%w_]%.[%w_]*$") ~= nil
			or before:match(":%s*['#]?[%w_]*$") ~= nil
			or before:match("%[%s*[%w_]*$") ~= nil
	else
		ask = member or call or is_type_declaration or annotation or (word ~= nil and #word >= 2)
	end
	if not ask then
		callback({ items = {}, is_incomplete_backward = false, is_incomplete_forward = true })
		return function() end
	end

	local intel = require("sap-nvim.core.intel")
	local row = ctx.cursor[1]

	-- PREFIJO A REEMPLAZAR según el contexto:
	--   tras ->/=>/~  → lo que va DESPUÉS del operador (vacío en "lo_alv->")
	--   tras @        → la anotación
	--   si no         → la palabra normal
	-- Antes se usaba #(word or p.word): al ser word=nil tras "->", reemplazaba #p.word
	-- caracteres hacia atrás y se comía "lo_alv". El rango debe arrancar justo tras el "->".
	local replace = before:match("[=%-]>([%w_]*)$")
		or before:match("~([%w_]*)$")
		or before:match("@([%w%._]*)$")
		or before:match("(['#][%w_]*)$") -- valor de anotación CDS: 'campo o #ENUM (incluye el '/# )
		or before:match("[%w_/]+$")
		or ""
	local start_char = col - #replace

	intel.proposals_async(bufnr, row, col, function(props)
		local items = {}
		for _, p in ipairs(props) do
			local it = {
				label = p.word,
				kind = KIND_MAP[p.kind or ""] or Kind.Text,
				labelDetails = { description = KIND_LABEL[p.kind or ""] or "SAP" },
				source_name = "SAP",
				textEdit = {
					newText = p.word,
					range = {
						start = { line = row - 1, character = start_char },
						["end"] = { line = row - 1, character = col },
					},
				},
			}

			if p.kind == "3" and member then
				it.textEdit.newText = p.word .. "( $0 )"
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
