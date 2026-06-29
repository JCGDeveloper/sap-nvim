-- Offline regression tests for the persistent ADT local index.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
  print(msg)
end

local index = require("sap-nvim.core.index")

local function same(actual, expected, label)
  if actual ~= expected then
    error((label or "assertion failed") .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  end
end

index.clear()

local search_xml = table.concat({
  '<feed xmlns:adtcore="http://www.sap.com/adt/core">',
  '<adtcore:objectReference adtcore:name="ZCL_FLIGHT_SERVICE" adtcore:type="CLAS/OC"',
  ' adtcore:uri="/sap/bc/adt/oo/classes/zcl_flight_service"',
  ' adtcore:description="Flight booking service" adtcore:packageName="ZPKG_FLIGHT"/>',
  '<adtcore:objectReference adtcore:name="ZIF_FLIGHT_API" adtcore:type="INTF/OI"',
  ' adtcore:uri="/sap/bc/adt/oo/interfaces/zif_flight_api"',
  ' adtcore:description="Flight API"/>',
  '<adtcore:objectReference adtcore:name="ZPKG_FLIGHT" adtcore:type="DEVC/K"',
  ' adtcore:uri="/sap/bc/adt/packages/zpkg_flight" adtcore:description="Flight package"/>',
  '</feed>',
}, "")

local search_entries = index._parse_search_body(search_xml)
same(#search_entries, 3, "search parser count")
same(search_entries[1].name, "ZCL_FLIGHT_SERVICE", "search parser name")
same(search_entries[1].group, "class", "class group")
same(search_entries[1].kind, "object", "class kind")
same(search_entries[1].package, "ZPKG_FLIGHT", "package attribute")
same(search_entries[3].kind, "package", "package kind")

local repo_xml = table.concat({
  '<asx:abap xmlns:asx="http://www.sap.com/abapxml">',
  '<SEU_ADT_REPOSITORY_OBJ_NODE>',
  '<OBJECT_TYPE>TABL/DT</OBJECT_TYPE>',
  '<OBJECT_NAME>ZFLIGHT_BOOKING</OBJECT_NAME>',
  '<OBJECT_URI>/sap/bc/adt/ddic/tables/zflight_booking</OBJECT_URI>',
  '<DESCRIPTION>Flight booking table</DESCRIPTION>',
  '</SEU_ADT_REPOSITORY_OBJ_NODE>',
  '</asx:abap>',
}, "")

local repo_entries = index._parse_nodestructure(repo_xml, { name = "ZPKG_FLIGHT", type = "DEVC/K" })
same(#repo_entries, 1, "repository parser count")
same(repo_entries[1].parent, "ZPKG_FLIGHT", "repository parent")
same(repo_entries[1].group, "table", "table group")

local child_xml = table.concat({
  '<tre:node xmlns:tre="http://www.sap.com/adt/core/tree" xmlns:adtcore="http://www.sap.com/adt/core">',
  '<tre:objectReference adtcore:name="GET_BOOKINGS" adtcore:type="CLAS/OM" adtcore:description="Read bookings"/>',
  '<tre:objectReference adtcore:name="CARRID" adtcore:type="FIELD" adtcore:description="Carrier"/>',
  '</tre:node>',
}, "")

local child_entries = index._parse_nodestructure(child_xml, { name = "ZCL_FLIGHT_SERVICE", type = "CLAS/OC" })
same(#child_entries, 2, "child parser count")
same(child_entries[1].kind, "method", "method kind")
same(child_entries[2].kind, "field", "field kind")
same(child_entries[1].parent, "ZCL_FLIGHT_SERVICE", "child parent")

local add1 = index.add_entries(search_entries, { source = "search:Z*", save = false })
same(add1.added, 3, "initial add")
local add2 = index.add_entries(repo_entries, { source = "repository:ZPKG_FLIGHT", save = false })
same(add2.added, 1, "repository add")
local add3 = index.add_entries(child_entries, { source = "repository:ZPKG_FLIGHT:ZCL_FLIGHT_SERVICE", save = true })
same(add3.added, 2, "child add")

local status = index.status()
same(status.counts.total, 6, "status total")
same(status.counts.object, 3, "status objects")
same(status.counts.method, 1, "status methods")
same(status.counts.field, 1, "status fields")
same(status.counts.package, 1, "status packages")

local objects = index.search_objects("ZCL_FLIGHT", { limit = 2 })
same(objects[1].name, "ZCL_FLIGHT_SERVICE", "object exact prefix ranking")

local desc = index.search("booking", { limit = 3 })
same(desc[1].name, "ZFLIGHT_BOOKING", "description/name ranking")

local methods = index.search_methods("GET", { parent = "ZCL_FLIGHT_SERVICE" })
same(#methods, 1, "method parent filter")
same(methods[1].name, "GET_BOOKINGS", "method search")

local packages = index.search_packages("flight")
same(packages[1].name, "ZPKG_FLIGHT", "package search")

local parsed_patterns, parsed_roots = index._parse_build_args({ "ZCL*", "package:zpkg_flight" })
same(parsed_patterns[1], "ZCL*", "build arg pattern")
same(parsed_roots[1], "ZPKG_FLIGHT", "build arg package")

local path = index.path()
if vim.fn.filereadable(path) ~= 1 then
  error("index file was not persisted: " .. path)
end

local reloaded = index.load()
same(#reloaded.entries, 6, "persisted entry count")
same(index.search_fields("CARR")[1].name, "CARRID", "field survives reload")

index.clear()

print("INDEX_SPEC_OK")
