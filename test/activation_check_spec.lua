-- Offline regression test for recursive activation pre-check helpers.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

local adt = require("sap-nvim.core.adt")

local objects = {
	{
		name = "ZMAIN",
		group = "program",
		uri = "/sap/bc/adt/programs/programs/zmain",
		source_lines = {
			"REPORT zmain.",
			"INCLUDE zinc.",
			"SELECT * FROM ztab INTO TABLE @DATA(lt_tab).",
		},
		filename = "/tmp/zmain.prog.abap",
	},
	{
		name = "ZTAB",
		group = "table",
		uri = "/sap/bc/adt/ddic/tables/ztab",
		filename = "/tmp/ztab.tabl.xml",
	},
	{
		name = "ZINC",
		group = "include",
		uri = "/sap/bc/adt/programs/includes/zinc",
		source_lines = { "WRITE ztab-field.", "WRITE 'ZBROKEN'." },
		filename = "/tmp/zinc.abap",
	},
	{
		name = "ZC_TOP",
		group = "ddls",
		uri = "/sap/bc/adt/ddic/ddl/sources/zc_top",
		source_lines = {
			"define view entity ZC_TOP",
			"  as select from ztab",
			"    association to ZC_BASE as _Base on $projection.id = _Base.id",
		},
		filename = "/tmp/zc_top.ddls",
	},
	{
		name = "ZC_BASE",
		group = "ddls",
		uri = "/sap/bc/adt/ddic/ddl/sources/zc_base",
		source_lines = { "define view entity ZC_BASE as select from ztab { key id }" },
		filename = "/tmp/zc_base.ddls",
	},
}

local sorted = adt._sort_activation_objects(objects)
local pos = {}
for i, obj in ipairs(sorted) do
	pos[obj.name] = i
end

if not (pos.ZTAB < pos.ZMAIN) then
	error("table dependency was not ordered before program")
end
if not (pos.ZINC < pos.ZMAIN) then
	error("include dependency was not ordered before program")
end
if not (pos.ZC_BASE < pos.ZC_TOP) then
	error("CDS dependency was not ordered before dependent CDS")
end

local body = table.concat({
	'<chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun">',
	'<chkrun:checkMessage chkrun:uri="/sap/bc/adt/programs/includes/zinc/source/main#start=7,3" chkrun:type="E" chkrun:shortText="Include broken"/>',
	'<chkrun:checkMessage chkrun:uri="/sap/bc/adt/ddic/ddl/sources/zc_top/source/main#start=4,1" chkrun:type="W" chkrun:shortText="CDS warning"/>',
	'<chkrun:checkMessage chkrun:uri="/sap/bc/adt/ddic/tables/ztab#start=1,1" chkrun:type="E" chkrun:shortText="Table broken"/>',
	'<chkrun:checkMessage chkrun:uri="/sap/bc/adt/programs/includes/zinc/source/main" chkrun:type="E" chkrun:shortText="Token &quot;ZBROKEN&quot; is invalid"/>',
	"</chkrun:checkObjectList>",
}, "")

local qf = adt._parse_checkrun_response(body, objects, { filename = "/tmp/current.abap" })
if #qf ~= 4 then
	error("expected 4 quickfix entries, got " .. tostring(#qf))
end
if not qf[1].text:find("ZINC %[include%]: Include broken") then
	error("include check message lost object context: " .. tostring(qf[1].text))
end
if qf[1].module ~= "ZINC [include]" then
	error("quickfix entry lost module grouping")
end
if not qf[2].text:find("Token \"ZBROKEN\" is invalid") or qf[2].lnum ~= 2 then
	error("check message without start did not infer source line")
end
if not qf[3].text:find("ZTAB %[table%]: Table broken") then
	error("table check message lost object context: " .. tostring(qf[2].text))
end
if not qf[4].text:find("ZC_TOP %[ddls%]: CDS warning") or qf[4].type ~= "W" then
	error("CDS warning was not parsed after errors")
end

local paused = adt._activation_block_message({
	ready = function()
		return false
	end,
	needs_login = function()
		return true
	end,
})
if not paused:find("pausada tras 401", 1, true) then
	error("paused session block message is not explicit: " .. tostring(paused))
end

local not_available = adt._activation_block_message({
	ready = function()
		return true
	end,
	is_available = function()
		return false
	end,
})
if not not_available:find("ADT no disponible", 1, true) then
	error("ADT unavailable block message missing")
end

print("ACTIVATION_CHECK_OK")
