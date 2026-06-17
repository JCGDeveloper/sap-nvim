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

  -- ── Declaración de miembros de clase/interfaz (lo que enseña Eclipse en las SECTION) ──
  methi = {
    trig = "methi",
    name = "METHODS (instancia, todos los parámetros)",
    body = [[METHODS ${1:name}\n  IMPORTING\n    !${2:iv_param} TYPE ${3:type}\n  EXPORTING\n    !${4:ev_param} TYPE ${5:type}\n  CHANGING\n    !${6:cv_param} TYPE ${7:type}\n  RETURNING\n    VALUE(${8:rv_result}) TYPE ${9:type}\n  RAISING\n    ${10:cx_static_check}.]],
  },
  methr = {
    trig = "methr",
    name = "METHODS RETURNING (función)",
    body = [[METHODS ${1:name}\n  IMPORTING\n    !${2:iv_param} TYPE ${3:type}\n  RETURNING\n    VALUE(${4:rv_result}) TYPE ${5:type}\n  RAISING\n    ${6:cx_static_check}.]],
  },
  cmethods = {
    trig = "cmethods",
    name = "CLASS-METHODS (estático)",
    body = [[CLASS-METHODS ${1:name}\n  IMPORTING\n    !${2:iv_param} TYPE ${3:type}\n  RETURNING\n    VALUE(${4:rv_result}) TYPE ${5:type}\n  RAISING\n    ${6:cx_static_check}.]],
  },
  ctor = {
    trig = "ctor",
    name = "METHODS constructor",
    body = [[METHODS constructor\n  IMPORTING\n    !${1:iv_param} TYPE ${2:type}.]],
  },
  cctor = {
    trig = "cctor",
    name = "CLASS-METHODS class_constructor",
    body = [[CLASS-METHODS class_constructor.]],
  },
  attr = {
    trig = "attr",
    name = "DATA (atributo de instancia)",
    body = [[DATA ${1:mv_attribute} TYPE ${2:string}.]],
  },
  cattr = {
    trig = "cattr",
    name = "CLASS-DATA (atributo estático)",
    body = [[CLASS-DATA ${1:gv_attribute} TYPE ${2:string}.]],
  },
  const = {
    trig = "const",
    name = "CONSTANTS",
    body = [[CONSTANTS ${1:co_name} TYPE ${2:string} VALUE ${3:'x'}.]],
  },
  types = {
    trig = "types",
    name = "TYPES",
    body = [[TYPES ${1:ty_name} TYPE ${2:string}.]],
  },
  event = {
    trig = "event",
    name = "EVENTS",
    body = [[EVENTS ${1:evt_name} EXPORTING VALUE(${2:ev_param}) TYPE ${3:type}.]],
  },
  cevent = {
    trig = "cevent",
    name = "CLASS-EVENTS",
    body = [[CLASS-EVENTS ${1:evt_name}.]],
  },
  alias = {
    trig = "alias",
    name = "ALIASES",
    body = [[ALIASES ${1:alias} FOR ${2:if_name}~${3:member}.]],
  },
  intf = {
    trig = "intf",
    name = "INTERFACES",
    body = [[INTERFACES ${1:if_name}.]],
  },
  redef = {
    trig = "redef",
    name = "METHODS REDEFINITION",
    body = [[METHODS ${1:method} REDEFINITION.]],
  },

  -- ── Estructuras de control que faltaban ──
  modu = {
    trig = "module",
    name = "MODULE-ENDMODULE",
    body = [[MODULE ${1:name} ${2:INPUT}.\n  ${0}\nENDMODULE.]],
  },
  func = {
    trig = "func",
    name = "FUNCTION-ENDFUNCTION",
    body = [[FUNCTION ${1:name}.\n  ${0}\nENDFUNCTION.]],
  },
  sos = {
    trig = "sos",
    name = "START-OF-SELECTION",
    body = [[START-OF-SELECTION.\n  ${0}]],
  },

  -- ── Sintaxis nueva 7.40+ (constructores, con el espaciado correcto que exige SAP) ──
  value = {
    trig = "value",
    name = "VALUE #( )",
    body = [[VALUE ${1:#}( ${0} )]],
  },
  valuet = {
    trig = "valuet",
    name = "VALUE tabla( ( fila ) )",
    body = [[VALUE ${1:ty_tab}( ( ${2:col1} = ${3:val1} ) )]],
  },
  cond = {
    trig = "cond",
    name = "COND #( WHEN THEN ELSE )",
    body = [[COND ${1:#}( WHEN ${2:condition} THEN ${3:a} ELSE ${4:b} )]],
  },
  switch = {
    trig = "switch",
    name = "SWITCH #( WHEN THEN )",
    body = [[SWITCH ${1:#}( ${2:operand}\n  WHEN ${3:value} THEN ${4:result}\n  ELSE ${5:default} )]],
  },
  new = {
    trig = "new",
    name = "NEW #( )",
    body = [[NEW ${1:zcl_class}( ${0} )]],
  },
  conv = {
    trig = "conv",
    name = "CONV #( )",
    body = [[CONV ${1:type}( ${2:value} )]],
  },
  refn = {
    trig = "ref",
    name = "REF #( )",
    body = [[REF ${1:#}( ${2:variable} )]],
  },
  reduce = {
    trig = "reduce",
    name = "REDUCE #( INIT FOR NEXT )",
    body = [[REDUCE ${1:i}( INIT ${2:s} = 0 FOR ${3:wa} IN ${4:]] .. n.itab .. [[table} NEXT ${2:s} = ${2:s} + ${5:wa-field} )]],
  },
  filter = {
    trig = "filter",
    name = "FILTER #( WHERE )",
    body = [[FILTER ${1:#}( ${2:]] .. n.itab .. [[table} WHERE ${3:field} > 0 )]],
  },
  corr = {
    trig = "corr",
    name = "CORRESPONDING #( MAPPING )",
    body = [[CORRESPONDING ${1:#}( ${2:source} MAPPING ${3:target} = ${4:source_field} )]],
  },
  loopa = {
    trig = "loopa",
    name = "LOOP ASSIGNING FIELD-SYMBOL",
    body = [[LOOP AT ${1:]] .. n.itab .. [[table} ASSIGNING FIELD-SYMBOL(<${2:fs}>).\n  ${0}\nENDLOOP.]],
  },
  loopd = {
    trig = "loopd",
    name = "LOOP INTO DATA()",
    body = [[LOOP AT ${1:]] .. n.itab .. [[table} INTO DATA(${2:]] .. n.struct .. [[row}).\n  ${0}\nENDLOOP.]],
  },
}
