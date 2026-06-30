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

local adt_tree_report = transport._parse_transport_detail("S4FK901640", {
	'<tm:request tm:number="S4FK901640" tm:owner="SEIJC2" tm:desc="ps-prac_final_fact_jcg" tm:type="K" tm:status="D" tm:target="">',
	'<atom:link atom:rel="http://www.sap.com/adt/relations/consistencychecks" atom:href="/sap/bc/adt/cts/transportrequests/S4FK901640/consistencychecks"/>',
	'<atom:link atom:rel="http://www.sap.com/adt/relations/releasejobs" atom:href="/sap/bc/adt/cts/transportrequests/S4FK901640/releasejobs"/>',
	'<tm:task tm:number="S4FK901641" tm:parent="S4FK901640" tm:owner="SEIJC2" tm:desc="" tm:status="D">',
	'<tm:abap_object tm:pgmid="R3TR" tm:type="PROG" tm:name="ZCAR_PRACFINAL_JCG" tm:obj_desc="Programa" tm:position="000001"/>',
	'<tm:abap_object tm:pgmid="R3TR" tm:type="DDLS" tm:name="ZCDS_CARGA_JCG" tm:obj_desc="CDS" tm:position="000002"/>',
	"</tm:task>",
	"</tm:request>",
})
assert_eq(adt_tree_report.owner, "SEIJC2", "ADT tree transport owner is parsed")
assert_eq(#adt_tree_report.tasks, 1, "ADT tree task is parsed")
assert_eq(#adt_tree_report.objects, 2, "ADT tree abap_object entries are parsed")
assert_eq(adt_tree_report.objects[2].object, "DDLS", "ADT tree object type is parsed")
local adt_links = transport._parse_adt_links(table.concat(adt_tree_report.lines, "\n"))
assert_eq(#adt_links, 2, "ADT link parser finds atom links")
assert_eq(transport._consistency_paths(adt_tree_report)[1], "/sap/bc/adt/cts/transportrequests/S4FK901640/consistencychecks", "consistency link path is preferred")
assert_eq(transport._release_job_paths(adt_tree_report)[1], "/sap/bc/adt/cts/transportrequests/S4FK901640/releasejobs", "releasejobs link path is preferred")

local consistency = transport._parse_transport_consistency_result(
	'<tm:consistencyChecks><tm:message tm:severity="W" tm:shortText="Task still open"/><tm:message tm:severity="E" tm:shortText="Object inactive"/></tm:consistencyChecks>',
	200,
	"/sap/bc/adt/cts/transportrequests/S4FK901640/consistencychecks",
	"POST"
)
assert_eq(consistency.ok, false, "consistency result blocks on error severity")
assert_eq(consistency.errors, 1, "consistency parser counts errors")
assert_eq(consistency.warnings, 1, "consistency parser counts warnings")
local consistency_lines = transport._consistency_lines(consistency, { { method = "GET", path = consistency.endpoint, code = 405 }, { method = "POST", path = consistency.endpoint, code = 200 } })
assert_true(consistency_lines[2]:find("HTTP 200", 1, true), "consistency panel includes HTTP status")
assert_true(table.concat(consistency_lines, "\n"):find("Object inactive", 1, true), "consistency panel includes messages")

local release_jobs = transport._parse_release_jobs(
	'<tm:releaseJobs><tm:releaseJob tm:id="JOB_1" tm:status="scheduled" tm:user="DEV" tm:text="Release simulation"/><tm:message tm:severity="I" tm:shortText="Read only"/></tm:releaseJobs>',
	200,
	"/sap/bc/adt/cts/transportrequests/S4FK901640/releasejobs"
)
assert_eq(release_jobs.ok, true, "releasejobs parser accepts 2xx")
assert_eq(#release_jobs.jobs, 1, "releasejobs parser finds jobs")
assert_eq(release_jobs.jobs[1].status, "scheduled", "releasejobs parser reads status")
assert_true(table.concat(transport._release_job_lines({ release_jobs }), "\n"):find("no ejecuta release", 1, true), "releasejobs panel states it is read-only")

local text_inactive = transport._parse_transport_detail("S4HK900030", {
	"Transport S4HK900030 Owner: DEV Status: D Target: QAS",
	"R3TR CLAS ZCL_INACTIVE Package: ZPKG_MAIN Target: QAS ActiveState: inactive",
})
assert_eq(text_inactive.objects[1].active_state, "inactive", "text inactive state is parsed")

local sapcli_recursive = transport._parse_transport_detail("S4FK901640", {
	"S4FK901640 D SEIJC2 ps-prac_final_fact_jcg",
	"  S4FK901641 D SEIJC2",
	"    PROG ZCAR_PRACFINAL_JCG",
	"    DDLS ZCDS_CARGA_JCG",
})
assert_eq(sapcli_recursive.owner, "SEIJC2", "sapcli positional transport owner is parsed")
assert_eq(sapcli_recursive.status, "D", "sapcli positional transport status is parsed")
assert_eq(sapcli_recursive.desc, "ps-prac_final_fact_jcg", "sapcli positional transport description is parsed")
assert_eq(#sapcli_recursive.tasks, 1, "sapcli recursive task is parsed")
assert_eq(sapcli_recursive.tasks[1].owner, "SEIJC2", "sapcli positional task owner is parsed")
assert_eq(#sapcli_recursive.objects, 2, "sapcli -r -r objects are parsed")
assert_eq(sapcli_recursive.objects[1].object, "PROG", "sapcli two-column object type is parsed")
assert_eq(sapcli_recursive.objects[1].name, "ZCAR_PRACFINAL_JCG", "sapcli two-column object name is parsed")

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

assert_eq(transport._object_group({ pgmid = "R3TR", object = "PROG", name = "ZREP" }), "program", "R3TR PROG maps to program")
assert_eq(transport._object_group({ pgmid = "LIMU", object = "REPS", name = "ZINC" }), "include", "LIMU REPS maps to include")
assert_eq(transport._object_group({ pgmid = "R3TR", object = "DDLS", name = "ZC_DEMO" }), "ddls", "DDLS maps to ddls")
assert_eq(
	transport._object_source_uri({ pgmid = "R3TR", object = "CLAS", name = "ZCL_ONE" }),
	"/sap/bc/adt/oo/classes/zcl_one/source/main",
	"class source URI is derived"
)

local filtered = transport._filter_transport_objects(report, "prog zpkg_main")
assert_eq(#filtered, 1, "object filter combines tokens")
assert_eq(filtered[1].name, "ZREP_ONE", "object filter returns matching program")
local object_lines = transport._object_list_lines(report, "clas")
assert_true(object_lines[1]:find("S4HK900001", 1, true), "object list includes transport id")
assert_true(object_lines[5]:find("ZCL_ONE", 1, true), "object list includes filtered object")

local add_missing = transport._transport_add_user_plan("", "DEV")
assert_eq(add_missing.reason, "missing_id", "add-user plan validates missing id")
local add_invalid = transport._transport_add_user_plan("ps-prac_final_fact_jcg", "DEV")
assert_eq(add_invalid.reason, "invalid_id", "add-user plan rejects transport descriptions as id")
local add_unsupported = transport._transport_add_user_plan("S4HK900001", "DEV2")
assert_eq(add_unsupported.executable, false, "add-user plan is safe by default")
assert_true(
	add_unsupported.reason == "opt_in_required" or add_unsupported.reason == "not_ready",
	"add-user plan reports a safe non-executable reason"
)
local new_task_default = transport._transport_new_task_plan("S4HK900001", "DEV2")
assert_eq(new_task_default.executable, false, "new task POST is opt-in by default")
assert_eq(new_task_default.reason, "opt_in_required", "new task plan requires explicit opt-in before ADT writes")
local task_xml = transport._task_xml("S4HK900001", "DEV2")
assert_true(task_xml:find('xmlns:tm="http://www.sap.com/cts/adt/tm"', 1, true), "new task payload uses CTS ADT namespace")
assert_true(task_xml:find('tm:useraction="newtask"', 1, true), "new task payload uses newtask action")
assert_true(task_xml:find('tm:targetuser="DEV2"', 1, true), "new task payload carries target user")

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
assert_eq(vim.fn.exists(":SapTransportObjects"), 2, "SapTransportObjects command exists")
assert_eq(vim.fn.exists(":SapTransportOpenObject"), 2, "SapTransportOpenObject command exists")
assert_eq(vim.fn.exists(":SapTransportObjectDiff"), 2, "SapTransportObjectDiff command exists")
assert_eq(vim.fn.exists(":SapTransportGui"), 2, "SapTransportGui command exists")
assert_eq(vim.fn.exists(":SapTransportAddUser"), 2, "SapTransportAddUser command exists")
assert_eq(vim.fn.exists(":SapTransportNewTask"), 2, "SapTransportNewTask command exists")
assert_eq(vim.fn.exists(":SapTransportConsistency"), 2, "SapTransportConsistency command exists")
assert_eq(vim.fn.exists(":SapTransportReleaseJobs"), 2, "SapTransportReleaseJobs command exists")
assert_eq(vim.fn.exists(":SapTransportActions"), 2, "SapTransportActions command exists")
assert_true(type(transport.fetch_transport_report) == "function", "transport report fetcher is exported for read-only consumers")

print("TRANSPORT_SPEC_OK")
