-- sap-nvim.core.connection
-- Login interactivo: elige la máquina SAP (por descripción) y mete la contraseña, que se
-- guarda en memoria + keyring del kernel (recordar estilo VSCode) — nunca en texto plano en
-- disco. La contraseña se VALIDA con una sola petición ANTES de habilitar nada: así una
-- contraseña errónea cuesta UN intento, no la ráfaga (completado por tecla + sapcli) que
-- bloquea el usuario en SAP. Una vez validada, core.sapcli inyecta credenciales solo en los
-- procesos hijo que las necesitan.

local M = {}
local adt = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
	end)
end

-- Valida las credenciales del contexto activo con UNA petición y, según el resultado, habilita
-- la conexión (mark_validated + persiste la contraseña) o activa el freno anti-bloqueo. cb(ok).
local function validate_and_finish(conn, password, cb)
	adt.validate(function(ok, code)
		if ok then
			if password and password ~= "" then
				adt.persist_password(conn.context, password)
			end
			adt.mark_validated()
			notify("Conectado a " .. conn.description .. " como " .. conn.user .. ".")
			if cb then cb(true) end
		else
			-- SAP rechazó la auth: NO guardamos la contraseña y pausamos (freno) para no
			-- seguir intentando y bloquear el usuario.
			adt.on_auth_failure()
			local why = (code == 401 or code == 403) and "contraseña incorrecta o usuario bloqueado"
				or ("sin respuesta válida de SAP (HTTP " .. tostring(code) .. ")")
			notify("Login rechazado: " .. why .. ". NO se guarda la contraseña. Reintenta con :SapLogin.", vim.log.levels.ERROR)
			if cb then cb(false) end
		end
	end)
end

-- Pide la contraseña (oculta) para `conn`, la fija en memoria, la VALIDA y termina. cb(ok).
function M.ask_password(conn, cb)
	vim.schedule(function()
		local pw = vim.fn.inputsecret("Contraseña " .. conn.user .. "@" .. conn.description .. ": ")
		if pw == nil or pw == "" then
			-- Sin contraseña tecleada: si hay una recordada (keyring) o en config.yml, validamos esa.
			adt.use_connection(conn.context, nil, { persist = false })
			if adt.creds() then
				validate_and_finish(conn, nil, cb)
			else
				notify("Login cancelado (sin contraseña).", vim.log.levels.WARN)
				if cb then cb(false) end
			end
			return
		end
		-- Contraseña tecleada: la ponemos SOLO en memoria (persist=false) hasta validar; si SAP
		-- la acepta, validate_and_finish la persiste en el keyring.
		adt.use_connection(conn.context, pw, { persist = false })
		validate_and_finish(conn, pw, cb)
	end)
end

-- Selector de conexión + contraseña. cb(ok). Si solo hay una, salta el selector.
function M.choose(cb)
	local conns = adt.list_connections()
	if #conns == 0 then
		notify("No hay conexiones en ~/.sapcli/config.yml. Usa :SapSetup.", vim.log.levels.WARN)
		if cb then cb(false) end
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
			if cb then cb(false) end
			return
		end
		M.ask_password(choice, cb)
	end)
end

-- Login solo si hace falta (no hay conexión validada). cb(ok). Para usar bajo demanda.
function M.ensure(cb)
	if adt.ready() then
		if cb then cb(true) end
		return
	end
	M.choose(cb)
end

-- Arranque del plugin: si ya hay una contraseña recordada (keyring/config), la VALIDA en
-- segundo plano con UNA petición y, si SAP la acepta, habilita la conexión (y la propaga al
-- entorno para sapcli). Si la rechaza, activa el freno y avisa. Si no hay ninguna recordada,
-- no hace nada (se pedirá al abrir el primer objeto). NUNCA pregunta al arrancar.
function M.bootstrap()
	if not adt.creds() then
		adt.export_env() -- asegura que no queden SAP_USER/SAP_PASSWORD viejos en el entorno
		return
	end
	adt.validate(function(ok, code)
		if ok then
			adt.mark_validated()
		elseif code == 401 or code == 403 then
			-- 401/403: la contraseña recordada es INVÁLIDA → olvidarla y pedir re-login.
			adt.on_auth_failure()
		else
			adt.export_env()
			notify("No se pudo validar SAP al arrancar (HTTP " .. tostring(code) .. "). La conexión queda sin validar.", vim.log.levels.WARN)
		end
	end)
end

-- Arranque: SIEMPRE pregunta con qué MÁQUINA entrar (selector). Tras elegirla:
--  - si esa máquina ya tiene la contraseña recordada (keyring/DPAPI/config) → la valida en
--    SILENCIO y entra directo al dashboard (sin pedir nada);
--  - si no la tiene → pide la contraseña.
-- Un solo intento de login (validación o login tecleado) → sin riesgo de bloqueo por ráfaga.
function M.start_login(cb)
	cb = cb or function() end
	local conns = adt.list_connections()
	if #conns == 0 then
		notify("No hay conexiones en ~/.sapcli/config.yml. Usa :SapSetup.", vim.log.levels.WARN)
		return cb(false)
	end

	local function on_machine(conn)
		-- Fija el contexto elegido (sin contraseña aún) y mira si ya hay una recordada.
		adt.use_connection(conn.context, nil, { persist = false })
		if adt.creds() then
			-- Hay contraseña recordada → validar en silencio (1 intento) y entrar.
			adt.validate(function(ok, code)
				if ok then
					adt.mark_validated()
					notify("Conectado a " .. conn.description .. " como " .. conn.user .. ".")
					cb(true)
				elseif code == 401 or code == 403 then
					-- Recordada inválida (401/403): olvidarla y pedir contraseña nueva.
					adt.on_auth_failure()
					M.ask_password(conn, cb)
				else
					adt.export_env()
					notify("No se pudo validar SAP (HTTP " .. tostring(code) .. "). Reintenta :SapLogin cuando haya conexión.", vim.log.levels.WARN)
					cb(false)
				end
			end)
		else
			-- No hay contraseña guardada para esta máquina → pedirla.
			M.ask_password(conn, cb)
		end
	end

	if #conns == 1 then
		return on_machine(conns[1]) -- una sola máquina: sin selector
	end
	vim.ui.select(conns, {
		prompt = "¿Con qué máquina SAP quieres entrar?",
		format_item = function(c)
			return string.format("%s   ·   %s   ·   %s   ·   client %s", c.description, c.host, c.user, c.client)
		end,
	}, function(choice)
		if not choice then
			return cb(false)
		end
		on_machine(choice)
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("SapLogin", function()
		M.choose()
	end, { desc = "SAP: elegir conexión + contraseña (validada, en memoria + keyring)" })
	vim.api.nvim_create_user_command("SapRelogin", function()
		M.choose() -- vuelve a elegir conexión + contraseña (sobrescribe la recordada)
	end, { desc = "SAP: cambiar de conexión / re-login" })
	-- OJO: no validamos aquí en arranque; lo hace home.start() vía start_login (selector de
	-- máquina + login solo si falta), para no duplicar intentos de login.
end

return M
