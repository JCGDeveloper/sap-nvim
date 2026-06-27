local intel = require("sap-nvim.core.intel")

local SapSource = {}
local Kind = require("blink.cmp.types").CompletionItemKind

function SapSource.new()
	return setmetatable({}, { __index = SapSource })
end

function SapSource:get_trigger_characters()
	return { ">", "-", "=", "~", ".", "@", ":", " ", ",", "$" }
end

function SapSource:get_completions(context, callback)
	local bufnr = context.bufnr or vim.api.nvim_get_current_buf()
	local row = (context.cursor and context.cursor[1]) or vim.api.nvim_win_get_cursor(0)[1]
	local col = (context.cursor and context.cursor[2]) or vim.api.nvim_win_get_cursor(0)[2]

	intel.proposals_async(bufnr, row, col, function(items)
		local completions = {}

		for _, it in ipairs(items) do
			local kind = Kind.Text
			local sort = "50"
			if it.kind == "2" then
				kind = Kind.Class
				sort = "10"
			elseif it.kind == "1" then
				kind = Kind.Variable
				sort = "00"
			elseif it.kind == "3" then
				kind = Kind.Method
				sort = "20"
			elseif it.kind == "4" or it.kind == "6" then
				kind = Kind.Function
				sort = "25"
			elseif it.kind == "52" then
				kind = Kind.Keyword
				sort = "90"
			end

			table.insert(completions, {
				label = it.word,
				kind = kind,
				detail = "SAP ADT",
				filterText = it.word,
				sortText = sort .. "_" .. it.word,
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
