local intel = require("sap-nvim.core.intel")
local index = require("sap-nvim.core.index")

local SapSource = {}
local Kind = require("blink.cmp.types").CompletionItemKind

function SapSource.new()
	return setmetatable({}, { __index = SapSource })
end

function SapSource:get_trigger_characters()
	return { ">", "-", "=", "~", ".", "@", ":", " ", ",", "$" }
end

local function prefix_before_cursor(bufnr, row, col)
	local line = vim.api.nvim_buf_get_lines(bufnr, row - 1, row, false)[1] or ""
	local before = line:sub(1, col)
	return before, (before:match("([%w_]+)$") or "")
end

local function indexed_items(bufnr, row, col)
	local before, prefix = prefix_before_cursor(bufnr, row, col)
	if #prefix < 2 then
		return {}
	end
	local lower = before:lower()
	local opts = { limit = 50 }
	if before:match("[=%-]>[%w_]*$") or before:match("~[%w_]*$") then
		opts.kind = "method"
	elseif before:match("[%w_%>%]%)]%-[%w_]*$") then
		opts.kind = "field"
	else
		opts.kinds = { "object", "package" }
		if lower:match("type%s+ref%s+to%s+[%w_]*$") then
			opts.kinds = { "object" }
		elseif not (lower:match("%s+type%s+[%w_]*$") or lower:match("%s+like%s+[%w_]*$")) then
			local meta = vim.b[bufnr].sap_obj
			if meta and meta.name and prefix:upper() == meta.name:upper() then
				return {}
			end
		end
	end
	return index.completion_items(prefix, opts)
end

function SapSource:get_completions(context, callback)
	local bufnr = context.bufnr or vim.api.nvim_get_current_buf()
	local row = (context.cursor and context.cursor[1]) or vim.api.nvim_win_get_cursor(0)[1]
	local col = (context.cursor and context.cursor[2]) or vim.api.nvim_win_get_cursor(0)[2]

	local cached = indexed_items(bufnr, row, col)
	if #cached > 0 then
		local completions = {}
		for _, it in ipairs(cached) do
			local kind = Kind.Text
			local sort = "05"
			if it.kind == "2" then
				kind = Kind.Class
			elseif it.kind == "1" then
				kind = Kind.Field or Kind.Variable
				sort = "00"
			elseif it.kind == "3" then
				kind = Kind.Method
				sort = "10"
			elseif it.kind == "4" or it.kind == "6" then
				kind = Kind.Function
				sort = "15"
			end
			table.insert(completions, {
				label = it.word,
				kind = kind,
				detail = it.detail or "SAP index",
				filterText = it.word,
				sortText = sort .. "_INDEX_" .. it.word,
			})
		end
		callback({
			is_incomplete_forward = false,
			is_incomplete_backward = false,
			items = completions,
		})
		return
	end

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
