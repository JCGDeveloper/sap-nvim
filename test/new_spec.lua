-- Offline regression tests for :SapNew builders/templates. No SAP calls.

package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local new = require("sap-nvim.core.new")
local T = new._test
local config = require("sap-nvim.core.config")

local fails = 0

local function same(got, expected, msg)
  local ok = got == expected
  if ok then
    print("  OK  " .. msg)
  else
    fails = fails + 1
    print("  FAIL " .. msg .. " expected=" .. tostring(expected) .. " got=" .. tostring(got))
  end
end

local function truthy(v, msg)
  same(v and true or false, true, msg)
end

local function contains(haystack, needle, msg)
  truthy(tostring(haystack or ""):find(needle, 1, true), msg)
end

local function joined(t)
  return table.concat(t, " ")
end

print("new.lua builders:")

truthy(T.type_by_key("table_type"), "table type is exposed in SapNew")
truthy(T.type_by_key("behavior_definition"), "RAP behavior definition is exposed in SapNew")
truthy(T.type_by_key("report_variant"), "report variant is exposed in SapNew")

local class_spec = T.type_by_key("class")
local class_xml = T.adt_create.class.build("ZCL_DEMO", "Demo & Test", "ES", "DEVELOPER", "ZPKG")
contains(class_xml, 'adtcore:type="CLAS/OC"', "class ADT XML has CLAS type")
contains(class_xml, 'adtcore:language="ES"', "class ADT XML keeps configured language")
contains(class_xml, 'adtcore:description="Demo &amp; Test"', "class ADT XML escapes text")
contains(class_xml, '<adtcore:packageRef adtcore:name="ZPKG"/>', "class ADT XML has packageRef")
truthy(T.valid_adt_create_path(T.adt_create_paths.class), "class ADT create path is validated")
same(T.valid_adt_create_path("/sap/bc/adt/unknown"), false, "unknown ADT create path is rejected")

local ddlx_xml = T.adt_create.metadata_extension.build("ZC_DEMO_E", "Metadata Ext", "ES", "DEVELOPER", "ZPKG")
contains(ddlx_xml, 'adtcore:type="DDLX/EX"', "DDLX ADT XML has type")
truthy(T.valid_adt_create_path(T.adt_create_paths.metadata_extension), "DDLX ADT create path is validated")

local bdef_xml = T.adt_create.behavior_definition.build("ZI_DEMO", "Behavior", "ES", "DEVELOPER", "ZPKG")
contains(bdef_xml, 'adtcore:type="BDEF/BDO"', "BDEF ADT XML has type")
truthy(T.valid_adt_create_path(T.adt_create_paths.behavior_definition), "BDEF ADT create path is validated")

local domain_xml = T.ddic_create.domain.build("ZD_DEMO", "Domain <Demo>", "ES", "DEVELOPER", "ZPKG", {
  datatype = "NUMC",
  length = 8,
})
contains(domain_xml, 'adtcore:type="DOMA/DO"', "domain DDIC XML has DOMA type")
contains(domain_xml, 'adtcore:description="Domain &lt;Demo&gt;"', "domain DDIC XML escapes description")
contains(domain_xml, 'ddic:dataType="NUMC"', "domain DDIC XML carries datatype")
truthy(T.valid_adt_create_path(T.adt_create_paths.domain), "domain ADT create path is validated")

local dtel_xml = T.ddic_create.data_element.build("ZDE_DEMO", "Data Element", "ES", "DEVELOPER", "ZPKG", {
  domain = "ZD_DEMO",
})
contains(dtel_xml, 'adtcore:type="DTEL/DE"', "data element DDIC XML has DTEL type")
contains(dtel_xml, 'adtcore:name="ZD_DEMO"', "data element DDIC XML references domain")

