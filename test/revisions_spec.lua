-- Offline regression tests for revision parser and commands. No SAP connection required.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg) print(msg) end

local revisions = require("sap-nvim.core.revisions")

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local xml = [[
<feed xmlns:adtcore="http://www.sap.com/adt/core">
  <entry>
    <id>0000000001</id>
    <title>Initial import</title>
    <updated>2026-06-29T10:00:00Z</updated>
    <author><name>JDOE</name></author>
    <link rel="content" type="text/plain" href="/sap/bc/adt/programs/programs/zrev/source/main?version=0000000001"/>
  </entry>
  <adtcore:objectReference adtcore:name="ZREV"
    adtcore:description="Changed &amp; activated"
    adtcore:uri="/sap/bc/adt/programs/programs/zrev"
    adtcore:version="0000000002"
    adtcore:changedBy="ASMITH"
    adtcore:changedAt="2026-06-29T11:00:00Z"
    transport="DEVK900001"/>
</feed>
]]

local rows = revisions._parse_body(xml)
assert_eq(#rows, 2, "revision parser returns two rows")
assert_eq(rows[1].id, "0000000001", "atom id parsed")
assert_eq(rows[1].author, "JDOE", "atom author parsed")
assert_eq(rows[1].content_uri, "/sap/bc/adt/programs/programs/zrev/source/main?version=0000000001", "atom content link parsed")
assert_eq(rows[2].version, "0000000002", "objectReference version parsed")
assert_eq(rows[2].description, "Changed & activated", "xml entities decoded")
assert_eq(rows[2].transport, "DEVK900001", "transport parsed")

local json_rows = revisions._parse_body([[{"versions":[{"version":"A1","changedBy":"JDOE","transport":"DEVK900002","contentUri":"/source?version=A1"}]}]])
assert_eq(#json_rows, 1, "revision parser supports json")
assert_eq(json_rows[1].version, "A1", "json version parsed")
assert_eq(json_rows[1].author, "JDOE", "json author parsed")

local key = revisions._route_key({ path = "/sap/bc/adt/x", query = { b = "2", a = "1" } })
assert_eq(key, "/sap/bc/adt/x?a=1&b=2", "route key sorts query params")

local lines = revisions._render_lines(rows, {
  { route = { path = "/sap/bc/adt/programs/programs/zrev/versions" }, code = 404, count = 0 },
}, { name = "ZREV", source_uri = "/sap/bc/adt/programs/programs/zrev/source/main" })
assert_eq(lines[1], "SAP Revisions", "render has title")
assert_eq(lines[#lines], "  NO HTTP 404 /sap/bc/adt/programs/programs/zrev/versions (0)", "render includes route status")

revisions.setup()
assert_eq(vim.fn.exists(":SapRevisions"), 2, "SapRevisions command exists")
assert_eq(vim.fn.exists(":SapRevisionRoutes"), 2, "SapRevisionRoutes command exists")
assert_eq(vim.fn.exists(":SapRevisionDiff"), 2, "SapRevisionDiff command exists")

print("REVISIONS_OK")
