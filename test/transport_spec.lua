-- Offline regression test for transport cockpit parsing and safe release gates.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
	print(msg)
end

local transport = require("sap-nvim.core.transport")

local function assert_eq(actual, expected, msg)
	if actual ~= expected then
		error(msg .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
	end
end

local function assert_true(value, msg)
	if not value then
		error(msg)
	end
end

local report = transport._parse_transport_detail("S4HK900001", {
	"Transport S4HK900001 Owner: DEVELOPER Status: D Target: QAS",
	"Task S4HK900002 Owner: REVIEWER Status: D",
	"R3TR PROG ZREP_ONE Package: ZPKG_MAIN Target: QAS",
	"LIMU REPS ZREP_ONE_TOP Package: ZPKG_MAIN Target: QAS",
	"R3TR CLAS ZCL_ONE Package: ZPKG_MAIN Target: QAS",
})

assert_eq(report.id, "S4HK900001", "transport id is preserved")
assert_eq(report.owner, "DEVELOPER", "owner is parsed")
assert_eq(report.status, "D", "status is parsed")
assert_eq(#report.tasks, 1, "task is parsed")
assert_eq(report.tasks[1].id, "S4HK900002", "task id is parsed")
assert_eq(#report.objects, 3, "objects are parsed")
assert_eq(report.objects[1].uri, "/sap/bc/adt/programs/programs/zrep_one", "program URI is derived")
assert_eq(report.objects[2].uri, "/sap/bc/adt/programs/includes/zrep_one_top", "include URI is derived")
assert_eq(report.blocking, true, "open task blocks readiness in safe_mode")
assert_eq(report.readiness.ok, false, "readiness exposes blocking state")

local ready = transport._parse_transport_detail("S4HK900003", {
	"Transport S4HK900003 Owner: DEVELOPER Status: D Target: QAS",
	"Task S4HK900004 Owner: REVIEWER Status: R",
	"R3TR PROG ZREP_READY Package: ZPKG_MAIN Target: QAS",
})
assert_eq(ready.blocking, false, "released tasks with single package/target are ready")
assert_eq(ready.readiness.ok, true, "ready transport exposes ok readiness")

local mixed_pkg = transport._analyze_transport_report({
	id = "S4HK900010",
	status = "D",
	objects = {
		{ pgmid = "R3TR", object = "PROG", name = "ZREP_A", package = "ZPKG_A", target = "QAS" },
		{ pgmid = "R3TR", object = "CLAS", name = "ZCL_B", package = "ZPKG_B", target = "QAS" },
	},
	tasks = {},
}, { safe_mode = true })
assert_eq(mixed_pkg.blocking, true, "mixed packages block release in safe_mode")
assert_true(mixed_pkg.warnings[1].text:find("mezcla paquetes", 1, true), "mixed package warning is explicit")

local mixed_pkg_relaxed = transport._analyze_transport_report({
	id = "S4HK900011",
	status = "D",
	objects = {
		{ pgmid = "R3TR", object = "PROG", name = "ZREP_A", package = "ZPKG_A", target = "QAS" },
		{ pgmid = "R3TR", object = "CLAS", name = "ZCL_B", package = "ZPKG_B", target = "QAS" },
	},
	tasks = {},
}, { safe_mode = false })
assert_eq(mixed_pkg_relaxed.blocking, false, "mixed packages warn but do not block when safe_mode is disabled")

local mixed_target = transport._analyze_transport_report({
	id = "S4HK900012",
	status = "D",
	objects = {
		{ pgmid = "R3TR", object = "PROG", name = "ZREP_A", package = "ZPKG_A", target = "QAS" },
		{ pgmid = "R3TR", object = "CLAS", name = "ZCL_B", package = "ZPKG_A", target = "PRD" },
	},
	tasks = {},
}, { safe_mode = true })
assert_eq(mixed_target.blocking, true, "mixed targets block release in safe_mode")
assert_true(mixed_target.warnings[2].text:find("productivo", 1, true), "productive target warning is explicit")

local xml_report = transport._parse_transport_detail("S4HK900020", {
	'<tm:request tm:number="S4HK900020" tm:status="D" tm:owner="DEV" tm:desc="Main" tm:target="QAS">',
	'<tm:request tm:number="S4HK900021" tm:status="R" tm:owner="DEV" tm:type="task"/>',
	'<tm:object tm:pgmid="R3TR" tm:object="DDLS" tm:name="ZC_DEMO" tm:devclass="ZPKG_MAIN" tm:target="QAS" tm:activeState="inactive" tm:uri="/sap/bc/adt/ddic/ddl/sources/zc_demo"/>',
	"</tm:request>",
})
assert_eq(xml_report.owner, "DEV", "ADT XML owner is parsed")
assert_eq(#xml_report.tasks, 1, "ADT XML task is parsed")
assert_eq(#xml_report.objects, 1, "ADT XML object is parsed")
assert_eq(xml_report.objects[1].uri, "/sap/bc/adt/ddic/ddl/sources/zc_demo", "ADT XML object URI is preserved")
assert_eq(xml_report.objects[1].active_state, "inactive", "ADT XML inactive state is parsed")
assert_eq(#xml_report.inactive_objects, 1, "inactive object list is built")
assert_eq(xml_report.blocking, true, "inactive objects block readiness")

local text_inactive = transport._parse_transport_detail("S4HK900030", {
	"Transport S4HK900030 Owner: DEV Status: D Target: QAS",
	"R3TR CLAS ZCL_INACTIVE Package: ZPKG_MAIN Target: QAS ActiveState: inactive",
})
assert_eq(text_inactive.objects[1].active_state, "inactive", "text inactive state is parsed")

local readiness, analyzed = transport._readiness({
	id = "S4HK900040",
	status = "D",
	objects = {
		{ pgmid = "R3TR", object = "PROG", name = "ZREP_READY", package = "ZPKG_MAIN", target = "QAS" },
	},
	tasks = {},
}, { safe_mode = true })
assert_eq(readiness.ok, true, "readiness helper returns ok")
assert_eq(analyzed.blocking, false, "readiness helper returns analyzed report")

local diff = transport._compare_transport_reports({
	id = "S4HK900050",
	objects = {
		{ pgmid = "R3TR", object = "PROG", name = "ZREP_A", package = "ZPKG_A", target = "QAS" },
		{ pgmid = "R3TR", object = "CLAS", name = "ZCL_COMMON", package = "ZPKG_A", target = "QAS" },
	},
}, {
	id = "S4HK900051",
	objects = {
		{ pgmid = "R3TR", object = "CLAS", name = "ZCL_COMMON", package = "ZPKG_B", target = "QAS" },
		{ pgmid = "R3TR", object = "DDLS", name = "ZC_ONLY_RIGHT", package = "ZPKG_B", target = "QAS" },
	},
})
assert_eq(#diff.only_left, 1, "compare finds left-only object")
assert_eq(#diff.only_right, 1, "compare finds right-only object")
assert_eq(#diff.common, 1, "compare finds common object")
assert_eq(#diff.changed, 1, "compare finds package/target changes")

os.remove(transport._history_path())
transport._record_history("readiness", "S4HK900060", "ok", "test")
local history = transport._read_history()
assert_eq(#history, 1, "history persists one entry")
assert_eq(history[1].action, "readiness", "history action is persisted")
assert_eq(history[1].transport, "S4HK900060", "history transport is persisted")

transport.setup()
assert_eq(vim.fn.exists(":SapTransports"), 2, "SapTransports command exists")
assert_eq(vim.fn.exists(":SapTransportReadiness"), 2, "SapTransportReadiness command exists")
assert_eq(vim.fn.exists(":SapTransportCompare"), 2, "SapTransportCompare command exists")
assert_eq(vim.fn.exists(":SapTransportHistory"), 2, "SapTransportHistory command exists")

print("TRANSPORT_SPEC_OK")
