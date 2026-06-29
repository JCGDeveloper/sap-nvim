-- Offline regression tests for dump parser and commands. No SAP connection required.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg) print(msg) end

local dumps = require("sap-nvim.core.dumps")

local function assert_eq(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assert_eq") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

local xml = [[
<feed xmlns:adtcore="http://www.sap.com/adt/core">
  <adtcore:objectReference adtcore:name="DBIF_RSQL_SQL_ERROR"
    adtcore:description="SQL error &amp; dump"
    adtcore:uri="/sap/bc/adt/runtime/dumps/1"
    adtcore:program="ZREP_DEMO"
    adtcore:user="JDOE"
    adtcore:timestamp="2026-06-29T10:00:00Z"/>
  <entry>
    <id>RAISE_EXCEPTION</id>
    <title>Unhandled exception</title>
    <updated>2026-06-29T11:00:00Z</updated>
    <link href="/sap/bc/adt/runtime/dumps/2"/>
  </entry>
</feed>
]]

local rows = dumps._parse_body(xml)
assert_eq(#rows, 2, "dump parser returns two rows")
assert_eq(rows[1].id, "DBIF_RSQL_SQL_ERROR", "dump parser keeps objectReference name")
assert_eq(rows[1].title, "SQL error & dump", "dump parser decodes XML entities")
assert_eq(rows[1].program, "ZREP_DEMO", "dump parser keeps program")
assert_eq(rows[2].uri, "/sap/bc/adt/runtime/dumps/2", "dump parser keeps atom link")

local atom = [[
<feed xmlns:atom="http://www.w3.org/2005/Atom">
  <atom:entry>
    <atom:author FullName="SEIJC2"><atom:name>SEIJC2</atom:name></atom:author>
    <atom:category term="DYNPRO_SYNTAX_ERROR" label="ABAP runtime error"/>
    <atom:category term="ZMM01_JCG" label="Terminated ABAP program"/>
    <atom:id>/sap/bc/adt/vit/runtime/dumps/1</atom:id>
    <atom:link href="adt://S4F/sap/bc/adt/runtime/dump/1" rel="self" type="text/plain"/>
    <atom:published>2026-06-25T15:12:45Z</atom:published>
    <atom:summary type="html">&lt;h4 id="HEADERX"&gt;Header Information&lt;/h4&gt;&lt;table&gt;&lt;tr&gt;&lt;td&gt;&lt;b&gt;Short Text&amp;nbsp;&lt;/b&gt;&lt;/td&gt;&lt;td nowrap&gt; Syntax or generation error in a screen. &lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;&lt;b&gt;Runtime Error&amp;nbsp;&lt;/b&gt;&lt;/td&gt;&lt;td nowrap&gt; DYNPRO_SYNTAX_ERROR &lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;&lt;b&gt;Program&amp;nbsp;&lt;/b&gt;&lt;/td&gt;&lt;td nowrap&gt; ZMM01_JCG &lt;/td&gt;&lt;/tr&gt;&lt;tr&gt;&lt;td&gt;&lt;b&gt;User&amp;nbsp;&lt;/b&gt;&lt;/td&gt;&lt;td nowrap&gt; SEIJC2 (SEIJC2) &lt;/td&gt;&lt;/tr&gt;&lt;/table&gt;</atom:summary>
  </atom:entry>
</feed>
]]

local atom_rows = dumps._parse_body(atom)
assert_eq(#atom_rows, 1, "dump parser supports SAP Atom dumps")
assert_eq(atom_rows[1].user, "SEIJC2", "atom parser keeps user")
assert_eq(atom_rows[1].program, "ZMM01_JCG", "atom parser keeps program")
assert_eq(atom_rows[1].exception, "DYNPRO_SYNTAX_ERROR", "atom parser keeps runtime error")
assert_eq(atom_rows[1].uri, "/sap/bc/adt/runtime/dump/1", "atom parser normalizes adt URI")

local json_rows = dumps._parse_body([[{"dumps":[{"id":"D1","shortText":"Short dump","program":"ZREP"}]}]])
assert_eq(#json_rows, 1, "dump parser supports json")
assert_eq(json_rows[1].title, "Short dump", "json parser keeps title")

dumps.setup()
assert_eq(vim.fn.exists(":SapDumps"), 2, "SapDumps command exists")
assert_eq(vim.fn.exists(":SapDumpList"), 2, "SapDumpList command exists")
assert_eq(vim.fn.exists(":SapDumpOpen"), 2, "SapDumpOpen command exists")
assert_eq(vim.fn.exists(":SapDumpsRoutes"), 2, "SapDumpsRoutes command exists")
assert_eq(vim.fn.exists(":SapST22"), 2, "SapST22 command exists")

print("DUMPS_OK")
