-- Offline regression tests for the persistent repository explorer helpers.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
  print(msg)
end

local repo = require("sap-nvim.core.repository")

local xml = table.concat({
  '<asx:abap xmlns:asx="http://www.sap.com/abapxml">',
  "<SEU_ADT_REPOSITORY_OBJ_NODE>",
  "<OBJECT_TYPE>CLAS/OC</OBJECT_TYPE>",
  "<OBJECT_NAME>ZCL_DEMO</OBJECT_NAME>",
  "<OBJECT_URI>/sap/bc/adt/oo/classes/zcl_demo</OBJECT_URI>",
  "<DESCRIPTION>Demo &amp; test</DESCRIPTION>",
  "<DEVCLASS>Z001</DEVCLASS>",
  "<ACTIVATION_STATE>inactive</ACTIVATION_STATE>",
  "<LOCKED_BY>DEVUSER</LOCKED_BY>",
  "<CORRNR>S4HK900777</CORRNR>",
  "</SEU_ADT_REPOSITORY_OBJ_NODE>",
  "<SEU_ADT_REPOSITORY_OBJ_NODE>",
  "<OBJECT_TYPE>DEVC/K</OBJECT_TYPE>",
  "<OBJECT_NAME>ZPKG_SUB</OBJECT_NAME>",
  "<OBJECT_URI>/sap/bc/adt/packages/zpkg_sub</OBJECT_URI>",
  "<DESCRIPTION>Sub package</DESCRIPTION>",
  "</SEU_ADT_REPOSITORY_OBJ_NODE>",
  "</asx:abap>",
}, "")

local rows = repo._parse_nodestructure(xml)
if #rows ~= 2 then
  error("expected 2 ADT rows, got " .. tostring(#rows))
end
if rows[1].name ~= "ZCL_DEMO" or rows[1].description ~= "Demo & test" then
  error("ADT node parse lost object data")
end
if rows[1].active_state ~= "inactive" or rows[1].locked_by ~= "DEVUSER" or rows[1].transport ~= "S4HK900777" then
  error("ADT node parse lost repository status")
end
if rows[1].package ~= "Z001" then
  error("ADT node parse lost package/devclass")
end

local nodes = repo._nodes_from_rows(rows)
if nodes[1].kind ~= "package" or nodes[1].name ~= "ZPKG_SUB" then
  error("packages must sort before repository objects")
end
if nodes[2].group ~= "class" then
  error("ADT class type did not resolve to source group")
end
if nodes[2].package ~= "Z001" then
  error("repository node did not preserve package")
end
if nodes[2].loaded ~= false or type(nodes[2].children) ~= "table" then
  error("expandable objects must start unloaded with a child table")
end
if repo._status_badges(nodes[2]) ~= " {inactive lock:DEVUSER S4HK900777}" then
  error("status badges did not include inactive/lock/transport")
end

local child_xml = table.concat({
  '<tre:node xmlns:tre="http://www.sap.com/adt/core/tree" xmlns:adtcore="http://www.sap.com/adt/core">',
  '<tre:objectReference adtcore:name="ZREP_DEMO_TOP" adtcore:type="PROG/I" adtcore:uri="/sap/bc/adt/programs/includes/zrep_demo_top" adtcore:description="Top include" adtcore:version="active" adtcore:packageName="Z001"/>',
  '<tre:objectReference adtcore:name="GET_DATA" adtcore:type="CLAS/OM" adtcore:description="Method" lockedBy="JDOE"/>',
  '<tre:objectReference name="CARRID" type="FIELD" description="Carrier"/>',
  "</tre:node>",
}, "")
local child_rows = repo._parse_nodestructure(child_xml)
if #child_rows ~= 3 then
  error("objectReference parser should parse generic ADT child nodes")
end
local child_nodes = repo._nodes_from_rows(child_rows)
local child_by_name = {}
for _, node in ipairs(child_nodes) do child_by_name[node.name] = node end
if child_by_name.ZREP_DEMO_TOP.group ~= "include" then
  error("program include child must be openable as include")
end
if child_by_name.ZREP_DEMO_TOP.package ~= "Z001" then
  error("objectReference parser lost adtcore:packageName")
end
if child_by_name.GET_DATA.member_kind ~= "method" or child_by_name.GET_DATA.locked_by ~= "JDOE" then
  error("class method child was not classified with lock status")
end
if child_by_name.CARRID.member_kind ~= "field" then
  error("DDIC field child was not classified")
end

local sapcli_rows = repo._parse_sapcli_package_lines({
  "Object type | Name | Description",
  "----------- | ---- | -----------",
  "PROG/P | ZREP_DEMO | Report",
  "PROG/I | ZREP_DEMO_TOP | Include",
})
if #sapcli_rows ~= 2 or sapcli_rows[2].type ~= "PROG/I" then
  error("sapcli package table parse failed")
end
local sapcli_nodes = repo._nodes_from_rows(sapcli_rows)
local groups = {}
for _, node in ipairs(sapcli_nodes) do
  groups[node.name] = node.group
end
if groups.ZREP_DEMO ~= "program" or groups.ZREP_DEMO_TOP ~= "include" then
  error("sapcli rows did not map to openable groups")
end

local tr = repo._parse_transport_line("S4HK900123  Fix explorer  (JOAQUIN)")
if tr.id ~= "S4HK900123" or tr.owner ~= "JOAQUIN" or tr.description ~= "Fix explorer" then
  error("transport line parse failed")
end

print("REPOSITORY_SPEC_OK")
