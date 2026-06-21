-- sap-nvim.core.sapgui
-- Abrir el SAP GUI NATIVO (escritorio) generando un shortcut `.sap` y lanzándolo con el SO.
-- En WSL el `.sap` se abre con Windows (donde está instalado el SAP GUI). Login sin contraseña
-- vía reentrance ticket (SSO) si el sistema lo permite; si no, el SAP GUI pedirá credenciales.
--
-- Mecanismo tomado de vscode_abap_remote_fs (client/src/adt/sapgui/sapgui.ts):
--   • shortcut .sap con [System]/[User]/[Function] y guiparm "/H/<server>/S/32<sysnr>"
--   • GET /sap/bc/adt/security/reentranceticket → MYSAPSSO2 para entrar sin contraseña
--   • abrir un objeto = transacción *SADT_START_WB_URI con D_OBJECT_URI=<uri ADT>

local M = {}
local adt = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Datos del GUI: server + número de sistema (sysnr) + client + user. El sysnr NO está en
-- config.yml: lo derivamos del puerto HTTPS del ICM (443NN → NN), o de vim.g.sap_gui_sysnr.
local function gui_conn()
	local c = adt.creds()
	if not c then
		notify("Sin conexión SAP (config.yml).", vim.log.levels.WARN)
		return nil
	end
	local server = (c.host or ""):gsub("^https?://", ""):gsub(":%d+$", "")
	local sysnr = vim.g.sap_gui_sysnr
	if not sysnr then
		local port = (c.base or ""):match(":(%d+)")
		sysnr = (port and port:match("^443(%d%d)$")) or "00"
	end
	return {
		server = server,
		sysnr = tostring(sysnr),
		client = c.client or "",
		user = c.user or "",
		sysname = vim.g.sap_gui_sysname or (server:match("^([^.]+)") or server or "SAP"):upper(),
		lang = vim.g.sap_gui_lang or "EN",
	}
end

-- Cadena de conexión directa: /H/<server>/S/32<sysnr> (dispatcher = 3200 + instancia).
local function conn_string(conn)
	return "/H/" .. conn.server .. "/S/32" .. conn.sysnr
end

-- Contenido del shortcut .sap. fn = nil (solo logon) | { type, command, params={{n,v}}, okcode }
local function build_shortcut(conn, fn, ticket)
	local lines = {
		"[System]",
		'guiparm="' .. conn_string(conn) .. '"',
		"Name=" .. conn.sysname,
		"Client=" .. conn.client,
		"[User]",
		"Name=" .. conn.user,
	}
	if ticket and ticket ~= "" then
		lines[#lines + 1] = 'at="MYSAPSSO2=' .. ticket .. '"'
	end
	lines[#lines + 1] = "Language=" .. conn.lang
	if fn then
		local params = ""
		for _, p in ipairs(fn.params or {}) do
			params = params .. p[1] .. " = " .. p[2] .. "; "
		end
		if fn.okcode then
			params = params .. "DYNP_OKCODE = " .. fn.okcode .. "; "
		end
		lines[#lines + 1] = "[Function]"
		lines[#lines + 1] = "Type=" .. (fn.type or "Transaction")
		lines[#lines + 1] = "Command=" .. fn.command .. " " .. params
	end
	vim.list_extend(lines, { "[Configuration]", "GuiSize=Maximized", "[Options]", "Reuse=1" })
	return lines
end

-- Escribe el .sap y lo lanza con el SO. En WSL: ruta Windows (wslpath) + Start-Process, así lo
-- abre el SAP GUI de Windows asociado a `.sap`.
local function launch(lines)
	local tmp = vim.fn.tempname() .. ".sap"
	vim.fn.writefile(lines, tmp)
	if vim.fn.has("wsl") == 1 then
		local win = vim.trim(vim.fn.system({ "wslpath", "-w", tmp }))
		local ps = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
		vim.fn.system({ ps, "-NoProfile", "-Command", "Start-Process '" .. win:gsub("'", "''") .. "'" })
		if vim.v.shell_error ~= 0 then
			notify("No se pudo lanzar el SAP GUI en Windows (¿instalado y .sap asociado?).", vim.log.levels.ERROR)
		end
	elseif vim.ui and vim.ui.open then
		pcall(vim.ui.open, tmp)
	else
		notify("No sé abrir .sap en esta plataforma.", vim.log.levels.WARN)
	end
	vim.defer_fn(function()
		pcall(os.remove, tmp)
	end, 60000)
end

-- Lanza el SAP GUI con la función dada (o solo logon). El reentrance ticket es best-effort.
function M.open(fn)
	local conn = gui_conn()
	if not conn then
		return
	end
	if conn.server == "" then
		notify("No hay host de SAP GUI en la conexión.", vim.log.levels.WARN)
		return
	end
	notify("Abriendo SAP GUI nativo (" .. conn.server .. " /32" .. conn.sysnr .. ")...")
	adt.request_async({ method = "GET", path = "/sap/bc/adt/security/reentranceticket" }, function(body)
		vim.schedule(function()
			local ticket = body and vim.trim(body) or ""
			if ticket == "" or ticket:find("<", 1, true) then
				ticket = nil -- respuesta vacía o XML de error: sin SSO, el GUI pedirá contraseña
			end
			launch(build_shortcut(conn, fn, ticket))
		end)
	end)
end

-- Ejecuta una transacción suelta en el SAP GUI.
function M.transaction(tcode)
	tcode = (tcode or ""):upper()
	if tcode == "" then
		return
	end
	M.open({ type = "Transaction", command = tcode })
end

-- Abre el objeto del buffer en el Workbench del SAP GUI (como doble clic).
function M.object(bufnr)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, intel = pcall(require, "sap-nvim.core.intel")
	local uri = ok and intel.object_uri and intel.object_uri(bufnr) or nil
	if not uri then
		notify("No identifico el objeto del buffer (ábrelo desde SAP).", vim.log.levels.WARN)
		return
	end
	uri = uri:gsub("/source/main$", "") -- SADT_START_WB_URI quiere la URI del objeto
	M.open({
		type = "Transaction",
		command = "*SADT_START_WB_URI",
		params = { { "D_OBJECT_URI", uri } },
		okcode = "OKAY",
	})
end

function M.setup()
	vim.api.nvim_create_user_command("SapGuiLogon", function()
		M.open(nil)
	end, { desc = "SAP GUI nativo: logon" })
	vim.api.nvim_create_user_command("SapGuiTransaction", function(a)
		if a.args ~= "" then
			M.transaction(a.args)
		else
			vim.ui.input({ prompt = "Transacción (SAP GUI): " }, function(t)
				if t and t ~= "" then
					M.transaction(t)
				end
			end)
		end
	end, { nargs = "?", desc = "SAP GUI nativo: ejecutar transacción" })
	vim.api.nvim_create_user_command("SapGuiObject", function()
		M.object()
	end, { desc = "SAP GUI nativo: abrir el objeto actual" })
	vim.keymap.set("n", "<leader>asG", function()
		M.object()
	end, { desc = "ABAP: abrir el objeto en SAP GUI nativo" })
end

return M
