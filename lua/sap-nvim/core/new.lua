-- sap-nvim.core.new
-- Asistente de creación de objetos ABAP (como Ctrl+N en Eclipse ADT)
-- Uso: :SapNew o <leader>an

local M = {}

-- ─── Templates por tipo de objeto ABAP ──────────────────────────────────────

local templates = {
  program = {
    name = "Programa ABAP",
    ext = "abap",
    desc = "REPORT clásico",
    template = function(name)
      return string.format([[
REPORT %s.

*-----------------------------------------------------------------------
* Descripción:
*-----------------------------------------------------------------------

START-OF-SELECTION.
  WRITE: / 'Hola desde %s'.
]], name, name)
    end,
    sapcli = function(name) return { "sapcli", "program", "create", name } end,
  },
  class = {
    name = "Clase ABAP",
    ext = "cls",
    desc = "Class Builder (SE24)",
    template = function(name)
      return string.format([[
CLASS %s DEFINITION PUBLIC.
  PUBLIC SECTION.
    METHODS: constructor.
  PROTECTED SECTION.
  PRIVATE SECTION.
ENDCLASS.

CLASS %s IMPLEMENTATION.
  METHOD constructor.
    super->constructor( ).
  ENDMETHOD.
ENDCLASS.
]], name, name)
    end,
    sapcli = function(name) return { "sapcli", "class", "create", name } end,
  },
  interface = {
    name = "Interface ABAP",
    ext = "intf",
    desc = "Interface pública",
    template = function(name)
      return string.format([[
INTERFACE %s PUBLIC.
  METHODS: say_hello RETURNING VALUE(rv_msg) TYPE string.
ENDINTERFACE.
]], name)
    end,
    sapcli = function(name) return { "sapcli", "interface", "create", name } end,
  },
  include = {
    name = "Include ABAP",
    ext = "abap",
    desc = "Include de programa",
    template = function(name)
      return string.format([[
*&---------------------------------------------------------------------*
*& Include %s
*&---------------------------------------------------------------------*

"], name)
    end,
    sapcli = function(name) return { "sapcli", "include", "create", name } end,
  },
  function_group = {
    name = "Function Group",
    ext = "fugr",
    desc = "Grupo de funciones (SE37)",
    template = function(name)
      return string.format([[
FUNCTION-POOL %s.

*-----------------------------------------------------------------------
* Funciones disponibles:
*   %s_DEMO
*-----------------------------------------------------------------------
]], name:upper(), name:upper())
    end,
    sapcli = function(name) return { "sapcli", "functiongroup", "create", name } end,
  },
  function_module = {
    name = "Function Module",
    ext = "func",
    desc = "Módulo de función",
    template = function(name, fgroup)
      fgroup = fgroup or "ZDEMO"
      return string.format([[
FUNCTION %s.
*"----------------------------------------------------------------------
*"*"Interfase local:
*"  IMPORTING
*"     VALUE(IV_PARAM) TYPE  STRING OPTIONAL
*"  EXPORTING
*"     VALUE(EV_RESULT) TYPE  STRING
*"----------------------------------------------------------------------
  EV_RESULT = |Hola desde { iv_param }|.
ENDFUNCTION.
]], name)
    end,
    sapcli = function(name) return { "sapcli", "functionmodule", "create", name } end,
  },
  table = {
    name = "Tabla de BD",
    ext = "tabl",
    desc = "Data Dictionary (SE11)",
    template = function(name)
      return string.format([[
@EndUserText.label : 'Tabla %s'
@AbapCatalog.enhancement.category : #NOT_EXTENSIBLE
@AbapCatalog.tableCategory : #TRANSPARENT
@AbapCatalog.deliveryClass : #A
@AbapCatalog.dataMaintenance : #LIMITED
define table %s {
  key mandt : mandt not null;
  key %s   : sysuuid_x16 not null;
  created_at  : timestampl;
  created_by  : uname;
}
]], name, name, name)
    end,
    sapcli = function(name) return { "sapcli", "table", "create", name } end,
  },
  structure = {
    name = "Estructura",
    ext = "stru",
    desc = "Data Dictionary (SE11)",
    template = function(name)
      return string.format([[
@EndUserText.label : 'Estructura %s'
define structure %s {
  field1 : char10;
  field2 : char40;
  field3 : numc10;
}
]], name, name)
    end,
    sapcli = function(name) return { "sapcli", "structure", "create", name } end,
  },
  data_element = {
    name = "Data Element",
    ext = "dtel",
    desc = "Data Dictionary (SE11)",
    template = function(name)
      return string.format([[
@EndUserText.label : 'Elemento de datos %s'
define data element %s {
  type char40;
  length 40;
  decimals 0;
}
]], name, name)
    end,
    sapcli = function(name) return { "sapcli", "dataelement", "create", name } end,
  },
  domain = {
    name = "Dominio",
    ext = "dome",
    desc = "Data Dictionary (SE11)",
    template = function(name)
      return string.format([[
@EndUserText.label : 'Dominio %s'
define domain %s {
  type char1;
  length 1;
  decimals 0;
  output_style : #UPPERCASE;
  fixed_values : (
    value 'X' label 'Sí',
    value ' ' label 'No'
  );
}
]], name, name)
    end,
    sapcli = function(name) return { "sapcli", "domain", "create", name } end,
  },
  cds_view = {
    name = "CDS View",
    ext = "ddls",
    desc = "Core Data Services",
    template = function(name)
      return "@AbapCatalog.sqlViewName: '" .. name .. "'\n"
        .. "@AccessControl.authorizationCheck: #CHECK\n"
        .. "@EndUserText.label: 'Vista CDS " .. name .. "'\n"
        .. "define view " .. name .. "\n"
        .. "  as select from <tabla>\n"
        .. "{\n"
        .. "  key <campo>\n"
        .. "}"
    end,
    sapcli = function(name) return { "sapcli", "ddl", "create", name } end,
  },
  cds_behavior = {
    name = "CDS Behavior",
    ext = "bdef",
    desc = "Behavior Definition",
    template = function(name)
      return "managed implementation for <entity>.\n"
        .. "define behavior for " .. name .. " alias <alias>\n"
        .. "  persistent table <tabla>\n"
        .. "  lock master\n"
        .. "  etag master <campo>\n"
        .. "{\n"
        .. "  create;\n"
        .. "  update;\n"
        .. "  delete;\n"
        .. "}"
    end,
  },
  report = {
    name = "Report ABAP (list)",
    ext = "abap",
    desc = "Programa con SELECT",
    template = function(name)
      return "REPORT " .. name .. ".\n"
        .. "\n"
        .. "TABLES: <tabla>.\n"
        .. "\n"
        .. "SELECTION-SCREEN BEGIN OF BLOCK b1 WITH FRAME TITLE TEXT-001.\n"
        .. "  PARAMETERS: p_param TYPE <campo>.\n"
        .. "SELECTION-SCREEN END OF BLOCK b1.\n"
        .. "\n"
        .. "START-OF-SELECTION.\n"
        .. "  SELECT *\n"
        .. "    FROM <tabla>\n"
        .. "    INTO TABLE @DATA(lt_data)\n"
        .. "    UP TO 100 ROWS.\n"
        .. "  IF sy-subrc = 0.\n"
        .. "    cl_demo_output=>display( lt_data ).\n"
        .. "  ENDIF."
    end,
  },
}

-- ─── Lista ordenada para el picker ──────────────────────────────────────────

local function get_picker_items()
  local items = {}
  local order = {
    "program", "class", "interface", "include",
    "table", "structure", "data_element", "domain",
    "cds_view", "cds_behavior",
    "function_group", "function_module",
    "report",
  }
  for _, key in ipairs(order) do
    local t = templates[key]
    if t then
      table.insert(items, {
        label = string.format("%-20s  %s", t.name, t.desc),
        key = key,
      })
    end
  end
  return items
end

-- ─── Crear archivo con template ─────────────────────────────────────────────

local function create_file(obj_type, obj_name, extra)
  local t = templates[obj_type]
  if not t then
    vim.notify("[sap-nvim] Tipo de objeto no válido: " .. obj_type, vim.log.levels.ERROR)
    return
  end

  local target_dir = vim.fn.getcwd()
  local filename = target_dir .. "/" .. obj_name .. "." .. t.ext

  -- Verificar si ya existe
  local f = io.open(filename, "r")
  if f then
    f:close()
    vim.notify("[sap-nvim] ⚠️ '" .. filename .. "' ya existe", vim.log.levels.WARN)
    vim.cmd("edit " .. filename)
    return
  end

  -- Generar contenido usando el template del objeto
  local content
  if obj_type == "function_module" then
    content = t.template(obj_name, extra or "ZDEMO")
  else
    content = t.template(obj_name)
  end

  -- Escribir archivo
  local f = io.open(filename, "w")
  if not f then
    vim.notify("[sap-nvim] ❌ No se pudo crear '" .. filename .. "'", vim.log.levels.ERROR)
    return
  end
  f:write(content)
  f:close()

  vim.notify(string.format("[sap-nvim] ✅ %s creado: %s", t.name, filename))
  vim.cmd("edit " .. filename)
end

-- ─── Picker principal ────────────────────────────────────────────────────────

function M.new_object()
  vim.ui.select(get_picker_items(), {
    prompt = "📦 sap-nvim: Nuevo objeto ABAP (Ctrl+N style):",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end

    -- Preguntar nombre del objeto
    vim.ui.input({
      prompt = "Nombre del objeto (" .. templates[choice.key].ext .. "): ",
      default = "Z",
    }, function(name)
      if not name or name == "" then return end
      name = name:upper()

      -- Para function_module, preguntar también el function group
      if choice.key == "function_module" then
        vim.ui.input({
          prompt = "Function Group: ",
          default = "ZDEMO",
        }, function(fgroup)
          create_file(choice.key, name, fgroup:upper())
        end)
        return
      end

      create_file(choice.key, name)
    end)
  end)
end

-- ─── Comando :SapNew ────────────────────────────────────────────────────────

function M.setup()
  vim.api.nvim_create_user_command("SapNew", function()
    M.new_object()
  end, { desc = "sap-nvim: Nuevo objeto ABAP (Ctrl+N style)" })

  vim.keymap.set("n", "<leader>an", function()
    M.new_object()
  end, { desc = "ABAP: Nuevo objeto" })
end

return M
