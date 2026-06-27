-- Test offline (luajit test/completion_spec.lua) del completado ADT:
--   1) intel.M.parse: extrae identifier/kind/PREFIXLENGTH de la respuesta del servidor.
--   2) Clasificación del "gate" de adt_completion (struct_field/type_ctx/cds_field/member).
-- No toca SAP: usa respuestas XML de ejemplo (formato real de codecompletion).

-- ── stubs mínimos para poder cargar intel.lua sin Neovim ─────────────────────
_G.vim = {
  api = { nvim_create_namespace = function() return 0 end },
  bo = setmetatable({}, { __index = function() return "" end }),
  log = { levels = { INFO = 1, WARN = 2, ERROR = 3 } },
  notify = function() end,
  fn = {},
}
package.preload["sap-nvim.core.adt_http"] = function() return { is_available = function() return false end } end
package.preload["sap-nvim.core.objtype"] = function() return {} end
package.path = "./lua/?.lua;./lua/?/init.lua;" .. package.path

local intel = require("sap-nvim.core.intel")

local fails = 0
local function ok(cond, msg)
  if cond then
    print("  ✔ " .. msg)
  else
    fails = fails + 1
    print("  ✘ FAIL: " .. msg)
  end
end

-- ── 1) M.parse ───────────────────────────────────────────────────────────────
print("M.parse — formato SCC_COMPLETION (wa-campo / TYPE):")
local scc = [[<?xml version="1.0"?><asx:abap><asx:values><DATA>
<SCC_COMPLETION><KIND>30</KIND><IDENTIFIER>VBELN</IDENTIFIER><PREFIXLENGTH>0</PREFIXLENGTH></SCC_COMPLETION>
<SCC_COMPLETION><KIND>30</KIND><IDENTIFIER>ERDAT</IDENTIFIER><PREFIXLENGTH>0</PREFIXLENGTH></SCC_COMPLETION>
<SCC_COMPLETION><KIND>30</KIND><IDENTIFIER>@end</IDENTIFIER><PREFIXLENGTH>0</PREFIXLENGTH></SCC_COMPLETION>
</DATA></asx:values></asx:abap>]]
local items = intel.parse(scc)
ok(#items == 2, "extrae 2 campos (descarta @end), got " .. #items)
ok(items[1] and items[1].word == "VBELN", "primer campo = VBELN")
ok(items[1] and items[1].prefixlength == 0, "prefixlength=0 parseado")

print("M.parse — PREFIXLENGTH no-cero (tras teclear 'vb'):")
local scc2 = [[<SCC_COMPLETION><KIND>30</KIND><IDENTIFIER>VBELN</IDENTIFIER><PREFIXLENGTH>2</PREFIXLENGTH></SCC_COMPLETION>]]
local it2 = intel.parse(scc2)
ok(it2[1] and it2[1].prefixlength == 2, "prefixlength=2 parseado")

print("M.parse — formato abapsource:codeCompletion (métodos):")
local acc = [[<abapsource:codeCompletion adtcore:name="METHOD1" adtcore:type="3"/>]]
local it3 = intel.parse(acc)
ok(it3[1] and it3[1].word == "METHOD1" and it3[1].kind == "3", "método METHOD1 kind 3")

ok(#intel.parse(nil) == 0, "parse(nil) = vacío")
ok(#intel.parse("<html>error</html>") == 0, "parse de basura = vacío")

-- ── 2) Gate de adt_completion (mismas regex que integrations/adt_completion.lua) ──
print("Gate — clasificación de contextos:")
local function classify(before)
  local bl = before:lower()
  return {
    member = before:match("[=%-]>[%w_]*$") ~= nil or before:match("~[%w_]*$") ~= nil,
    cds_field = before:match("[%w_/]+%.[%w_/]*$") ~= nil,
    struct_field = before:match("[%w_%>%]%)]%-[%w_]*$") ~= nil,
    type_ctx = bl:match("%s+type%s+[%w_/]*$") ~= nil or bl:match("%s+like%s+[%w_/]*$") ~= nil,
  }
end

ok(classify("  wl_vbak-").struct_field, "`wl_vbak-` => struct_field")
ok(classify("  wl_vbak-vb").struct_field, "`wl_vbak-vb` => struct_field")
ok(classify("  <fs_line>-").struct_field, "`<fs_line>-` => struct_field")
ok(classify("  lt_alv[ 1 ]-").struct_field, "`lt_alv[ 1 ]-` => struct_field")
ok(not classify("  lo_obj->").struct_field, "`lo_obj->` NO es struct_field (es member)")
ok(classify("  lo_obj->").member, "`lo_obj->` => member")
ok(not classify("  a - b").struct_field, "`a - b` (resta con espacios) NO es struct_field")
ok(classify("  DATA lv TYPE vb").type_ctx, "`DATA lv TYPE vb` => type_ctx")
ok(classify("  DATA lv TYPE ").type_ctx, "`DATA lv TYPE ` (espacio) => type_ctx")
ok(classify("    p TYPE REF").type_ctx, "`p TYPE REF` => type_ctx (servidor sugiere TO)")
ok(not classify("  DATA lv_type ").type_ctx, "`lv_type ` (variable) NO es type_ctx")
ok(classify("  acreedor.").cds_field, "`acreedor.` => cds_field (CDS)")
ok(not classify("  wl_vbak-").cds_field, "`wl_vbak-` NO es cds_field")

print(fails == 0 and "\nTODO OK ✅" or ("\n" .. fails .. " FALLOS ❌"))
os.exit(fails == 0 and 0 or 1)
