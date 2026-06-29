-- Offline regression tests for source package/devclass detection.

vim.opt.rtp:append(vim.fn.getcwd())

local source = require("sap-nvim.core.source")

local function same(actual, expected, msg)
  if actual ~= expected then
    error((msg or "assertion failed") .. " (got " .. tostring(actual) .. ", expected " .. tostring(expected) .. ")")
  end
end

same(
  source._package_from_xml('<adtcore:packageRef adtcore:name="Z001"/>'),
  "Z001",
  "packageRef is parsed"
)
same(
  source._package_from_xml('<adtcore:objectReference adtcore:packageName="Z001"/>'),
  "Z001",
  "adtcore:packageName is parsed"
)
same(
  source._package_from_xml('<tm:object tm:devclass="Z001"/>'),
  "Z001",
  "devclass attribute is parsed"
)
same(
  source._package_from_xml("<ROOT><DEVCLASS>Z001</DEVCLASS></ROOT>"),
  "Z001",
  "DEVCLASS tag is parsed"
)
same(source._normalize_package_value("z001"), "Z001", "plain package fallback is uppercased")
same(source._better_package("$TMP", "Z001"), "Z001", "real fallback wins over metadata $TMP")
same(source._better_package("Z002", "Z001"), "Z002", "real metadata wins over fallback")

same(
  source._object_uri("domain", "ZD_DEMO"),
  "/sap/bc/adt/ddic/domains/zd_demo",
  "domain object URI is lowercased and escaped"
)
same(
  source._source_uri("tabletype", "ZTT_DEMO"),
  "/sap/bc/adt/ddic/tabletypes/ztt_demo/source/main",
  "table type source URI is built"
)
same(
  source._object_uri("functionmodule", "Z_FM_DEMO", { fgroup = "ZFG_DEMO" }),
  "/sap/bc/adt/functions/groups/zfg_demo/fmodules/z_fm_demo",
  "function module URI includes function group"
)
same(
  source._readonly_reason("ZDE_DEMO", "dataelement"),
  "metadata ADT sin editor de código",
  "data element opens as metadata readonly"
)
same(source._readonly_reason("ZT_DEMO", "table"), nil, "table source is editable when source/main exists")

print("SOURCE_PACKAGE_SPEC_OK")
