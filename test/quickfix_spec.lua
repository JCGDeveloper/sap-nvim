-- Offline tests for local ABAP quickfixes. No SAP connection required.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
  print(msg)
end

local quickfix = require("sap-nvim.core.quickfix")
local fails = 0

local function ok(cond, msg)
  if cond then
    print("  OK " .. msg)
  else
    fails = fails + 1
    print("  FAIL " .. msg)
  end
end

local function find_action(actions, id_prefix)
  for _, action in ipairs(actions) do
    if action.id:sub(1, #id_prefix) == id_prefix then
      return action
    end
  end
end

local function apply(lines, action)
  return quickfix._apply_action_to_lines(lines, action)
end

do
  local lines = {
    "REPORT zquickfix.",
    "METHOD run.",
    "  lv_total = 1",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 3,
    col = 4,
    message = 'Field "lv_total" is unknown',
  })
  local action = find_action(actions, "create-data:lv_total")
  ok(action ~= nil, "detects missing DATA from SAP message")
  local out = apply(lines, action)
  ok(out[3] == "  DATA lv_total TYPE i.", "inserts inferred integer DATA inside method")
  ok(out[4] == "  lv_total = 1", "keeps original statement after declaration")
end

do
  local lines = {
    "REPORT zquickfix.",
    "METHOD run.",
    "  LOOP AT lt_items ASSIGNING <ls_item>.",
    "  ENDLOOP.",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 3,
    col = 31,
    message = '"<ls_item>" has not been declared',
  })
  local action = find_action(actions, "declare-field-symbol:<ls_item>")
  ok(action ~= nil, "detects missing FIELD-SYMBOL")
  local out = apply(lines, action)
  ok(out[3] == "  FIELD-SYMBOLS <ls_item> LIKE LINE OF lt_items.", "declares FIELD-SYMBOL LIKE LINE OF table")
end

do
  local lines = {
    "METHOD build.",
    "  CREATE OBJECT lo_alv",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 2,
    col = 20,
    message = 'Statement "." expected',
  })
  local action = find_action(actions, "complete-create-object-period")
  ok(action ~= nil, "detects incomplete CREATE OBJECT")
  local out = apply(lines, action)
  ok(out[2] == "  CREATE OBJECT lo_alv.", "adds period to CREATE OBJECT")
end

do
  local lines = {
    "METHOD call_fm.",
    "  IF sy-subrc <> 0.",
    "  ENDIF.",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 2,
    col = 5,
    message = "",
  })
  local action = find_action(actions, "message-sy-msg")
  ok(action ~= nil, "offers sy-msg MESSAGE snippet in sy-subrc branch")
  local out = apply(lines, action)
  ok(out[3] == "    MESSAGE ID sy-msgid TYPE sy-msgty NUMBER sy-msgno", "inserts MESSAGE ID first line")
  ok(out[4] == "      WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4.", "inserts MESSAGE ID WITH continuation")
end

do
  local lines = {
    "METHOD run.",
    "  DATA lv_name TYPE string",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 2,
    col = 25,
    message = 'Statement "." expected',
  })
  local action = find_action(actions, "add-period")
  ok(action ~= nil, "detects safe missing final period")
  local out = apply(lines, action)
  ok(out[2] == "  DATA lv_name TYPE string.", "adds final period safely")
end

do
  local lines = {
    "METHOD run.",
    "  TRY.",
    "ENDMETHOD.",
  }
  local actions = quickfix._detect_local_actions({
    lines = lines,
    lnum = 2,
    col = 5,
    message = '"ENDTRY" expected',
  })
  local action = find_action(actions, "snippet-try")
  ok(action ~= nil, "offers contextual TRY/CATCH snippet")
  local preview = table.concat(quickfix._preview_lines({ lines = lines }, action), "\n")
  ok(preview:find("--- antes", 1, true) ~= nil and preview:find("--- despues", 1, true) ~= nil, "builds preview output")
end

do
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_set_current_buf(buf)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, {
    "REPORT zquickfix.",
    "METHOD run.",
    "  lv_flag = abap_true",
    "ENDMETHOD.",
  })
  vim.fn.setqflist({
    { bufnr = buf, lnum = 3, col = 4, text = 'Field "lv_flag" is unknown' },
  }, "r")
  vim.fn.setqflist({}, "a", { idx = 1 })
  local actions = quickfix.actions({ bufnr = buf })
  local action = find_action(actions, "create-data:lv_flag")
  ok(action ~= nil, "reads current quickfix item as local quickfix context")
  quickfix.apply({ bufnr = buf, action_id = action.id, confirm = false, local_only = true })
  local out = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
  ok(out[3] == "  DATA lv_flag TYPE abap_bool.", "applies quickfix to real buffer from qflist")
end

