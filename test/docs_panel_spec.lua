-- Offline regression test for SAP Help panel sections, favorites and history.

vim.env.XDG_STATE_HOME = "/tmp/sap-nvim-docs-panel-test-" .. tostring(vim.fn.getpid())
vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

local state_root = vim.fn.stdpath("state")
vim.fn.delete(state_root .. "/sap-nvim", "rf")

local docs = require("sap-nvim.core.docs")
require("sap-nvim.core.config").setup({
	docs = {
		always_show_api_hub = true,
		history_limit = 3,
		favorite_limit = 3,
	},
})

local xml = table.concat({
	'<adtcore:objectReference adtcore:name="CL_DEMO" adtcore:type="CLAS/OC" adtcore:description="Demo &amp; Test" adtcore:uri="/sap/bc/adt/oo/classes/cl_demo"/>',
	'<adtcore:objectReference adtcore:name="CL_DEMO" adtcore:type="CLAS/OC" adtcore:description="Duplicate" adtcore:uri="/sap/bc/adt/oo/classes/cl_demo"/>',
	'<adtcore:objectReference adtcore:name="Z_FM" adtcore:type="FUNC/FF" adtcore:description="Function" adtcore:uri="/sap/bc/adt/functions/groups/zfg/fmodules/z_fm"/>',
}, "")

local rows = docs._test.parse_search_body(xml)
if #rows ~= 2 then
	error("expected 2 unique ADT rows, got " .. tostring(#rows))
end
if rows[1].desc ~= "Demo & Test" then
	error("XML entities were not decoded")
end
if docs._test.fgroup_from_uri(rows[2].uri) ~= "zfg" then
	error("function group was not derived from ADT URI")
end

docs._test.record_history("CL_DEMO", "class")
docs._test.record_history("BAPI_USER_GET_DETAIL", "function")
docs._test.record_history("CL_DEMO", "class")
docs._test.favorite_query("CL_DEMO")
docs._test.favorite_row(rows[2], "Z_FM")

local store = docs._test.load_store()
if #store.history ~= 2 or store.history[1].query ~= "CL_DEMO" then
	error("history was not deduplicated with most recent first")
end
if #store.favorites ~= 2 or store.favorites[1].name ~= "Z_FM" then
	error("favorites were not persisted with ADT results")
end

local base_state = {
	query = "CL_DEMO",
	kind = "all",
	rows = rows,
	status = "offline",
	filter = nil,
	all_types = true,
	section = "docs",
	rerender = function() end,
}

local docs_lines = docs._test.build_lines(base_state)
if not table.concat(docs_lines, "\n"):find("%[1 Docs%].-2 ADT.-3 Favoritos.-4 Historial") then
	error("section tabs were not rendered")
end

base_state.section = "adt"
local adt_lines, adt_actions, adt_items = docs._test.build_lines(base_state)
local adt_text = table.concat(adt_lines, "\n")
if not adt_text:find("CL_DEMO") or not adt_text:find("Z_FM") then
	error("ADT rows were not rendered")
end
local has_adt_item = false
for lnum, item in pairs(adt_items) do
	if item.kind == "adt" and item.row.name == "Z_FM" and type(adt_actions[lnum]) == "function" then
		has_adt_item = true
	end
end
if not has_adt_item then
	error("ADT row action metadata was not attached")
end

base_state.section = "favorites"
local fav_lines = docs._test.build_lines(base_state)
local fav_text = table.concat(fav_lines, "\n")
if not fav_text:find("Z_FM") or not fav_text:find("CL_DEMO") then
	error("favorites section did not include saved query and result")
end

base_state.section = "history"
local hist_lines = docs._test.build_lines(base_state)
if not table.concat(hist_lines, "\n"):find("BAPI_USER_GET_DETAIL") then
	error("history section did not include saved searches")
end

print("DOCS_PANEL_OK")
