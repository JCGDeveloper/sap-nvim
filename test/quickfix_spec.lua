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

if fails > 0 then
  error(fails .. " quickfix test(s) failed")
end

print("QUICKFIX_OK")
