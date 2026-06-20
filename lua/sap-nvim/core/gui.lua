-- sap-nvim.core.gui
-- Ejecutar transaccion / abrir WebGUI (como el "Web Browser GUI" de VSCode)

local M = {}

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Abre una URL en el navegador de Windows desde WSL
local function open_url(url)
	notify("Lanzando navegador en Windows...", vim.log.levels.INFO)

	-- 1. Específico para WSL usando ruta absoluta de Windows
	if vim.fn.has("wsl") == 1 then
		-- Usamos la ruta absoluta a PowerShell para que no dependa del $PATH de Linux
		local ps_path = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
		local cmd = string.format([[%s -NoProfile -Command "Start-Process '%s'"]], ps_path, url)

		local out = vim.fn.system(cmd)
		if vim.v.shell_error ~= 0 then
			notify("Error al abrir navegador: " .. out, vim.log.levels.ERROR)
			-- Te copiamos la URL al portapapeles por si falla Windows
			vim.fn.setreg("+", url)
		end
		return
	end

	-- 2. Fallbacks para Linux Nativo o Mac
	if vim.ui and vim.ui.open then
		pcall(vim.ui.open, url)
		return
	end

	notify("No se pudo abrir automáticamente. URL copiada al portapapeles.", vim.log.levels.WARN)
	vim.fn.setreg("+", url)
end

local function base_client()
	local c = require("sap-nvim.core.adt_http").creds()
	if not c then
		notify("Sin conexion SAP (config.yml).", vim.log.levels.WARN)
		return nil
	end
	return c.base, c.client
end

-- Ejecuta una transaccion en WebGUI.
function M.run_transaction(tcode)
	local base, client = base_client()
	if not base then
		return
	end
	tcode = (tcode or ""):upper()
	if tcode == "" then
		return
	end
	notify("Abriendo transaccion " .. tcode .. " en WebGUI...")
	open_url(base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. client .. "&~transaction=" .. tcode)
end

-- Abre el WebGUI (pantalla inicial).
function M.web_gui()
	local base, client = base_client()
	if not base then
		return
	end
	open_url(base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. client)
end

-- Mapeo tipo de objeto -> transacción/campo/okcode para EJECUTAR en WebGUI. Idéntico a la
-- extensión de VSCode (SapGuiPanel.getTransactionInfo): PROG/P -> SE38, FUGR/FF -> SE37, etc.
local RUN_INFO = {
	program = { tx = "SE38", field = "RS38M-PROGRAMM", okcode = "STRT" },
	functiongroup = { tx = "SE37", field = "RS38L-NAME", okcode = "WB_EXEC" },
	functionmodule = { tx = "SE37", field = "RS38L-NAME", okcode = "WB_EXEC" },
	class = { tx = "SE24", field = "SEOCLASS-CLSNAME", okcode = "WB_EXEC" },
}