local struct_xml = T.ddic_create.structure.build("ZS_DEMO", "Structure", "ES", "DEVELOPER", "ZPKG", {
  field = "FIELD1",
  element = "ZDE_DEMO",
})
contains(struct_xml, 'adtcore:type="TABL/DS"', "structure DDIC XML has TABL/DS type")
contains(struct_xml, 'ddic:name="FIELD1"', "structure DDIC XML carries field")

local table_plan = T.build_adt_plan("table", "ZT_DEMO", "Table Demo", "ZPKG")
same(table_plan.path, "/sap/bc/adt/ddic/tables", "table plan uses DDIC table route")
same(table_plan.default_path, false, "DDIC plan is not default creation path")

local srvd_plan = T.build_adt_plan("service_definition", "ZUI_DEMO", "Service Demo", "ZPKG")
same(srvd_plan.default_path, true, "RAP source plan is default ADT creation path")
contains(srvd_plan.body, 'adtcore:type="SRVD/SRV"', "SRVD plan body has type")

local tabletype_args = T.build_create_args(T.type_by_key("table_type"), "ZTT_DEMO", "Table type", "ZPKG", "S4HK900001")
same(joined(tabletype_args), "sapcli tabletype create ZTT_DEMO Table type ZPKG --corrnr S4HK900001", "tabletype create command")

local fm_args = T.build_create_args(T.type_by_key("function_module"), "Z_FM_DEMO", "FM Demo", nil, nil, "ZFG_DEMO")
same(joined(fm_args), "sapcli functionmodule create ZFG_DEMO Z_FM_DEMO FM Demo", "function module create command")

local tx_args = T.build_transaction_args("ZTX_DEMO", "Tx Demo", "ZPKG", "S4HK900002", "report", "ZREP_DEMO")
contains(joined(tx_args), "sapcli transaction create ZTX_DEMO Tx Demo ZPKG -t report --report-name ZREP_DEMO", "transaction report command")
contains(joined(tx_args), "--report-dynnr 1000", "transaction report gets default dynpro")
contains(joined(tx_args), "--corrnr S4HK900002", "transaction report gets corrnr")

local variant_args = T.build_create_args(T.type_by_key("report_variant"), "ZVARIANT", "Variant", nil, "S4HK900003", nil, {
  program = "ZREP_DEMO",
})
same(joined(variant_args), "sapcli program variant create ZREP_DEMO ZVARIANT Variant --corrnr S4HK900003", "report variant command")

local pkg_xml = T.build_package_adt_body("ZPKG_DEMO", "Pkg <Demo>", "ZSUPER", "ES", "DEVELOPER")
contains(pkg_xml, 'adtcore:type="DEVC/K"', "package ADT XML has DEVC type")
contains(pkg_xml, 'adtcore:description="Pkg &lt;Demo&gt;"', "package ADT XML escapes text")
contains(pkg_xml, '<pak:superPackage adtcore:name="ZSUPER"/>', "package ADT XML has super package")

local cds = T.initial_source(T.type_by_key("cds_view"), "ZI_DEMO", "CDS Demo")
contains(cds, "define view entity ZI_DEMO", "CDS initial source")
local bdef = T.initial_source(T.type_by_key("behavior_definition"), "ZI_DEMO", "Behavior Demo")
contains(bdef, "define behavior for ZI_ENTITY", "BDEF initial source")
local srvd = T.initial_source(T.type_by_key("service_definition"), "ZUI_DEMO", "Service Demo")
contains(srvd, "define service ZUI_DEMO", "SRVD initial source")

config.setup({ profile = "prod" })
same(T.creation_block_reason(), "modo solo lectura activo", "prod profile blocks object creation by default")
config.setup({ profile = "prod", productive = { read_only = false, allow_create_objects = false } })
same(T.creation_block_reason(), "productive.allow_create_objects=false", "prod opt-in gate blocks creation")
config.setup({ profile = "dev" })

print(fails == 0 and "new_spec OK" or (tostring(fails) .. " failure(s)"))
if fails > 0 then
  vim.cmd("cquit")
end
