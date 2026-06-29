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
quality._record_history({ kind = "ATC", scope = "object", target = "ZCL_DEMO", status = "ok", errors = 0, warnings = 0 })
local history = quality._read_history()
assert_eq(#history, 1, "quality history persists one entry")
assert_eq(history[1].target, "ZCL_DEMO", "quality history keeps target")

quality.setup()
assert_eq(vim.fn.exists(":SapQuality"), 2, "SapQuality command exists")
assert_eq(vim.fn.exists(":SapAUnitPanel"), 2, "SapAUnitPanel command exists")
assert_eq(vim.fn.exists(":SapAtcPanel"), 2, "SapAtcPanel command exists")
assert_eq(vim.fn.exists(":SapQualityHistory"), 2, "SapQualityHistory command exists")

print("QUALITY_OK")
