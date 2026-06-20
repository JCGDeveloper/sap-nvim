-- sap-nvim.core.connection
-- Login interactivo: elige la máquina SAP (por descripción) y mete la contraseña, que
-- se guarda SOLO en memoria (vía adt_http.use_connection) — nunca en disco. Así puedes
-- quitar `password:` de ~/.sapcli/config.yml y que te la pida al arrancar (más seguro).
--
-- Para la descripción de la máquina, añade un campo `description:` en su bloque de
-- `connections:` en config.yml; si no, se usa el nombre del contexto.

local M = {}
local adt = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
	end)
end

-- Pide la contraseña (oculta) para `conn` y la fija en memoria. cb(ok).
function M.ask_password(conn, cb)
	vim.schedule(function()
		local pw = vim.fn.inputsecret("Contraseña " .. conn.user .. "@" .. conn.description .. ": ")
		if pw == nil or pw == "" then
			-- Sin password tecleada: si config.yml ya trae una, usamos esa; si no, abortamos.
			if conn.pass and conn.pass ~= "" then
				adt.use_connection(conn.context, nil)
				notify("Conectado a " .. conn.description .. " (contraseña de config.yml).")
				if cb then
					cb(true)
				end
			else
				notify("Login cancelado (sin contraseña).", vim.log.levels.WARN)
				if cb then
					cb(false)
				end
			end
			return
		end
		adt.use_connection(conn.context, pw)
		notify("Conectado a " .. conn.description .. " como " .. conn.user .. ".")
		if cb then
			cb(true)
		end
	end)
end

-- Selector de conexión + contraseña. cb(ok). Si solo hay una, salta el selector.
function M.choose(cb)
	local conns = adt.list_connections()
	if #conns == 0 then
		notify("No hay conexiones en ~/.sapcli/config.yml. Usa :SapSetup.", vim.log.levels.WARN)
		if cb then
			cb(false)
		end
		return
	end
	if #conns == 1 then
		M.ask_password(conns[1], cb)
		return
	end
	vim.ui.select(conns, {
		prompt = "Conexión SAP:",
		format_item = function(c)
			return string.format("%s   ·   %s   ·   %s   ·   client %s", c.description, c.host, c.user, c.client)
		end,
	}, function(choice)
		if not choice then
			if cb then
				cb(false)
			end
			return
		end
		M.ask_password(choice, cb)
	end)
end

-- Login solo si hace falta (no hay contraseña disponible). cb(ok). Para el arranque.
function M.ensure(cb)
	if not adt.needs_login() then
		if cb then
			cb(true)
		end
		return
	end
	M.choose(cb)
end

function M.setup()
	vim.api.nvim_create_user_command("SapLogin", function()
		M.choose()
	end, { desc = "SAP: elegir conexión + contraseña (en memoria)" })
	vim.api.nvim_create_user_command("SapRelogin", function()
		M.choose() -- vuelve a elegir conexión + contraseña (sobrescribe la de memoria)
	end, { desc = "SAP: cambiar de conexión / re-login" })
end

return M