do
  local proposals = quickfix._parse_remote_proposals([[
<quickfixes:proposals xmlns:adtcore="http://www.sap.com/adt/core">
  <adtcore:objectReference adtcore:name="FIX1" adtcore:description="Remote fix"
    adtcore:uri="adt://S4F/sap/bc/adt/quickfixes/edits/1"/>
</quickfixes:proposals>
]])
  ok(#proposals == 1, "parses ADT quickfix proposals")
  ok(proposals[1].adt_uri == "/sap/bc/adt/quickfixes/edits/1", "normalizes ADT proposal URI")
  ok(proposals[1].desc == "Remote fix", "keeps ADT proposal description")

  local deltas = quickfix._parse_remote_deltas([[
<quickfixes:edits xmlns:adtcore="http://www.sap.com/adt/core">
  <unit>
    <adtcore:objectReference adtcore:uri="/sap/bc/adt/programs/programs/z/source/main#start=2,2;end=2,9"/>
    <content>DATA lv_text TYPE string.</content>
  </unit>
</quickfixes:edits>
]])
  ok(#deltas == 1, "parses ADT quickfix deltas")
  local out = quickfix._apply_remote_deltas_to_lines({ "REPORT z.", "  lv_text = `A`." }, deltas)
  ok(out[2] == "  DATA lv_text TYPE string. = `A`.", "applies ADT delta to in-memory lines for preview")
end

do
  local xml = [[
    <quickfixes:proposals xmlns:quickfixes="http://www.sap.com/adt/quickfixes" xmlns:adtcore="http://www.sap.com/adt/core">
      <quickfixes:proposal>
        <adtcore:objectReference adtcore:uri="/sap/bc/adt/quickfixes/evaluation/foo?proposalId=42&amp;mode=edit" adtcore:name="CREATE_DATA" adtcore:description="Crear DATA &quot;lv_text&quot;"/>
        <quickfixes:userContent>TYPE string</quickfixes:userContent>
      </quickfixes:proposal>
    </quickfixes:proposals>
  ]]
  local proposals = quickfix._parse_proposals(xml)
  ok(#proposals == 1, "parses nested ADT proposal")
  ok(proposals[1].adt_uri == "/sap/bc/adt/quickfixes/evaluation/foo?proposalId=42&mode=edit", "keeps dynamic proposal URI")
  ok(proposals[1].desc == 'Crear DATA "lv_text"', "decodes ADT proposal description")
  ok(proposals[1].user == "TYPE string", "parses ADT proposal userContent")
end

do
  local xml = [[
    <quickfixes:edits xmlns:quickfixes="http://www.sap.com/adt/quickfixes" xmlns:adtcore="http://www.sap.com/adt/core">
      <quickfixes:unit>
        <adtcore:objectReference adtcore:uri="/sap/bc/adt/programs/programs/zq/source/main#start=2,0;end=2,0"/>
        <quickfixes:content>  DATA lv_total TYPE i.&#10;</quickfixes:content>
      </quickfixes:unit>
    </quickfixes:edits>
  ]]
  local deltas, unsupported = quickfix._parse_deltas(xml)
  ok(#deltas == 1 and #unsupported == 0, "parses ADT edit delta with range")
  ok(deltas[1].srow == 2 and deltas[1].scol == 0 and deltas[1].erow == 2, "reads ADT delta range")
  ok(deltas[1].content == "  DATA lv_total TYPE i.\n", "decodes ADT delta content entities")
  local after = quickfix._apply_deltas_to_lines({ "REPORT zq.", "START-OF-SELECTION.", "  lv_total = 1." }, deltas)
  ok(after[2] == "  DATA lv_total TYPE i." and after[3] == "START-OF-SELECTION.", "applies ADT delta to preview lines")
  local preview = table.concat(quickfix._remote_preview_lines({
    lines = { "REPORT zq.", "START-OF-SELECTION.", "  lv_total = 1." },
    uri = "/sap/bc/adt/programs/programs/zq/source/main",
    row = 2,
    col = 0,
  }, { desc = "Crear DATA", adt_uri = "/sap/bc/adt/quickfixes/evaluation/foo" }, deltas, {}), "\n")
  ok(preview:find("Estado: preview; no aplicado", 1, true) ~= nil, "remote preview marks non-applied state")
  ok(preview:find("--- antes", 1, true) ~= nil and preview:find("--- despues", 1, true) ~= nil, "remote preview renders before and after")
end

do
  local xml = [[
    <quickfixes:edits xmlns:quickfixes="http://www.sap.com/adt/quickfixes">
      <quickfixes:workspaceEdit>
        <quickfixes:documentChanges>opaque server format</quickfixes:documentChanges>
      </quickfixes:workspaceEdit>
    </quickfixes:edits>
  ]]
  local deltas, unsupported = quickfix._parse_deltas(xml)
  ok(#deltas == 0 and #unsupported == 1, "keeps unclear ADT edit format unsupported")
  local preview = table.concat(quickfix._remote_preview_lines({
    lines = { "REPORT zq." },
    uri = "/sap/bc/adt/programs/programs/zq/source/main",
    row = 1,
    col = 0,
  }, { desc = "Opaque edit", adt_uri = "/sap/bc/adt/quickfixes/opaque" }, deltas, unsupported), "\n")
  ok(preview:find("Aplicacion bloqueada", 1, true) ~= nil, "blocks unclear ADT edits in preview")
  ok(preview:find("Bloques ADT no convertidos", 1, true) ~= nil, "shows unsupported ADT edit detail")
end

if fails > 0 then
  error(fails .. " quickfix test(s) failed")
end

print("QUICKFIX_OK")
