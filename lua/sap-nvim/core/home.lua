-- sap-nvim.core.home
-- "Neovim SAP": dashboard separado, picker de buffers (␣␣), restauración de sesión
-- SOLO de objetos SAP y backstop de navegación (`-` → dashboard).
--
-- TODO está GATED tras vim.g.sap_mode / opts.sap_mode. En modo normal (alguien que solo
-- usa el plugin en su Neovim personal) este módulo NO toca keymaps globales ni autocomandos:
-- solo expone el comando :SapHome. Así el entorno SAP no interfiere con el del usuario.

local M = {}

local SESSION_FILE = vim.fn.stdpath("state") .. "/sap-nvim/last_session.txt"

-- ── Utilidades ──────────────────────────────────────────────────────────────

local function cache_dir()
	local ok, source = pcall(require, "sap-nvim.core.source")
	return ok and source.cache_dir() or nil
end

-- ¿El buffer es un objeto SAP? (tiene sap_obj o vive en la caché del plugin)
function M.is_sap_buf(b)
	if vim.b[b] and vim.b[b].sap_obj then
		return true
	end
	local name = vim.api.nvim_buf_get_name(b)
	if name == "" then
		return false
	end
	local dir = cache_dir()
	return dir ~= nil and name:sub(1, #dir) == dir
end

-- Etiqueta de la conexión SAP activa (para el pie del dashboard).
function M.conn_label()
	local ok, adt = pcall(require, "sap-nvim.core.adt_http")
	if ok and adt.creds then
		local c = adt.creds()
		if c then
			return (c.base or "?") .. "  ·  client " .. (c.client or "?") .. "  ·  " .. (c.user or "?")
		end
	end
	return "sin conexión — :SapSetup para configurar"
end

-- ── Paleta SAP (azul corporativo + ámbar para teclas) ───────────────────────
local function setup_highlights()
	local set = vim.api.nvim_set_hl
	set(0, "SapHomeLogo", { fg = "#1c9fd8", bold = true })
	set(0, "SapHomeTitle", { fg = "#7fd3f7", bold = true })
	set(0, "SapHomeKey", { fg = "#ffca28", bold = true })
	set(0, "SapHomeDesc", { fg = "#cfd8dc" })
	set(0, "SapHomeFoot", { fg = "#607d8b", italic = true })
end

-- ── Acciones del menú ───────────────────────────────────────────────────────

function M.search()
	-- Picker en vivo (Telescope) con filtro por tipo (<C-t>), como VSCode.
	require("sap-nvim.core.search").open_picker()
end

function M.transaction()
	vim.ui.input({ prompt = "Transacción: " }, function(t)
		if t and t ~= "" then
			require("sap-nvim.core.gui").run_transaction(t)
		end
	end)
end

local MENU = {
	{
		key = "n",
		desc = "Nuevo objeto en SAP (programa, clase, include…)",
		action = function()
			require("sap-nvim.core.new").new_object()
		end,
	},
	{
		key = "o",
		desc = "Abrir / buscar objeto",
		action = function()
			M.search()
		end,
	},
	{
		key = "C",
		desc = "Abrir vista CDS / objeto RAP (ddls, bdef…)",
		action = function()
			M.open_cds()
		end,
	},
	{
		key = "x",
		desc = "Ejecutar transacción (WebGUI)",
		action = function()
			M.transaction()
		end,
	},
	{
		key = "g",
		desc = "Abrir SAP GUI nativo (transacción o logon)",
		action = function()
			vim.ui.input({ prompt = "Transacción para SAP GUI (vacío = logon): " }, function(t)
				local gui = require("sap-nvim.core.sapgui")
				if t and vim.trim(t) ~= "" then
					gui.transaction(t)
				else
					gui.open(nil)
				end
			end)
		end,
	},
	{
		key = "R",
		desc = "Ejecutar programa (SE38)",
		action = function()
			require("sap-nvim.core.gui").run_program()
		end,
	},
	{
		key = "t",
		desc = "Órdenes de transporte (mías)",
		action = function()
			require("sap-nvim.core.cts").list_transports()
		end,
	},
	{
		key = "c",
		desc = "Crear orden de transporte",
		action = function()
			require("sap-nvim.core.cts").create_transport()
		end,
	},
	{
		key = "b",
		desc = "Buffers abiertos  (también ␣␣)",
		action = function()
			M.pick_buffers()
		end,
	},
	{
		key = "r",
		desc = "Objetos SAP recientes (sesión anterior)",
		action = function()
			M.pick_buffers()
		end,
	},
	{
		key = "S",
		desc = "Configurar conexión SAP (:SapSetup) — primera vez / nueva máquina",
		action = function()
			vim.cmd("SapSetup")
		end,
	},
	{
		key = "L",
		desc = "Conexión / login (cambiar de máquina)",
		action = function()
			require("sap-nvim.core.connection").choose()
		end,
	},
	{
		key = "q",
		desc = "Salir",
		action = function()
			vim.cmd("qa")
		end,
	},
}

-- Abre una vista CDS / objeto RAP pidiendo tipo (por defecto ddls) y nombre.
function M.open_cds()
	-- Picker en vivo filtrado a CDS/RAP (DDLS por defecto, <C-t> cambia el grupo).
	require("sap-nvim.core.search").open_cds_picker()
end

local LOGO = {
	"",
	" █████   █████   █████   ████    █████   █████ ",
	" █       █       █   █   █   █   █   █   █   █ ",
	" █████   █████     █     █   █   █   █   █████ ",
	"     █   █         █     █   █   █   █   █  █   ",
	" █████   █████   █████   ████    █████   █   █ ",
	"",
	"           N E O V I M  ·  S E I D O R",
	"",
}

-- ── Dashboard ───────────────────────────────────────────────────────────────
function M.open_dashboard()
	setup_highlights()
	local lines, line_item = {}, {}
	for _, l in ipairs(LOGO) do
		lines[#lines + 1] = l
	end
	local menu_start = #lines
	for _, item in ipairs(MENU) do
		line_item[#lines] = item -- índice 0-based de esta línea
		lines[#lines + 1] = string.format("       [ %s ]   %s", item.key, item.desc)
	end
	lines[#lines + 1] = ""
	lines[#lines + 1] = "       " .. M.conn_label()
	lines[#lines + 1] = ""
	lines[#lines + 1] = "       ↵ activa la línea · ␣␣ salta entre buffers · - vuelve aquí"

	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].buftype = "nofile"
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].swapfile = false
	vim.bo[buf].modifiable = false
	vim.bo[buf].filetype = "sapdashboard"
	pcall(vim.api.nvim_buf_set_name, buf, "SAP Home")
	vim.api.nvim_win_set_buf(0, buf)
	vim.wo.number = false
	vim.wo.relativenumber = false
	vim.wo.cursorline = true
	vim.wo.signcolumn = "no"
	vim.wo.list = false

	-- Las opciones de arriba son de VENTANA: si abres un objeto SAP en esta misma
	-- ventana, se quedarían pegadas (sin números ni signcolumn → no verías el
	-- breakpoint). Al salir del dashboard las restauramos a valores normales.
	vim.api.nvim_create_autocmd({ "BufLeave", "BufWinLeave" }, {
		buffer = buf,
		once = true,
		callback = function()
			pcall(function()
				vim.wo.number = true
				vim.wo.relativenumber = true
				vim.wo.signcolumn = "yes"
				vim.wo.cursorline = true
				vim.wo.list = false
			end)
		end,
	})

	-- Resaltado
	local ns = vim.api.nvim_create_namespace("sap_home")
	for i = 0, menu_start - 1 do
		pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapHomeLogo", i, 0, -1)
	end
	for i = menu_start, #lines - 1 do
		local l = lines[i + 1] or ""
		local a, b = l:find("%[.-%]")
		if a then
			pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapHomeKey", i, a - 1, b)
			pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapHomeDesc", i, b, -1)
		else
			pcall(vim.api.nvim_buf_add_highlight, buf, ns, "SapHomeFoot", i, 0, -1)
		end
	end

	-- Keymaps buffer-local: cada tecla ejecuta su acción
	local opt = { buffer = buf, nowait = true, silent = true }
	for _, item in ipairs(MENU) do
		vim.keymap.set("n", item.key, item.action, opt)
	end
	vim.keymap.set("n", "<CR>", function()
		local row = vim.api.nvim_win_get_cursor(0)[1] - 1
		local item = line_item[row]
		if item then
			item.action()
		end
	end, opt)
	vim.keymap.set("n", "<leader><leader>", function()
		M.pick_buffers()
	end, opt)

	pcall(vim.api.nvim_win_set_cursor, 0, { menu_start + 1, 7 })
	return buf
end

-- ── Picker de buffers (␣␣) — prioriza objetos SAP ───────────────────────────
function M.pick_buffers()
	-- Si hay snacks, usamos su picker nativo (mejor UX, preview, fuzzy).
	local ok_snacks, Snacks = pcall(require, "snacks")
	if ok_snacks and Snacks.picker and Snacks.picker.buffers then
		pcall(Snacks.picker.buffers)
		return
	end

	local items = {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and vim.bo[b].buflisted then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" then
				local meta = vim.b[b].sap_obj
				local sap = M.is_sap_buf(b)
				local label = meta and (meta.name .. "  (" .. (meta.group or "?") .. ")")
					or vim.fn.fnamemodify(name, ":t")
				items[#items + 1] = { buf = b, label = (sap and "● " or "  ") .. label, sap = sap }
			end
		end
	end
	if #items == 0 then
		vim.notify("[SAP] No hay buffers abiertos todavía.", vim.log.levels.INFO)
		return
	end
	table.sort(items, function(a, b)
		if a.sap ~= b.sap then
			return a.sap
		end
		return a.label < b.label
	end)
	vim.ui.select(items, {
		prompt = "Buffers abiertos:",
		format_item = function(i)
			return i.label
		end,
	}, function(c)
		if c then
			vim.api.nvim_set_current_buf(c.buf)
		end
	end)
end

-- ── Sesión: guardar/restaurar SOLO objetos SAP ──────────────────────────────
function M.save_session()
	local paths, seen = {}, {}
	for _, b in ipairs(vim.api.nvim_list_bufs()) do
		if vim.api.nvim_buf_is_loaded(b) and M.is_sap_buf(b) then
			local name = vim.api.nvim_buf_get_name(b)
			if name ~= "" and not seen[name] and vim.fn.filereadable(name) == 1 then
				seen[name] = true
				paths[#paths + 1] = name
			end
		end
	end
	pcall(vim.fn.mkdir, vim.fn.fnamemodify(SESSION_FILE, ":h"), "p")
	pcall(vim.fn.writefile, paths, SESSION_FILE)
end

-- Reabre (en la buffer-list, sin robar el foco al dashboard) los objetos SAP guardados.
function M.restore_session()
	if vim.fn.filereadable(SESSION_FILE) == 0 then
		return 0
	end
	local ok, paths = pcall(vim.fn.readfile, SESSION_FILE)
	if not ok then
		return 0
	end
	local n = 0
	for _, p in ipairs(paths) do
		if vim.fn.filereadable(p) == 1 then
			pcall(vim.cmd, "badd " .. vim.fn.fnameescape(p))
			n = n + 1
		end
	end
	return n
end

-- Arranque del modo SAP: restaura objetos SAP, abre el dashboard y pregunta con qué MÁQUINA
-- entrar (selector). Si esa máquina ya tiene la contraseña recordada (keyring/DPAPI), valida
-- en silencio y te deja en el dashboard; si no, te pide la contraseña. Se puede desactivar el
-- selector de arranque con vim.g.sap_login_on_start = false.
function M.start()
	-- Guard: VimEnter y el guard de carga-tardía pueden invocar start() ambos; solo una vez.
	if M._started then
		return
	end
	M._started = true
	M.restore_session()
	M.open_dashboard()
	if vim.g.sap_login_on_start == false then
		return
	end
	-- Selector de máquina sobre el dashboard; login solo si falta la contraseña.
	local ok, conn = pcall(require, "sap-nvim.core.connection")
	if ok then
		pcall(conn.start_login)
	end
end

-- ── Setup (GATED) ───────────────────────────────────────────────────────────
function M.setup(opts)
	opts = opts or {}

	-- Comando siempre disponible y NO intrusivo (modo normal incluido).
	vim.api.nvim_create_user_command("SapHome", function()
		M.open_dashboard()
	end, { desc = "SAP: abrir el dashboard de Neovim SAP" })

	local sap_mode = opts.sap_mode or vim.g.sap_mode
	if not sap_mode then
		return -- Modo normal: no tocamos nada más. Cero interferencia.
	end

	setup_highlights()

	-- ␣␣ global → picker de buffers (saltar entre programas abiertos, estilo VSCode).
	vim.keymap.set("n", "<leader><leader>", function()
		M.pick_buffers()
	end, { desc = "SAP: buffers abiertos (␣␣)" })

	-- `-` → dashboard (home / backstop): en modo SAP no abrimos el explorador de ficheros
	-- del PC; el dashboard es la pantalla "más atrás".
	vim.keymap.set("n", "-", function()
		M.open_dashboard()
	end, { desc = "SAP: volver al dashboard" })

	local g = vim.api.nvim_create_augroup("sap_home", { clear = true })

	-- Arranque sin argumentos: restaurar objetos SAP de la sesión anterior + dashboard.
	vim.api.nvim_create_autocmd("VimEnter", {
		group = g,
		nested = true,
		callback = function()
			if vim.fn.argc() ~= 0 then
				return -- abriste con un fichero/dir: respétalo
			end
			vim.schedule(function()
				M.start()
			end)
		end,
	})

	-- Guardar la sesión SAP al salir.
	vim.api.nvim_create_autocmd("VimLeavePre", {
		group = g,
		callback = function()
			pcall(M.save_session)
		end,
	})

	-- Si el plugin se carga DESPUÉS de VimEnter (lazy.nvim a veces lo hace), el autocmd
	-- de arriba ya no dispara en este arranque: lo lanzamos a mano si procede.
	if vim.v.vim_did_enter == 1 and vim.fn.argc() == 0 then
		vim.schedule(function()
			M.start()
		end)
	end
end

return M
