local intel = require("sap-nvim.core.intel")

local SapSource = {}

function SapSource.new()
	return setmetatable({}, { __index = SapSource })
end

-- Aquí le decimos a Blink que se despierte y pregunte al plugin
-- justo cuando el usuario teclee estos caracteres.
function SapSource:get_trigger_characters()
	return { ">", "-", "=", "~" }
end

function SapSource:get_completions(context, callback)
	-- 1. Chivato: Si esto no sale en pantalla, Blink NO nos está llamando
	vim.notify("¡Blink ha detectado la flecha y llama a SAP!", vim.log.levels.WARN)

	local bufnr = vim.api.nvim_get_current_buf()
	local row = context.cursor[1]
	local col = context.cursor[2]

	intel.proposals_async(bufnr, row, col, function(items)
		local completions = {}

		-- 2. Método falso de prueba: Lo metemos a la fuerza para ver si Blink lo dibuja
		table.insert(completions, {
			label = "METODO_FALSO_DE_PRUEBA",
			kind = require("blink.cmp.types").CompletionItemKind.Method,
			detail = "TEST",
		})

		for _, it in ipairs(items) do
			local kind = require("blink.cmp.types").CompletionItemKind.Method
			if it.kind == "2" then
				kind = require("blink.cmp.types").CompletionItemKind.Class
			elseif it.kind == "1" then
				kind = require("blink.cmp.types").CompletionItemKind.Variable
			end

			table.insert(completions, {
				label = it.word,
				kind = kind,
				detail = "SAP ADT",
			})
		end

		callback({
			is_incomplete_forward = false,
			is_incomplete_backward = false,
			items = completions,
		})
	end)
end

return SapSource
