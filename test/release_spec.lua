-- Offline regression test for release assistant checklist. No SAP connection required.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg) print(msg) end

local transport = require("sap-nvim.core.transport")
local release = require("sap-nvim.core.release")

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local function assert_true(value, msg)
  if not value then error(msg) end
end

assert_eq(release._parse_transport_id("S4HK900001"), "S4HK900001", "transport id parser accepts bare id")
assert_eq(release._parse_transport_id("release S4HK900001 now"), "S4HK900001", "transport id parser extracts id from args")
assert_eq(release._parse_transport_id("ps-prac_final_fact_jcg"), nil, "transport id parser rejects descriptions")

local report = transport._parse_transport_detail("S4HK900001", {
  "Transport S4HK900001 Owner: DEV Status: D Target: QAS",
  "Task S4HK900002 Owner: DEV Status: D",
  "Task S4HK900003 Owner: DEV Status: R",
  "R3TR PROG ZREP_ONE Package: ZPKG_MAIN Target: QAS ActiveState: active",
  "R3TR CLAS ZCL_INACTIVE Package: ZPKG_MAIN Target: QAS ActiveState: inactive",
})
report.locks = { { object = "R3TR CLAS ZCL_INACTIVE", owner = "DEV", status = "enqueue" } }

local lines = release._build_checklist(report, {
  consistency = {
    available = true,
    ok = false,
    code = 200,
    endpoint = "/sap/bc/adt/cts/transportrequests/S4HK900001/consistencychecks",
    errors = 1,
    warnings = 1,
    messages = {
      { severity = "E", text = "Object inactive", object = "ZCL_INACTIVE" },
    },
  },
  quality = {
    source = "quality history",
    summary = { errors = 0, warnings = 1, info = 0, total = 1 },
    detail = "ATC warning kept for review",
  },
  check_consistency = false,
})
local rendered = table.concat(lines, "\n")

assert_true(rendered:find("SAP Release Assistant", 1, true), "checklist title is rendered")
assert_true(rendered:find("Read-only checklist", 1, true), "checklist states read-only")
assert_true(rendered:find("TRKORR      : S4HK900001", 1, true), "checklist includes order")
assert_true(rendered:find("Owner       : DEV", 1, true), "checklist includes owner")
assert_true(rendered:find("Target      : QAS", 1, true), "checklist includes target")
assert_true(rendered:find("[BLOCK] Open tasks: 1/2", 1, true), "checklist blocks open tasks")
assert_true(rendered:find("[BLOCK] Inactive objects: 1", 1, true), "checklist blocks inactive objects")
assert_true(rendered:find("ATC/quality from quality history", 1, true), "checklist includes quality data")
assert_true(rendered:find("ADT consistency", 1, true), "checklist includes ADT consistency")
assert_true(rendered:find("Locks / Status", 1, true), "checklist includes locks/status section")
assert_true(rendered:find("Release Order", 1, true), "checklist includes release order section")
assert_true(rendered:find("Fix BLOCK items first", 1, true), "checklist includes next action")

vim.fn.setqflist({}, "r", {
  title = "ATC transport S4HK900001",
  items = {
    { filename = "ZREP_ONE", lnum = 1, col = 1, type = "W", text = "warning" },
  },
})
local snapshot = release._current_quality_snapshot("S4HK900001")
assert_eq(snapshot.summary.warnings, 1, "quality snapshot reads ATC quickfix warnings")

release.setup()
assert_eq(vim.fn.exists(":SapReleaseAssistant"), 2, "SapReleaseAssistant command exists")
assert_true(vim.fn.maparg("<leader>atR", "n") ~= "", "release assistant keymap exists")

print("RELEASE_SPEC_OK")
