-- Offline regression tests for ABAP refactors. No SAP calls.

vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
  print(msg)
end

local refactor = require("sap-nvim.core.refactor")._test

local fails = 0

local function same(actual, expected, label)
  if actual ~= expected then
    fails = fails + 1
    print("  FAIL " .. label .. ": expected " .. tostring(expected) .. ", got " .. tostring(actual))
  else
    print("  OK   " .. label)
  end
end

local function truthy(value, label)
  same(value and true or false, true, label)
end

local function joined(lines)
  return table.concat(lines or {}, "\n")
end

local function contains(lines, needle, label)
  truthy(joined(lines):find(needle, 1, true), label)
end

local function not_contains(lines, needle, label)
  same(joined(lines):find(needle, 1, true) == nil, true, label)
end

print("refactor.lua offline:")

do
  local lines = {
    "CLASS lcl_demo IMPLEMENTATION.",
    "  METHOD first.",
    "    DATA lv_value TYPE string.",
    "    lv_value = 'lv_value'. \" lv_value comment",
    "  ENDMETHOD.",
    "  METHOD second.",
    "    lv_value = 'other'.",
    "  ENDMETHOD.",
    "ENDCLASS.",
  }
  local out, err, meta = refactor.rename_lines(lines, "lv_value", "lv_result", 3)
  same(err, nil, "rename has no error")
  same(meta.occurrences, 2, "rename counts code occurrences only")
  contains(out, "DATA lv_result TYPE string.", "rename declaration in method scope")
  contains(out, "lv_result = 'lv_value'. \" lv_value comment", "rename skips strings and comments")
  contains(out, "  METHOD second.\n    lv_value = 'other'.", "rename does not cross method scope")
end

do
  local lines = {
    "CLASS lcl_demo DEFINITION.",
    "  PUBLIC SECTION.",
    "    METHODS run.",
    "  PRIVATE SECTION.",
    "ENDCLASS.",
    "CLASS lcl_demo IMPLEMENTATION.",
    "  METHOD run.",
    "    DATA lv_text TYPE string.",
    "    lv_text = 'x'.",
    "  ENDMETHOD.",
    "ENDCLASS.",
  }
  local out, err, meta = refactor.extract_lines(lines, 8, 9, "build_text")
  same(err, nil, "extract method has no error")
  same(meta.kind, "method", "extract inside METHOD creates METHOD helper")
  contains(out, "    METHODS build_text.", "extract adds private method declaration")
  contains(out, "    me->build_text( ).", "extract replaces selection with local method call")
  contains(out, "  METHOD build_text.\n    DATA lv_text TYPE string.\n    lv_text = 'x'.\n  ENDMETHOD.", "extract appends method implementation")
end

do
  local lines = {
    "REPORT zdemo.",
    "START-OF-SELECTION.",
    "  WRITE: / 'hello'.",
  }
  local out, err, meta = refactor.extract_lines(lines, 3, 3, "write_hello")
  same(err, nil, "extract form has no error")
  same(meta.kind, "form", "extract outside METHOD creates FORM helper")
  contains(out, "  PERFORM write_hello.", "extract replaces report selection with PERFORM")
  contains(out, "FORM write_hello.\n  WRITE: / 'hello'.\nENDFORM.", "extract appends FORM")
end

do
  local lines = {
    "CLASS lcl_demo DEFINITION.",
    "  PUBLIC SECTION.",
    "    METHODS run.",
    "  PRIVATE SECTION.",
    "ENDCLASS.",
    "CLASS lcl_demo IMPLEMENTATION.",
    "  METHOD run.",
    "    me->missing( ).",
    "  ENDMETHOD.",
    "ENDCLASS.",
  }
  local out, err, meta = refactor.create_stub_lines(lines, 8, 10)
  same(err, nil, "stub has no error")
  same(meta.kind, "method", "stub creates method in class context")
  contains(out, "    METHODS missing.", "stub adds method declaration")
  contains(out, "  METHOD missing.\n  ENDMETHOD.", "stub adds method implementation")
end

do
  local lines = {
    "CLASS zcl_order_service DEFINITION PUBLIC FINAL CREATE PUBLIC.",
    "ENDCLASS.",
    "CLASS zcl_order_service IMPLEMENTATION.",
    "ENDCLASS.",
  }
  local out, err, meta = refactor.generate_test_class_lines(lines)
  same(err, nil, "test class generation has no error")
  same(meta.name, "ltcl_order_service", "test class name is derived from CUT")
  contains(out, "CLASS ltcl_order_service DEFINITION FINAL FOR TESTING", "test class definition inserted")
  contains(out, "cl_abap_unit_assert=>assert_true( abap_true ).", "test class has smoke assertion")
end

do
  local lines = {
    "INTERFACE zif_demo.",
    "  METHODS do_it.",
    "ENDINTERFACE.",
    "CLASS lcl_demo DEFINITION.",
    "  PUBLIC SECTION.",
    "    INTERFACES zif_demo.",
    "ENDCLASS.",
    "CLASS lcl_demo IMPLEMENTATION.",
    "ENDCLASS.",
  }
  local out, err, meta = refactor.implement_interface_lines(lines)
  same(err, nil, "interface skeleton has no error")
  same(meta.added, 1, "interface skeleton adds one method")
  contains(out, "  METHOD zif_demo~do_it.\n  ENDMETHOD.", "interface method implementation inserted")
end

do
  local lines = {
    "CLASS lcl_app DEFINITION.",
    "  PUBLIC SECTION.",
    "    INTERFACES if_oo_adt_classrun.",
    "ENDCLASS.",
    "CLASS lcl_app IMPLEMENTATION.",
    "ENDCLASS.",
  }
  local out, err = refactor.implement_interface_lines(lines)
  same(err, nil, "known interface skeleton has no error")
  contains(out, "  METHOD if_oo_adt_classrun~main.\n  ENDMETHOD.", "known ADT classrun main method inserted")
end

do
  local line = "    DATA(lv_value) = lv_other."
  same(refactor.symbol_at(line, 11), "lv_value", "symbol_at handles inline DATA")
  local changed = refactor.replace_symbol_line("lv_value = `lv_value`.", "lv_value", "lv_new")
  same(changed, "lv_new = `lv_value`.", "replace skips backtick literal")
end

if fails > 0 then
  error(tostring(fails) .. " refactor_spec failure(s)")
end

print("REFACTOR_SPEC_OK")
