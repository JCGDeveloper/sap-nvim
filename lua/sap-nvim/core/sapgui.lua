local M = {}
local adt = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ============================================================================
-- 1. RESOLUCIÓN DE CONEXIÓN Y SAP LOGON (SAPUILandscape.xml)
-- ============================================================================
local function landscape_conn(host)
	if vim.fn.has("wsl") ~= 1 then
		return nil
	end
	local files = {}
	vim.list_extend(files, vim.fn.glob("/mnt/c/Users/*/AppData/Roaming/SAP/Common/SAPUILandscape.xml", true, true))
	vim.list_extend(files, vim.fn.glob("/mnt/c/Users/*/AppData/Local/SAP/Common/SAPUILandscapeGlobal.xml", true, true))

	for _, file in ipairs(files) do
		local ok, lines = pcall(vim.fn.readfile, file)
		if ok then
			local xml = table.concat(lines, "\n")
			local routers = {}
			for attrs in xml:gmatch("<Router%s+(.-)/?>") do
				local uuid, rstr = attrs:match('uuid="([^"]*)"'), attrs:match('router="([^"]*)"')
				if uuid and rstr then
					routers[uuid] = rstr
				end
			end

			local cands = {}
			for attrs in xml:gmatch("<Service%s+(.-)/?>") do
				if attrs:match('type="SAPGUI"') then
					local server = attrs:match('server="([^"]*)"')
					if server and server ~= "" then
						cands[#cands + 1] = {
							sysid = attrs:match('systemid="([^"]*)"') or "",
							server = server,
							router = routers[attrs:match('routerid="([^"]*)"') or ""],
						}
					end
				end
			end

			local pick, hl = nil, (host or ""):lower()
			for _, c in ipairs(cands) do
				if c.sysid ~= "" and hl:find(c.sysid:lower(), 1, true) then
					pick = c
					break
				end
			end

			pick = pick or cands[1]
			if pick then
				local sh, sp = pick.server:match("^(.-):(%d+)$")
				sh, sp = sh or pick.server, sp or "3200"
				local route = pick.router or ""
				if route ~= "" and not route:find("/S/") then
					route = route .. "/S/3299"
				end
				return { connstring = route .. "/H/" .. sh .. "/S/" .. sp, sysid = pick.sysid }
			end
		end
	end
	return nil
end

local function gui_conn()
	local c = adt.creds()
	if not c then
		notify("Sin conexión SAP (config.yml).", vim.log.levels.WARN)
		return nil
	end
	local host = (c.host or ""):gsub("^https?://", ""):gsub(":%d+$", "")
	local connstring, sysid = vim.g.sap_gui_connstring, nil

	if not connstring then
		local ls = landscape_conn(host)
		if ls then
			connstring, sysid = ls.connstring, ls.sysid
		end
	end

	if not connstring then
		local sysnr = vim.g.sap_gui_sysnr
		if not sysnr then
			local port = (c.base or ""):match(":(%d+)")
			sysnr = (port and port:match("^443(%d%d)$")) or "00"
		end
		connstring = "/H/" .. host .. "/S/32" .. tostring(sysnr)
	end

	return {
		server = host,
		sysnr = connstring:match("/S/32(%d%d)$") or "00",
		connstring = connstring,
		client = c.client or "",
		user = c.user or "",
		sysname = vim.g.sap_gui_sysname or sysid or (host:match("^([^.]+)") or host or "SAP"):upper(),
		lang = vim.g.sap_gui_lang or "EN",
	}
end

