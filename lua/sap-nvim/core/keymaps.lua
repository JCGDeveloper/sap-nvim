-- sap-nvim.core.keymaps
-- Atajos básicos para ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- TDD: Ejecutar tests unitarios ABAP vía sapcli
  vim.keymap.set("n", "<leader>aT", function()
    local obj = vim.fn.expand("%:t:r")
    if obj == "" then
      vim.notify("sap-nvim: Guardá el archivo primero", vim.log.levels.WARN)
      return
    end
    vim.cmd("write")
    vim.notify("[sap-nvim] Ejecutando tests de " .. obj .. "...")
    local aunit_lines = {}
    vim.fn.jobstart({ "sapcli", "aunit", "run", "class", obj }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(aunit_lines, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if #aunit_lines > 0 then
            vim.notify("[sap-nvim] AUnit:\n" .. table.concat(aunit_lines, "\n"))
          end
          if code == 0 then
            vim.notify("[sap-nvim] Tests OK", vim.log.levels.INFO)
          else
            vim.notify("[sap-nvim] Tests fallaron (code " .. code .. ")", vim.log.levels.WARN)
          end
        end)
      end,
    })
  end, { desc = "ABAP: Ejecutar tests unitarios" })

  -- ATC: Ejecutar ABAP Test Cockpit
  vim.keymap.set("n", "<leader>aK", function()
    require("sap-nvim.core.adt").run_atc()
  end, { desc = "ABAP: Ejecutar ATC" })

  -- Help actualizada
  vim.keymap.set("n", "<leader>ah", function()
    vim.notify([[
sap-nvim atajos:
  <leader>ah   Ayuda
  <leader>aF   Formatear (uppercase + indent)
  <leader>aT   Tests unitarios (AUnit)
  <leader>aK   Quality check (ATC)
  <leader>ai   Objetos inactivos
  <leader>ad   Debuggear (vsp)

  OBJETOS:
  <leader>aa   Activar objeto (sube antes si es remoto) → errores/warnings a quickfix
  <leader>au   Subir (push) objeto a SAP sin activar (:SapPush)
  <leader>ao   Outline del objeto: saltar a metodo/form/type/include (:SapOutline)
  <leader>ag   Ir a definicion bajo el cursor (gd): include/form/variable/objeto
  gd           = <leader>ag (en buffers ABAP)
  -            Volver al archivo anterior de la navegacion (:SapBack)
  <leader>an   Crear objeto ABAP EN SAP y abrirlo (:SapNew)
  <leader>aX   Borrar el objeto actual del sistema (:SapDelete)
  <leader>aw   Where-used list → quickfix
  <leader>aD   Diff local vs sistema SAP (:SapDiff)

  INTELIGENCIA ADT (como VSCode):
  (auto)       Completado al escribir clase/metodo + params al abrir '(' (blink)
  <C-x><C-o>   Completado manual (:SapComplete)
  K            Hover: firma + documentacion (2a K entra, hjkl scroll) (:SapHover)
  gd           Ir a definicion (incluye clases/metodos del sistema, ADT)
  gy           Ir al TIPO del dato (:SapGotoType)
  gr           Referencias del simbolo → picker (:SapReferences)
  (auto)       Syntax check de SAP en vivo (diagnosticos, al escribir/guardar) (:SapCheck)
  <leader>aF   Formatear con el Pretty Printer de SAP (objetos remotos)

  PLANTILLAS (<leader>aP ...):
  <leader>aPi  Insertar plantilla (picker con preview)            (:SapTemplate)
  <leader>aPs  Guardar buffer como plantilla (en visual: la sel.) (:SapTemplateSave)
  <leader>aPd  Mostrar la carpeta de plantillas                   (:SapTemplatesDir)
  <leader>aPe  Abrir/editar la carpeta de plantillas              (:SapTemplateEdit)
               Vars dinamicas: $OBJECT $PACKAGE $SHORTTEXT $METHOD $AUTHOR $DATE $YEAR ...
               Al guardar puedes parametrizar otros nombres (grupo/tabla) como huecos.
               Guia completa: docs/PLANTILLAS.md

  DATOS / TABLAS:
  <leader>avt  Ver definicion DDIC de tabla (:SapTable)
  <leader>avd  Ver datos de la tabla BAJO EL CURSOR (split; q/- cierra)
  <leader>avq  Ejecutar OpenSQL y ver resultados (:SapData)

  PAQUETES / SISTEMA:
  <leader>afs  Buscar objeto en sistema (:SapSearch)
  <leader>afb  Explorar paquete (:SapBrowse)
  <leader>ack  Checkout paquete completo (:SapCheckout)

  TRANSPORTES:
  <leader>atl  Listar ordenes (:SapTransports)
  <leader>atc  Crear orden (:SapTransportCreate)
  <leader>atr  Liberar orden (:SapTransportRelease)

  CONEXION:
  <leader>asg  Abrir SAP GUI
  <leader>aso  Objeto en SAP GUI
  <leader>asc  Configurar conexiones (:SapSetup, formato kubeconfig)
  <leader>asd  Diagnostico SAP solo-lectura (:SapDoctor)
  <leader>asi  Info conexion activa (:SapStatus)
    ]], vim.log.levels.INFO)
  end, { desc = "ABAP: Ayuda" })

  -- Formatear ABAP con formateador nativo (uppercase + indentación)
  -- Dispatcher handles ABAP vs CDS automatically by file extension
  vim.keymap.set("n", "<leader>aF", function()
    require("sap-nvim.core.formatter").format_file()
  end, { desc = "ABAP/CDS: Format file" })

  -- SAP GUI integration
  local function find_sapgui()
    local paths = {
      "/Applications/SAP GUI.app",
      "/Applications/SAPGUI.app",
    }
    for _, p in ipairs(paths) do
      local f = io.open(p .. "/Contents/Info.plist", "r")
      if f then
        f:close()
        return p
      end
    end
    return nil
  end

  vim.keymap.set("n", "<leader>asg", function()
    local app = find_sapgui()
    if app then
      vim.fn.jobstart({ "open", app })
      vim.notify("sap-nvim: Abriendo SAP GUI...")
    else
      vim.notify("sap-nvim: SAP GUI no encontrado", vim.log.levels.ERROR)
    end
  end, { desc = "ABAP: Abrir SAP GUI" })

  vim.keymap.set("n", "<leader>aso", function()
    local app = find_sapgui()
    if app then
      local obj = vim.fn.expand("%:t:r")
      local tx = "SE80"
      vim.fn.jobstart({ "open", app })
      vim.notify(string.format("sap-nvim: SAP GUI abierto. Busca %s en %s", obj, tx))
    else
      vim.notify("sap-nvim: SAP GUI no encontrado", vim.log.levels.ERROR)
    end
  end, { desc = "ABAP: Abrir objeto en SAP GUI" })

  -- Activar objeto ABAP. Para objetos remotos sube antes (push) implícitamente,
  -- igual que la extensión de VSCode al guardar; errores/warnings al quickfix.
  vim.keymap.set("n", "<leader>aa", function()
    require("sap-nvim.core.source").activate()
  end, { desc = "ABAP: Activar objeto (sube antes si es remoto, jump-to-error)" })

  -- Where-used list
  vim.keymap.set("n", "<leader>aw", function()
    require("sap-nvim.core.whereused").whereused()
  end, { desc = "ABAP: Where-used list" })

  -- Checkout de paquete completo
  vim.keymap.set("n", "<leader>ack", function()
    require("sap-nvim.core.checkout").checkout_package()
  end, { desc = "ABAP: Checkout paquete SAP" })

  -- Debug: Iniciar depurador ABAP interactivo (vsp)
  vim.keymap.set("n", "<leader>ad", function()
    require("sap-nvim.core.debugger").debug_current()
  end, { desc = "ABAP: Debuggear" })

  -- ── Override BUFFER-LOCAL en buffers ABAP ──────────────────────────────────
  -- El prefijo <leader>a choca con plugins de IA (code-companion/opencode mapean
  -- <leader>aa, an, ai...). Los mapeos globales de arriba pueden quedar pisados por
  -- esos plugins según el orden de carga. Aquí re-asignamos los atajos ABAP como
  -- BUFFER-LOCAL en filetype abap: en un buffer ABAP ganan siempre (preceden a los
  -- globales); fuera de ABAP, los plugins de IA siguen funcionando con normalidad.
  local abap_maps = {
    { "<leader>aa",  "<cmd>SapActivate<cr>",   "Activar (sube antes si es remoto)" },
    { "<leader>au",  "<cmd>SapPush<cr>",       "Subir (push) sin activar" },
    { "<leader>aX",  "<cmd>SapDelete<cr>",     "Borrar objeto del sistema" },
    { "<leader>ao",  "<cmd>SapOutline<cr>",    "Outline del objeto" },
    { "<leader>ag",  "<cmd>SapGotoDef<cr>",    "Ir a definición" },
    { "<leader>aw",  "<cmd>SapWhereUsed<cr>",  "Where-used" },
    { "<leader>ai",  "<cmd>SapInactive<cr>",   "Objetos inactivos" },
    { "<leader>an",  "<cmd>SapNew<cr>",        "Nuevo objeto en SAP" },
    { "<leader>aT",  "<cmd>SapAUnit<cr>",      "Tests unitarios (AUnit)" },
    { "<leader>avt", "<cmd>SapTable<cr>",      "Ver definición de tabla" },
    { "<leader>avd", "<cmd>SapTableData<cr>",  "Ver datos de tabla" },
    { "<leader>avq", "<cmd>SapData<cr>",       "Ejecutar OpenSQL" },
  }
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_keymaps_abap", { clear = true }),
    callback = function(ev)
      for _, m in ipairs(abap_maps) do
        vim.keymap.set("n", m[1], m[2], { buffer = ev.buf, silent = true, desc = "ABAP: " .. m[3] })
      end
    end,
  })
end

return M
