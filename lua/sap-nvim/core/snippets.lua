-- sap-nvim.snippets
-- Snippets ABAP para autocompletado con blink.cmp
-- Usá el prefijo + Tab para expandir.
-- Los nombres de variables placeholder usan la convención configurable
-- (require("sap-nvim").setup({ naming = {...} })) vía core/config.lua.

local n = require("sap-nvim.core.config").naming()

return {
  -- REPORT
  report = {
    trig = "report",
    name = "REPORT skeleton",
    body = [[REPORT ${1:zprogram}.\n\n${0}]],
  },
  -- IF / ENDIF
  ife = {
    trig = "ife",
    name = "IF-ENDIF",
    body = [[IF ${1:condition}.\n  ${0}\nENDIF.]],
  },
  ifel = {
    trig = "ifel",
    name = "IF-ELSE-ENDIF",
    body = [[IF ${1:condition}.\n  ${0}\nELSE.\n  ${2}\nENDIF.]],
  },
  -- LOOP / ENDLOOP
  loop = {
    trig = "loop",
    name = "LOOP-ENDLOOP",
    body = [[LOOP AT ${1:]] .. n.itab .. [[table} INTO ${2:]] .. n.struct .. [[row}.\n  ${0}\nENDLOOP.]],
  },
  -- DO / ENDDO
  doo = {
    trig = "doo",
    name = "DO-ENDDO",
    body = [[DO ${1:10} TIMES.\n  ${0}\nENDDO.]],
  },
  -- WHILE / ENDWHILE
  -- NOTE: `while` is a Lua reserved word, so the key must be quoted.
  ["while"] = {
    trig = "while",
    name = "WHILE-ENDWHILE",
    body = [[WHILE ${1:condition}.\n  ${0}\nENDWHILE.]],
  },
  -- TRY / ENDTRY
  try = {
    trig = "try",
    name = "TRY-CATCH-ENDTRY",
    body = [[TRY.\n  ${0}\nCATCH ${1:cx_root} INTO ${2:]] .. n.ref .. [[error}.\n  MESSAGE ]] .. n.ref .. [[error->get_text( ) TYPE 'E'.\nENDTRY.]],
  },
  -- CASE / ENDCASE
  case = {
    trig = "case",
    name = "CASE-WHEN-ENDCASE",
    body = [[CASE ${1:]] .. n.var .. [[value}.\n  WHEN ${2:value1}.\n    ${0}\n  WHEN OTHERS.\n    ${3}\nENDCASE.]],
  },
  -- DATA declaration
  data = {
    trig = "data",
    name = "DATA declaration",
    body = [[DATA(${1:]] .. n.var .. [[name}) TYPE ${2:string}.]],
  },
  datab = {
    trig = "datab",
    name = "DATA BEGIN OF",
    body = [[DATA: BEGIN OF ${1:]] .. n.struct .. [[struct},\n          ${2:field} TYPE ${3:string},\n        END OF ${1:]] .. n.struct .. [[struct}.]],
  },
  -- METHOD
  meth = {
    trig = "meth",
    name = "METHOD-ENDMETHOD",
    body = [[METHOD ${1:name}.\n  ${0}\nENDMETHOD.]],
  },
  -- CLASS definition
  class = {
    trig = "class",
    name = "CLASS DEFINITION",
    body = [[CLASS ${1:zcl_class} DEFINITION${2: PUBLIC}.\n  PUBLIC SECTION.\n    ${0}\n  PROTECTED SECTION.\n  PRIVATE SECTION.\nENDCLASS.]],
  },
  class_imp = {
    trig = "classi",
    name = "CLASS IMPLEMENTATION",
    body = [[CLASS ${1:zcl_class} IMPLEMENTATION.\n  METHOD ${2:constructor}.\n    ${0}\n  ENDMETHOD.\nENDCLASS.]],
  },
  -- SELECT
  sel = {
    trig = "sel",
    name = "SELECT single",
    body = [[SELECT SINGLE *\n  FROM ${1:dbtab}\n  INTO ${2:]] .. n.struct .. [[row}\n  WHERE ${3:field} = ${4:value}.]],
  },
  sel_all = {
    trig = "selall",
    name = "SELECT all",
    body = [[SELECT *\n  FROM ${1:dbtab}\n  INTO TABLE ${2:]] .. n.itab .. [[table}\n  UP TO ${3:100} ROWS\n  WHERE ${4:condition}.\nIF sy-subrc = 0.\n  ${0}\nENDIF.]],
  },
  -- WRITE
  write = {
    trig = "wri",
    name = "WRITE statement",
    body = [[WRITE: / '${1:text}', ${2:variable}.]],
  },
  -- MESSAGE
  msg = {
    trig = "msg",
    name = "MESSAGE statement",
    body = [[MESSAGE '${1:text}' TYPE '${2:I}' DISPLAY LIKE '${3:I}'.]],
  },
  -- FORM
  form = {
    trig = "form",
    name = "FORM-ENDFORM",
    body = [[FORM ${1:name} ${2:USING} ${3:value}.\n  ${0}\nENDFORM.]],
  },
  -- AUnit test
  test = {
    trig = "test",
    name = "AUnit test method",
    body = [[METHOD test_${1:name} FOR TESTING.\n  ${0}\n  cl_abap_unit_assert=>fail( 'Test no implementado' ).\nENDMETHOD.]],
  },
  testclass = {
    trig = "testc",
    name = "Test class skeleton",
    body = [[CLASS ltc_${1:testclass} DEFINITION FOR TESTING.\n  PRIVATE SECTION.\n    METHODS: test_${2:case} FOR TESTING.\nENDCLASS.\n\nCLASS ltc_${1:testclass} IMPLEMENTATION.\n  METHOD test_${2:case}.\n    ${0}\n  ENDMETHOD.\nENDCLASS.]],
  },
  -- ALV
  alv = {
    trig = "alv",
    name = "ALV grid call",
    body = [[cl_salv_table=>factory(\n  IMPORTING\n    r_salv_table = DATA(]] .. n.ref .. [[alv)\n  CHANGING\n    t_table      = ${1:]] .. n.itab .. [[data} ).\n]] .. n.ref .. [[alv->display( ).]],
  },
  -- RAP
  rap_behavior = {
    trig = "rapb",
    name = "RAP Behavior Definition",
    body = [[managed implementation in class ${1:zcl_rap} unique.\nstrict.\n\ndefine behavior for ${2:ZENTITY} alias ${3:Alias}\n  persistent table ${4:zdbtab}\n  lock master\n  etag master ${5:last_changed_at}\n{\n  create;\n  update;\n  delete;\n}]],
  },
}