-- ============================================================================
-- 2. LANZADORES: NATIVO (.sap) vs WEB (Navegador)
-- ============================================================================
local function build_shortcut(conn, fn, ticket)
	local lines = {
		"[System]",
		'guiparm="' .. conn.connstring .. '"',
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

local function launch_desktop(lines)
	local content = table.concat(lines, "\r\n") .. "\r\n"
	if vim.fn.has("wsl") == 1 then
		local dir_wsl, dir_win = "/mnt/c/Users/Public/sap-nvim", "C:\\Users\\Public\\sap-nvim"
		pcall(vim.fn.mkdir, dir_wsl, "p")
		local fname = "shortcut_" .. os.time() .. ".sap"
		local f = io.open(dir_wsl .. "/" .. fname, "wb")
		if not f then
			return
		end
		f:write(content)
		f:close()
		local win_path = dir_win .. "\\" .. fname
		local ps = "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe"
		vim.fn.system({ ps, "-NoProfile", "-Command", "Start-Process '" .. win_path:gsub("'", "''") .. "'" })
		vim.defer_fn(function()
			pcall(os.remove, dir_wsl .. "/" .. fname)
		end, 60000)
		return
	end
	-- Linux nativo / Mac
	local tmp = vim.fn.tempname() .. ".sap"
	local f = io.open(tmp, "wb")
	if f then
		f:write(content)
		f:close()
	end
	if vim.ui and vim.ui.open then
		pcall(vim.ui.open, tmp)
	end
	vim.defer_fn(function()
		pcall(os.remove, tmp)
	end, 60000)
end

local function launch_web(conn, fn)
	local c = adt.creds()
	local url = c.base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. conn.client .. "&sap-language=" .. conn.lang
	if fn and fn.command then
		local cmd = fn.command:gsub("^%*", "")
		if fn.type == "Transaction" and cmd ~= "SADT_START_WB_URI" then
			url = url .. "&~transaction=" .. cmd
		end
	end
	notify("Abriendo WebGUI...")
	local sys_cmd
	if vim.fn.has("wsl") == 1 then
		sys_cmd = { "/mnt/c/Windows/System32/cmd.exe", "/c", "start", url }
	elseif vim.fn.has("mac") == 1 then
		sys_cmd = { "open", url }
	else
		sys_cmd = { "xdg-open", url }
	end
	vim.fn.jobstart(sys_cmd)
end

-- ============================================================================
-- 3. INTERFAZ PRINCIPAL
-- ============================================================================
function M.open(fn, opts)
	opts = opts or { desktop = true }
	local conn = gui_conn()
	if not conn then
		return
	end

	if opts.desktop then
		if conn.server == "" then
			notify("No hay host de SAP GUI en la conexión.", vim.log.levels.WARN)
			return
		end
		notify("Abriendo SAP GUI nativo (" .. conn.server .. " /32" .. conn.sysnr .. ")...")
		adt.request_async({ method = "GET", path = "/sap/bc/adt/security/reentranceticket" }, function(body)
			vim.schedule(function()
				local ticket = body and vim.trim(body) or ""
				if ticket == "" or ticket:find("<", 1, true) then
					ticket = nil
				end
				launch_desktop(build_shortcut(conn, fn, ticket))
			end)
		end)
	else
		launch_web(conn, fn)
	end
end

function M.transaction(tcode, opts)
	tcode = (tcode or ""):upper()
	if tcode == "" then
		return
	end
	M.open({ type = "Transaction", command = tcode }, opts)
end

function M.object(bufnr, opts)
	bufnr = bufnr or vim.api.nvim_get_current_buf()
	local ok, intel = pcall(require, "sap-nvim.core.intel")
	local uri = ok and intel.object_uri and intel.object_uri(bufnr) or nil
	if not uri then
		notify("No identifico el objeto del buffer (ábrelo desde SAP).", vim.log.levels.WARN)
		return
	end
	uri = uri:gsub("/source/main$", "")

	opts = opts or { desktop = true }
	if not opts.desktop then
		notify(
			"Abriendo SE80 en WebGUI. Busca manualmente tu objeto: "
				.. (vim.b[bufnr].sap_obj and vim.b[bufnr].sap_obj.name or "")
		)
		M.transaction("SE80", opts)
	else
		M.open({
			type = "Transaction",
			command = "*SADT_START_WB_URI",
			params = { { "D_OBJECT_URI", uri } },
			okcode = "OKAY",
		}, { desktop = true })
	end
end

function M.setup()
	-- Comandos
	vim.api.nvim_create_user_command("SapGuiLogon", function()
		M.open(nil, { desktop = true })
	end, { desc = "SAP GUI nativo: logon" })
	vim.api.nvim_create_user_command("SapGuiTransaction", function(a)
		if a.args ~= "" then
			M.transaction(a.args, { desktop = true })
		else
			vim.ui.input({ prompt = "Transacción: " }, function(t)
				if t and t ~= "" then
					M.transaction(t, { desktop = true })
				end
			end)
		end
	end, { nargs = "?", desc = "SAP GUI nativo: ejecutar transacción" })

	vim.api.nvim_create_user_command("SapGuiObject", function()
		M.object(nil, { desktop = true })
	end, { desc = "SAP GUI nativo: abrir el objeto actual" })

	-- WebGUI options
	vim.api.nvim_create_user_command("SapWebGui", function()
		M.open(nil, { desktop = false })
	end, { desc = "Abrir SAP en WebGUI (Navegador)" })
	vim.api.nvim_create_user_command("SapWebGuiObject", function()
		M.object(nil, { desktop = false })
	end, { desc = "Abrir Objeto en WebGUI (SE80)" })

	-- Keymaps
	vim.keymap.set("n", "<leader>asw", function()
		M.object(nil, { desktop = false })
	end, { desc = "ABAP: Abrir Objeto en WebGUI (Navegador)" })
	vim.keymap.set("n", "<leader>asG", function()
		M.object(nil, { desktop = true })
	end, { desc = "ABAP: Abrir Objeto en SAP GUI (Nativo)" })
end

return M