-- Emula EXACTAMENTE el encodeURIComponent de JS (lo que usa la extensión de VSCode): NO
-- codifica `A-Z a-z 0-9 - _ . ! ~ * ' ( )`. CLAVE doble:
--  • el `;` y el `=` del shortcut SÍ se codifican (`%3B`/`%3D`): sin ello el ITS parsea mal
--    la URL y el OKCODE (ejecutar/F8) no se aplica.
--  • el `*` se deja LITERAL (no `%2A`): el ITS exige que `~transaction` empiece por `*SE38`
--    para saltar la pantalla inicial; con `%2A` la ejecución aborta en el menú SAP.
local function enc(s)
	return (s:gsub("[^%w%-_.!~*'()]", function(c)
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Construye la URL WebGUI que EJECUTA el objeto (shortcut de transacción completo y codificado).
local function webgui_run_url(base, client, info, name)
	local shortcut = "*" .. info.tx .. " " .. info.field .. "=" .. name:upper() .. ";DYNP_OKCODE=" .. info.okcode
	return base
		.. "/sap/bc/gui/sap/its/webgui?~transaction="
		.. enc(shortcut)
		.. "&sap-client="
		.. client
		.. "&sap-language=EN&saml2=disabled"
end

-- Ejecuta el PROGRAMA/report del buffer actual (o el nombre dado) via SE38 en WebGUI.
-- Si es un INCLUDE, pregunta asíncronamente a SAP cuál es su Main Program antes de ejecutar.
function M.run_program(progname)
	local base, client = base_client()
	if not base then
		return
	end

	local function go(p)
		p = (p or ""):upper()
		if p == "" then
			return
		end
		notify("Ejecutando programa " .. p .. " (SE38) en WebGUI...")
		open_url(webgui_run_url(base, client, RUN_INFO.program, p))
	end

	-- 1. Si el usuario pasa un nombre explícito, vamos directo
	if progname then
		go(progname)
		return
	end

	-- 2. Deducimos el nombre del objeto. PREFERIMOS vim.b.sap_obj.name (el nombre real
	-- del objeto SAP). Si no, objtype.name() quita la doble extensión abapGit
	-- (zcar_x.prog.abap → ZCAR_X); NO usamos expand("%:t:r") a secas porque solo quita
	-- UNA extensión y deja ".PROG" pegado (rompe SE38: "ZCAR_X.PROG" no existe).
	local meta = vim.b.sap_obj
	local current_filename = ((meta and meta.name) or require("sap-nvim.core.objtype").name()):upper()

	-- 3. Si parece un Include (por su nombre o estructura), preguntamos a SAP por el padre
	-- Usamos la API de Includes para resolver el 'mainprogram'
	local adt_http = require("sap-nvim.core.adt_http")
	notify("Detectando programa principal...")

	adt_http.request_async({
		method = "GET",
		path = "/sap/bc/adt/programs/includes/" .. current_filename:lower() .. "/mainprograms",
		accept = "application/*",
	}, function(body, status)
		local mainname = body and body:match('adtcore:name="([^"]*)"')

		vim.schedule(function()
			if mainname and mainname ~= "" then
				notify("Programa principal detectado: " .. mainname)
				go(mainname)
			else
				-- 4. Si no es un include (o no tiene padre), ejecutamos el nombre del archivo actual
				if current_filename and current_filename ~= "" then
					go(current_filename)
				else
					-- 5. Fallback final: pedirlo a mano
					vim.ui.input({ prompt = "Programa a ejecutar: " }, function(v)
						if v then
							go(v)
						end
					end)
				end
			end
		end)
	end)
end
-- Muestra texto en un split de solo lectura (q/- cierra).
local function show(bufname, lines)
	local b = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.bo[b].modifiable = false
	vim.bo[b].buftype = "nofile"
	pcall(vim.api.nvim_buf_set_name, b, bufname)
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, b)
	pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
	vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- Ejecuta una CLASE (runClass / F9 de VSCode): corre if_oo_adt_classrun~main y muestra la
-- salida (out->write). `sapcli class execute NAME`. Usa la clase del buffer o pregunta.
function M.run_class(name)
	local meta = vim.b.sap_obj
	name = name or (meta and meta.group == "class" and meta.name) or nil
	local function go(c)
		c = (c or ""):upper()
		if c == "" then
			return
		end
		notify("Ejecutando clase " .. c .. " (if_oo_adt_classrun~main)...")
		local out = {}
		vim.fn.jobstart({ "sapcli", "class", "execute", c }, {
			on_stdout = function(_, d)
				for _, l in ipairs(d) do
					out[#out + 1] = l
				end
			end,
			on_stderr = function(_, d)
				for _, l in ipairs(d) do
					if vim.trim(l) ~= "" then
						out[#out + 1] = l
					end
				end
			end,
			on_exit = function(_, code)
				vim.schedule(function()
					if code ~= 0 and #out == 0 then
						notify("No se pudo ejecutar " .. c, vim.log.levels.ERROR)
						return
					end
					show("sap-runclass://" .. c, out)
				end)
			end,
		})
	end
	if name then
		go(name)
	else
		vim.ui.input({ prompt = "Clase a ejecutar: " }, function(v)
			if v then
				go(v)
			end
		end)
	end
end

function M.setup()
	vim.api.nvim_create_user_command("SapRunTransaction", function(a)
		if a.args ~= "" then
			M.run_transaction(a.args)
		else
			vim.ui.input({ prompt = "Transaccion: " }, function(v)
				if v and v ~= "" then
					M.run_transaction(v)
				end
			end)
		end
	end, { desc = "sap-nvim: Ejecutar transaccion (WebGUI)", nargs = "?" })

	vim.api.nvim_create_user_command("SapRun", function(a)
		M.run_program(a.args ~= "" and a.args or nil)
	end, { desc = "sap-nvim: Ejecutar el programa/report (WebGUI SE38)", nargs = "?" })

	vim.api.nvim_create_user_command("SapWebGui", function()
		M.web_gui()
	end, { desc = "sap-nvim: Abrir WebGUI" })

	vim.api.nvim_create_user_command("SapRunClass", function(a)
		M.run_class(a.args ~= "" and a.args or nil)
	end, { desc = "sap-nvim: Ejecutar clase (if_oo_adt_classrun~main)", nargs = "?" })

	-- Atajos: <leader>ax ejecutar transacción, <leader>aR ejecutar el programa del buffer.
	vim.keymap.set("n", "<leader>ax", function()
		local w = vim.fn.expand("<cword>")
		-- Solo auto-ejecutar la palabra bajo el cursor como transacción si estamos en un
		-- buffer ABAP y parece un código de transacción. Fuera de un programa (dashboard,
		-- otro filetype, palabra rara) SIEMPRE mostramos el cuadro para elegir/escribir.
		if vim.bo.filetype == "abap" and w and w:match("^[%w_/]+$") and #w >= 3 and #w <= 20 then
			M.run_transaction(w)
		else
			vim.ui.input({ prompt = "Transacción: " }, function(v)
				if v and v ~= "" then
					M.run_transaction(v)
				end
			end)
		end
	end, { desc = "ABAP: Ejecutar transacción (WebGUI)" })
	vim.keymap.set("n", "<leader>aR", function()
		M.run_program()
	end, { desc = "ABAP: Ejecutar el programa/report (WebGUI)" })
	vim.keymap.set("n", "<leader>aE", function()
		M.run_class()
	end, { desc = "ABAP: Ejecutar clase (classrun)" })
end

return M
