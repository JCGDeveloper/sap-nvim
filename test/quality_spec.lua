-- Offline regression test for quality parsers/history. No SAP connection required.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg) print(msg) end

local quality = require("sap-nvim.core.quality")
local aunit = require("sap-nvim.core.aunit")

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local atc = quality._parse_atc_output({
  "-- Class ZCL_DEMO",
  "zcl_demo.clas.abap:12:5: E: SELECT * is not allowed",
  "W: Method too long",
}, { filename = "/tmp/zcl_demo.clas.abap" })

assert_eq(#atc, 2, "ATC parser returns two quickfix entries")
assert_eq(atc[1].lnum, 12, "ATC parser keeps line")
assert_eq(atc[1].col, 5, "ATC parser keeps column")
assert_eq(atc[1].type, "E", "ATC parser keeps severity")
assert_eq(atc[2].type, "W", "ATC parser keeps warning severity")

local summary = quality._summarize_qf(atc)
assert_eq(summary.errors, 1, "summary counts errors")
assert_eq(summary.warnings, 1, "summary counts warnings")

local serialized = quality._serialize_findings(atc)
assert_eq(#serialized, 2, "ATC findings serialize for history/worklist")
assert_eq(#quality._filter_findings(serialized, "errors"), 1, "ATC worklist filters errors")
assert_eq(#quality._filter_findings(serialized, "warnings"), 1, "ATC worklist filters warnings")
local worklist_lines = table.concat(quality._worklist_lines(serialized, { source = "quickfix", filter = "all" }), "\n")
if not worklist_lines:find("SAP ATC Worklist", 1, true) then error("ATC worklist title missing") end
if not worklist_lines:find("SELECT * is not allowed", 1, true) then error("ATC worklist finding missing") end
local help_lines = table.concat(quality._finding_help_lines({
  text = "Check ID: SELECT_STAR https://example.invalid/check",
  check = "SELECT_STAR",
}), "\n")
if not help_lines:find("SELECT_STAR", 1, true) then error("ATC help should include check id") end
if not help_lines:find("https://example.invalid/check", 1, true) then error("ATC help should include URL") end

local atc_doc = quality._parse_atc_output({
  "Check ID: SECURITY.SELECT_STAR",
  "zcl_demo.clas.abap:21:3: W: Avoid SELECT * https://example.invalid/atc/select-star",
  "Documentation: Replace SELECT * with the required field list.",
}, { filename = "/tmp/zcl_demo.clas.abap" })
assert_eq(#atc_doc, 1, "ATC parser returns documented finding")
assert_eq(atc_doc[1].user_data.check_id, "SECURITY.SELECT_STAR", "ATC parser keeps check id")
assert_eq(atc_doc[1].user_data.help_url, "https://example.invalid/atc/select-star", "ATC parser keeps help url")
assert_eq(atc_doc[1].user_data.help_text, "Replace SELECT * with the required field list.", "ATC parser keeps help text")

local warnings = quality._filter_findings(atc, "warnings")
assert_eq(#warnings, 1, "ATC worklist filter keeps warnings only")
assert_eq(warnings[1].type, "W", "ATC worklist warning severity")

local worklist_lines, worklist_rows, worklist_filtered = quality._worklist_lines(atc_doc, {
  source = "quickfix",
  filter = "warnings",
})
assert_eq(worklist_lines[1], "SAP ATC Worklist", "ATC worklist renders title")
assert_eq(#worklist_filtered, 1, "ATC worklist renders filtered findings")
assert_eq(worklist_rows[8], 1, "ATC worklist maps finding line to item index")

local help_lines = table.concat(quality._finding_help_lines(atc_doc[1]), "\n")
if not help_lines:match("SECURITY%.SELECT_STAR") then error("ATC help should include check id") end
if not help_lines:match("https://example%.invalid/atc/select%-star") then error("ATC help should include URL") end
if not help_lines:match("Replace SELECT") then error("ATC help should include help text") end

local reporters = quality._parse_reporters([[
<chkrun:checkReporters xmlns:chkrun="http://www.sap.com/adt/checkrun">
  <chkrun:reporter chkrun:id="abapCheckRun" chkrun:name="ABAP Check Run"/>
  <chkrun:reporter id="atc" name="ATC"/>
</chkrun:checkReporters>
]])
assert_eq(#reporters, 2, "ATC reporters parser returns reporters")
assert_eq(reporters[1].id, "abapCheckRun", "ATC reporters parser keeps id")

local remote_qf = quality._parse_atc_worklist_response([[
<atcworklist:worklist xmlns:atcworklist="http://www.sap.com/adt/atc/worklist">
  <atcworklist:object atcworklist:name="ZCL_DEMO" atcworklist:type="CLAS/OC" atcworklist:uri="/sap/bc/adt/oo/classes/zcl_demo">
    <atcworklist:finding atcworklist:uri="/sap/bc/adt/atc/findings/1" atcworklist:location="/sap/bc/adt/oo/classes/zcl_demo/source/main#start=7,2" atcworklist:priority="2" atcworklist:checkId="SECURITY.SELECT_STAR" atcworklist:checkTitle="SELECT star" atcworklist:messageTitle="Avoid SELECT *">
      <atom:link xmlns:atom="http://www.w3.org/2005/Atom" rel="documentation" href="/sap/bc/adt/atc/documentation/SECURITY.SELECT_STAR"/>
    </atcworklist:finding>
  </atcworklist:object>
</atcworklist:worklist>
]])
assert_eq(#remote_qf, 1, "ATC remote worklist parser returns finding")
assert_eq(remote_qf[1].type, "W", "ATC remote worklist maps priority to warning")
assert_eq(remote_qf[1].lnum, 7, "ATC remote worklist keeps line")
assert_eq(remote_qf[1].user_data.check_id, "SECURITY.SELECT_STAR", "ATC remote worklist keeps check id")
assert_eq(remote_qf[1].user_data.doc_uri, "/sap/bc/adt/atc/documentation/SECURITY.SELECT_STAR", "ATC remote worklist keeps doc uri")

local run_info = quality._parse_atc_run_info({
  '<atcworklist:worklist atcworklist:worklistId="WL-123" atcworklist:timestamp="20260629120000"/>',
})
assert_eq(run_info.id, "WL-123", "ATC run parser keeps worklist id")
assert_eq(run_info.timestamp, "20260629120000", "ATC run parser keeps timestamp")
local remote_req = quality._remote_worklist_request({ id = "WL-123", timestamp = "20260629120000" })
assert_eq(remote_req.path, "/sap/bc/adt/atc/worklists/WL-123", "ATC remote worklist request path")
assert_eq(remote_req.query.timestamp, "20260629120000", "ATC remote worklist request timestamp")

local doc_req = quality._remote_doc_request(remote_qf[1])
assert_eq(doc_req.path, "/sap/bc/adt/atc/documentation/SECURITY.SELECT_STAR", "ATC doc request uses ADT URI")
local doc_lines = table.concat(quality._finding_doc_lines(remote_qf[1], "<html><body><p>Use explicit fields.</p></body></html>"), "\n")
if not doc_lines:find("Use explicit fields.", 1, true) then error("ATC doc lines should include remote text") end

local validation_lines = table.concat(quality._remote_validation_lines({
  reporters_code = 200,
  reporters = reporters,
  checkrun_code = 200,
  object_uri = "/sap/bc/adt/oo/classes/zcl_demo",
  qf = remote_qf,
}), "\n")
if not validation_lines:find("/sap/bc/adt/checkruns/reporters", 1, true) then error("ATC validation lines should include reporters route") end
if not validation_lines:find("/sap/bc/adt/checkruns?reporters=abapCheckRun", 1, true) then error("ATC validation lines should include checkrun route") end

local failures = aunit._parse_junit4([[
<testsuite tests="2" failures="1" errors="0" skipped="0">
  <testcase classname="ZCL_DEMO" name="test_one">
    <failure message="expected true">Line 42</failure>
  </testcase>
</testsuite>
]])
assert_eq(#failures, 1, "AUnit parser returns one failure")
assert_eq(failures[1].class, "ZCL_DEMO", "AUnit parser keeps class")
assert_eq(failures[1].line, 42, "AUnit parser extracts line")

os.remove(quality._history_path())
os.remove(quality._settings_path())
quality._record_history({ kind = "ATC", scope = "object", target = "ZCL_DEMO", status = "ok", errors = 0, warnings = 0 })
quality._record_history({
  kind = "ATC",
  scope = "object",
  target = "ZCL_DEMO",
  status = "issues",
  errors = 0,
  warnings = 1,
  findings = quality._serialize_findings(atc_doc),
})
local history = quality._read_history()
assert_eq(#history, 2, "quality history persists entries")
assert_eq(history[1].target, "ZCL_DEMO", "quality history keeps target")
assert_eq(#history[2].findings, 1, "quality history keeps serialized findings")

quality.setup()
assert_eq(vim.fn.exists(":SapQuality"), 2, "SapQuality command exists")
assert_eq(vim.fn.exists(":SapAUnitPanel"), 2, "SapAUnitPanel command exists")
assert_eq(vim.fn.exists(":SapAtcPanel"), 2, "SapAtcPanel command exists")
assert_eq(vim.fn.exists(":SapQualityHistory"), 2, "SapQualityHistory command exists")
assert_eq(vim.fn.exists(":SapAtcWorklist"), 2, "SapAtcWorklist command exists")
assert_eq(vim.fn.exists(":SapAtcRemoteWorklist"), 2, "SapAtcRemoteWorklist command exists")
assert_eq(vim.fn.exists(":SapAtcFilter"), 2, "SapAtcFilter command exists")
assert_eq(vim.fn.exists(":SapAtcHelp"), 2, "SapAtcHelp command exists")
assert_eq(vim.fn.exists(":SapAtcDoc"), 2, "SapAtcDoc command exists")
assert_eq(vim.fn.exists(":SapAtcRoutes"), 2, "SapAtcRoutes command exists")
assert_eq(vim.fn.exists(":SapAtcRequestExemption"), 2, "SapAtcRequestExemption command exists")

vim.fn.setqflist({}, "r", { items = atc_doc, title = "ATC test" })
local qf_worklist = quality.show_worklist("quickfix warnings")
local rendered_qf = table.concat(vim.api.nvim_buf_get_lines(qf_worklist, 0, -1, false), "\n")
if not rendered_qf:match("Source%s+:%s+quickfix") then error("ATC worklist should render quickfix source") end
if not rendered_qf:match("Filter%s+:%s+warnings %(1/1%)") then error("ATC worklist should render warning filter") end
quality.open_worklist_quickfix()
assert_eq(#vim.fn.getqflist(), 1, "ATC worklist exports filtered quickfix")
quality.filter_worklist("info")
assert_eq(quality._read_settings().severity_filter, "info", "ATC filter persists severity")

vim.fn.setqflist({}, "r", { items = {}, title = "empty" })
local hist_worklist = quality.show_worklist("history warnings")
local rendered_hist = table.concat(vim.api.nvim_buf_get_lines(hist_worklist, 0, -1, false), "\n")
if not rendered_hist:match("Source%s+:%s+history") then error("ATC worklist should render history source") end

vim.cmd("enew")
vim.bo.filetype = "abap"
local ok, err = pcall(function() quality.run("") end)
if not ok then error("SapQuality without SAP object should not fail: " .. tostring(err)) end

print("QUALITY_OK")
