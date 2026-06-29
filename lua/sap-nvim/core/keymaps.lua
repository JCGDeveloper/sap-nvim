-- lua/sap-nvim/core/keymaps.lua
local M = {}
local sapcli = require("sap-nvim.core.sapcli")

function M.setup(opts)
	opts = opts or {}

	local function register_which_key_groups()
		local ok, wk = pcall(require, "which-key")
		if not ok or not wk then
			return
		end
		if type(wk.add) == "function" then
			wk.add({
				{ "<leader>a", group = "SAP" },
				{ "<leader>al", group = "SAP Help" },
			})
		elseif type(wk.register) == "function" then
			wk.register({
				a = {
					name = "SAP",
					l = { name = "SAP Help" },
				},
			}, { prefix = "<leader>" })
		end
	end
	register_which_key_groups()

	-- ====================================================================
	-- REGISTRO DE COMANDOS (Para que existan desde el minuto 1)
	-- ====================================================================
	vim.api.nvim_create_user_command("SapActivateAll", function()
		require("sap-nvim.core.adt").activate_ui()
	end, { desc = "sap-nvim: Gestor de activación masiva" })
	-- ====================================================================

	vim.keymap.set("n", "<leader>aT", function()
		local obj = vim.fn.expand("%:t:r")
		if obj == "" then
			vim.notify("sap-nvim: Guardá el archivo primero", vim.log.levels.WARN)
			return
		end
		vim.cmd("write")
		vim.notify("[sap-nvim] Ejecutando tests de " .. obj .. "...")
		local aunit_lines = {}
		sapcli.jobstart({ "sapcli", "aunit", "run", "class", obj }, {
			on_stdout = function(_, data)
				for _, line in ipairs(data) do
					if line ~= "" then
						table.insert(aunit_lines, line)
					end
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

	vim.keymap.set("n", "<leader>aK", function()
		require("sap-nvim.core.quality").run_atc("")
	end, { desc = "ABAP: Ejecutar ATC" })

	vim.keymap.set("n", "<leader>ah", function()
		vim.notify(
			[[
sap-nvim atajos:
  <leader>ah   Ayuda
  <leader>aF   Formatear (uppercase + indent)
  <leader>aT   Tests unitarios (AUnit)
  <leader>aK   Quality panel (ATC)
  <leader>aqp  Quality panel (ATC + AUnit objeto)
  <leader>aqh  Historial local de calidad
  <leader>aqw  Worklist ATC con filtros (:SapAtcWorklist)
  <leader>ai   Objetos inactivos
  <leader>ad   Debuggear (vsp)
  <leader>db   Limpiar breakpoints del objeto/buffer actual (:SapDapClearBreakpoints)
  <leader>dB   Limpiar breakpoints raíz + includes relacionados (:SapDapClearBreakpointsRecursive)
 <leader>aR   Ejecutar programa/report en WebGUI (:SapRun)
  <leader>e    Repository Explorer SAP del objeto/paquete actual (:SapRepositoryToggle)
  <leader>aW   SAP Home dashboard (:SapHome)

  OBJETOS:
  <leader>aa   Activar SOLO objeto actual (:SapActivate)
  <leader>aA   Activar raíz + includes relacionados (:SapActivateRecursive)
  <leader>aG   Gestor global de inactivos (:SapActivateAll)
  <leader>au   Subir (push) objeto a SAP sin activar (:SapPush)
  <leader>ao   Outline del objeto: saltar a metodo/form/type/include (:SapOutline)
  <leader>ag   Ir a definicion bajo el cursor (gd): include/form/variable/objeto
  gd           = <leader>ag (en buffers ABAP)
  -            Volver al archivo anterior de la navegacion (:SapBack)
  <leader>an   Crear objeto ABAP EN SAP y abrirlo (:SapNew)
  <leader>aX   Borrar objeto remoto (:SapDelete, desactivado salvo opt-in)
  <leader>aw   Where-used list → quickfix
  <leader>aD   Diff local vs sistema SAP (:SapDiff)
  <leader>aV   Revisiones/versiones ADT (:SapRevisions)
  :SapRevisionRoutes  Probar rutas ADT de revisiones (solo lectura)
  :SapRevisionDiff    Diff local vs revision si ADT devuelve fuente

  INTELIGENCIA ADT (como VSCode):
  (auto)       Completado al escribir clase/metodo + params al abrir '(' (blink)
  <C-x><C-o>   Completado manual (:SapComplete)
  K            Hover: firma + documentacion (2a K entra, hjkl scroll) (:SapHover)
  <leader>aH   Panel lateral de documentacion oficial SAP (:SapHelpPanel)
  <leader>a?   Popup de documentacion oficial SAP (:SapHelp)
  <leader>a/   Buscar documentacion/objetos oficiales SAP (:SapHelpSearch)
  <leader>al   Grupo SAP Help en which-key; panel: 1-4 secciones, o abre, m favorito, s busca, / filtra, c limpia
  gd           Ir a definicion (incluye clases/metodos del sistema, ADT)
  gy           Ir al TIPO del dato (:SapGotoType)
  gr           Referencias del simbolo → picker (:SapReferences)
  (auto)       Syntax check REAL de SAP al guardar (diagnosticos con contexto del sistema)
  <leader>ae   Lista navegable de errores de sintaxis SAP (estilo Problems de VSCode) (:SapCheck)
  <leader>aq   Quick fixes ABAP/ADT/locales desde cursor o quickfix (:SapQuickfix)
  <leader>aQ   Preview de quick fix local sin tocar el buffer (:SapQuickfixPreview)
  <leader>ar   Refactors offline con preview (:SapRefactor)
  <leader>aF   Formatear con el Pretty Printer de SAP (objetos remotos)

  PLANTILLAS (<leader>aP ...):
  <leader>aPi  Insertar plantilla (picker con preview)            (:SapTemplate)
  <leader>aPs  Guardar buffer como plantilla (en visual: la sel.) (:SapTemplateSave)
  <leader>aPd  Mostrar la carpeta de plantillas                   (:SapTemplatesDir)
  <leader>aPe  Abrir/editar la carpeta de plantillas              (:SapTemplateEdit)

  DATOS / TABLAS:
  <leader>avt  Ver definicion DDIC de tabla (:SapTable)
  <leader>avd  Ver datos de la tabla BAJO EL CURSOR (split; q/- cierra)
  <leader>avq  Ejecutar OpenSQL y ver resultados (:SapData)

  PAQUETES / SISTEMA:
  <leader>afs  Buscar objeto en sistema (:SapSearch)
  <leader>afb  Explorar paquete (:SapBrowse)
  <leader>afr  Repository Explorer persistente (:SapRepositoryToggle)
  <leader>alg  Logs locales de sesión (:SapLogs)
  <leader>asD  Dumps del sistema (:SapDumps, solo lectura)
  <leader>ack  Checkout paquete completo (:SapCheckout)

  TRANSPORTES:
  <leader>atl  Listar ordenes (:SapTransports)
  <leader>atL  Listar TODAS las ordenes del sistema (:SapListAllTransports)
  <leader>atc  Crear orden (:SapTransportCreate)
  <leader>atr  Liberar orden (:SapTransportRelease)

  CONEXION:
  <leader>asl  Conexion / login SAP (valida la contrasena) (:SapLogin)
  <leader>asg  Abrir SAP GUI
  <leader>aso  Objeto en SAP GUI
  <leader>asc  Configurar conexiones (:SapSetup, formato kubeconfig)
  <leader>asd  Diagnostico SAP solo-lectura (:SapDoctor)
 <leader>asi  Info conexion activa (:SapStatus)
    ]],
			vim.log.levels.INFO
		)
	end, { desc = "ABAP: Ayuda" })

	vim.keymap.set("n", "<leader>aF", function()
		require("sap-nvim.core.formatter").format_file()
	end, { desc = "ABAP/CDS: Format file" })

	vim.keymap.set("n", "<leader>ae", function()
		require("sap-nvim.core.intel").check_list()
	end, { desc = "ABAP: Errores de sintaxis SAP (lista navegable, como VSCode)" })

	local function find_sapgui()
		local paths = { "/Applications/SAP GUI.app", "/Applications/SAPGUI.app" }
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
			vim.fn.jobstart({ "open", app })
			vim.notify(string.format("sap-nvim: SAP GUI abierto. Busca %s en SE80", obj))
		else
			vim.notify("sap-nvim: SAP GUI no encontrado", vim.log.levels.ERROR)
		end
	end, { desc = "ABAP: Abrir objeto en SAP GUI" })

	vim.keymap.set("n", "<leader>asl", function()
		require("sap-nvim.core.connection").choose()
	end, { desc = "ABAP: Conexión / login SAP (valida contraseña)" })

	local function abap_uncomment_star(l1, l2)
		for ln = l1, l2 do
			local s = vim.fn.getline(ln)
			local new = s:gsub("^(%s*)%*%s?", "%1")
			if new ~= s then
				vim.fn.setline(ln, new)
			end
		end
	end
	vim.keymap.set("n", "<leader>a*", function()
		local l = vim.fn.line(".")
		abap_uncomment_star(l, l)
	end, { desc = "ABAP: quitar comentario * (descomentar línea)" })
	vim.keymap.set("x", "<leader>a*", function()
		local a, b = vim.fn.line("v"), vim.fn.line(".")
		if a > b then
			a, b = b, a
		end
		abap_uncomment_star(a, b)
		vim.cmd("normal! \27")
	end, { desc = "ABAP: quitar comentario * de la selección (descomentar)" })

	vim.keymap.set("n", "<leader>aw", function()
		require("sap-nvim.core.whereused").whereused()
	end, { desc = "ABAP: Where-used list" })

	vim.keymap.set("n", "<leader>ack", function()
		require("sap-nvim.core.checkout").checkout_package()
	end, { desc = "ABAP: Checkout paquete SAP" })

	vim.keymap.set("n", "<leader>ad", function()
		local ok = pcall(vim.cmd, "SapDap")
		if not ok then
			vim.notify("sap-nvim: nvim-dap no está disponible o :SapDap no se registró.", vim.log.levels.WARN)
		end
	end, { desc = "ABAP: Debuggear" })

	vim.keymap.set("n", "<leader>atL", function()
		local ok = pcall(vim.cmd, "SapListAllTransports")
		if not ok then
			vim.notify("sap-nvim: :SapListAllTransports no se registró.", vim.log.levels.WARN)
		end
	end, { desc = "SAP: Ver todas las órdenes de transporte" })

	-- 🎯 MAPEOS COMBINADOS ABAP + CDS (Aquí se configuran los atajos finales)
	local abap_maps = {
		{ "<leader>aa", "<cmd>SapActivate<cr>", "Activar objeto actual" },
		{ "<leader>aA", "<cmd>SapActivateRecursive<cr>", "Activar raíz + includes" },
		{ "<leader>aG", "<cmd>SapActivateAll<cr>", "Gestor global de activación" },
		{ "<C-F3>", "<cmd>SapActivate<cr>", "Activar objeto actual (Ctrl+F3)" },
		{ "<leader>au", "<cmd>SapPush<cr>", "Subir (push) sin activar" },
		{ "<leader>aX", "<cmd>SapDelete<cr>", "Borrar objeto remoto (requiere opt-in)" },
		{ "<leader>ao", "<cmd>SapOutline<cr>", "Outline del objeto" },
		{ "<leader>ag", "<cmd>SapGotoDef<cr>", "Ir a definición" },
		{ "<leader>aw", "<cmd>SapWhereUsed<cr>", "Where-used" },
		{ "<leader>ar", "<cmd>SapRefactor<cr>", "Refactors offline con preview" },
		{ "<leader>aV", "<cmd>SapRevisions<cr>", "Revisiones/versiones ADT" },
		{ "<leader>ai", "<cmd>SapInactive<cr>", "Objetos inactivos" },
		{ "<leader>an", "<cmd>SapNew<cr>", "Nuevo objeto en SAP" },
		{ "<leader>aT", "<cmd>SapAUnit<cr>", "Tests unitarios (AUnit)" },
		{ "<leader>aK", "<cmd>SapAtcPanel<cr>", "Quality panel (ATC)" },
		{ "<leader>aqp", "<cmd>SapQuality<cr>", "Quality panel" },
		{ "<leader>aqh", "<cmd>SapQualityHistory<cr>", "Historial quality" },
		{ "<leader>aH", "<cmd>SapHelpPanel<cr>", "Documentacion oficial SAP (panel)" },
		{ "<leader>a?", "<cmd>SapHelp<cr>", "Documentacion oficial SAP (popup)" },
		{ "<leader>a/", "<cmd>SapHelpSearch<cr>", "Buscar documentacion oficial SAP" },
		{ "<leader>alh", "<cmd>SapHelp<cr>", "Help: popup oficial SAP" },
		{ "<leader>alp", "<cmd>SapHelpPanel<cr>", "Help: panel oficial SAP" },
		{ "<leader>alf", "<cmd>SapHelpPanelSearch<cr>", "Help: buscar en panel" },
		{ "<leader>als", "<cmd>SapHelpSearch<cr>", "Help: buscar SAP/ADT" },
		{ "<leader>alo", "<cmd>SapHelpOpen<cr>", "Help: abrir enlace oficial" },
		{ "<leader>alb", "<cmd>SapHelpBrowser<cr>", "Help: diagnosticar navegador" },
		{ "<leader>alr", "<cmd>SapHelpRoutes<cr>", "Help: validar busqueda ADT" },
		{ "<leader>avt", "<cmd>SapTable<cr>", "Ver definición de tabla" },
		{ "<leader>avd", "<cmd>SapTableData<cr>", "Ver datos de tabla" },
		{ "<leader>avq", "<cmd>SapData<cr>", "Ejecutar OpenSQL" },
		{ "<leader>e", "<cmd>SapRepositoryToggle<cr>", "Repository Explorer SAP" },
		{ "<leader>aW", "<cmd>SapHome<cr>", "SAP Home dashboard" },
		{ "<leader>alg", "<cmd>SapLogs<cr>", "Logs locales de sesión" },
		{ "<leader>asD", "<cmd>SapDumps<cr>", "Dumps del sistema" },
	}

	local cds_maps = {
		{ "<leader>cp", "<cmd>SapCdsPreview<cr>", "Preview Datos" },
		{ "<leader>cs", "<cmd>SapCdsSql<cr>", "Ver SQL Nativo" },
		{ "<leader>co", "<cmd>SapCdsOData<cr>", "Generar OData" },
		{ "<leader>cg", "<cmd>SapCdsGraph<cr>", "Grafo RAP" },
		{ "<leader>cc", "<cmd>SapSearchCds<cr>", "Buscar/Abrir CDS (en vivo)" },
	}

	vim.api.nvim_create_autocmd("FileType", {
		pattern = { "abap", "cds", "acds", "abapcds", "ddls" },
		group = vim.api.nvim_create_augroup("sap_nvim_keymaps_abap", { clear = true }),
		callback = function(ev)
			for _, m in ipairs(abap_maps) do
				if m[1] == "<C-F3>" then
					vim.keymap.set(
						{ "n", "i" },
						m[1],
						m[2],
						{ buffer = ev.buf, silent = true, desc = "ABAP: " .. m[3] }
					)
				else
					vim.keymap.set("n", m[1], m[2], { buffer = ev.buf, silent = true, desc = "ABAP: " .. m[3] })
				end
			end
			for _, m in ipairs(cds_maps) do
				vim.keymap.set("n", m[1], m[2], { buffer = ev.buf, silent = true, desc = "CDS: " .. m[3] })
			end
		end,
	})
end

return M
