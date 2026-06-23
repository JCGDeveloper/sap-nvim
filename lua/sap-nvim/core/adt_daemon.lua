-- sap-nvim.core.adt_daemon
-- Cliente Lua del daemon Python `python/adt_daemon.py`. El daemon mantiene UNA
-- conexion HTTPS keep-alive contra ADT y la reutiliza, de modo que las llamadas
-- ADT no pagan el handshake TLS por llamada (replica `abap-adt-api` de VSCode).
--
-- Este modulo NO se integra todavia en adt_http (eso lo hara el orquestador).
-- Aqui solo arrancamos el daemon, le hablamos por stdin (una linea JSON por
-- peticion) y resolvemos los callbacks cuando llega la linea de respuesta.

local M = {}

-- Estado del modulo (singleton del proceso nvim).
local state = {
	job = nil, -- id del job (jobstart) o nil si muerto
	next_id = 0, -- contador incremental de ids de peticion
	pending = {}, -- id -> cb (callbacks a la espera de respuesta)
	buf = "", -- buffer de stdout parcial (lineas incompletas)
}

-- ── Localizar el script python/adt_daemon.py ─────────────────────────────────
local function script_path()
	-- 1) buscar en el runtimepath (forma robusta cuando el plugin esta cargado).
	local rt = vim.api.nvim_get_runtime_file("python/adt_daemon.py", false)
	if rt and rt[1] then
		return rt[1]
	end

	-- 2) derivar de la ruta de ESTE modulo:
	--    .../lua/sap-nvim/core/adt_daemon.lua -> .../python/adt_daemon.py
	local src = debug.getinfo(1, "S").source
	src = src:gsub("^@", "")
	-- subir desde core/ -> sap-nvim/ -> lua/ -> raiz del plugin
	local root = src:gsub("[/\\]lua[/\\]sap%-nvim[/\\]core[/\\]adt_daemon%.lua$", "")
	return root .. "/python/adt_daemon.py"
end

-- ── Disponibilidad ───────────────────────────────────────────────────────────
function M.available()
	if vim.fn.executable("python3") ~= 1 then
		return false
	end
	return require("sap-nvim.core.adt_http").creds() ~= nil
end

-- ── Procesado del stdout del daemon (lineas JSON) ────────────────────────────
local function on_stdout(_, data)
	if not data then
		return
	end

	-- Reconstruir el buffer añadiendo los \n que Neovim quitó
	for i, chunk in ipairs(data) do
		state.buf = state.buf .. chunk
		if i < #data then
			state.buf = state.buf .. "\n"
		end
	end

	-- Extraer líneas completas
	while true do
		local nl = state.buf:find("\n", 1, true)
		if not nl then
			break
		end

		local line = state.buf:sub(1, nl - 1)
		state.buf = state.buf:sub(nl + 1)

		if line ~= "" then
			local ok, resp = pcall(vim.json.decode, line)
			if ok and type(resp) == "table" and resp.id ~= nil then
				local cb = state.pending[resp.id]
				if cb then
					state.pending[resp.id] = nil
					local body = nil
					local status = tonumber(resp.status) or 0
					if status > 0 and status < 400 then
						body = resp.body
					elseif status == 401 then
						-- SAP rechazo la auth por el camino del daemon: activa el freno
						-- anti-bloqueo (deja de mandar la contrasena erronea).
						pcall(function()
							require("sap-nvim.core.adt_http").on_auth_failure()
						end)
					end
					pcall(cb, body)
				end
			end
		end
	end
end

-- on_exit: el daemon murio. Marcamos el job como muerto (se re-arranca en la
-- proxima peticion) y resolvemos los pendientes con nil.
local function on_exit()
	state.job = nil
	state.buf = ""
	local pend = state.pending
	state.pending = {}
	for _, cb in pairs(pend) do
		pcall(cb, nil)
	end
end

-- ── Arranque (una sola vez) ──────────────────────────────────────────────────
function M.ensure()
	if state.job then
		return state.job
	end
	local c = require("sap-nvim.core.adt_http").creds()
	if not c then
		return nil
	end

	-- `-u`: python SIN buffer en stdin/stdout. CLAVE: sin esto, el pipe se bufferiza y las
	-- peticiones/respuestas no se entregan al instante -> el daemon "se queda pillado".
	state.job = vim.fn.jobstart({ "python3", "-u", script_path() }, {
		env = {
			ADT_BASE = c.base,
			ADT_CLIENT = c.client or "",
			ADT_USER = c.user,
			ADT_PASS = c.pass,
		},
		on_stdout = on_stdout,
		-- Drenar stderr (descartar): si nadie lo lee y el daemon escribe ahi, el pipe
		-- se llena y el daemon se BLOQUEA al escribir. Con este handler nunca pasa.
		on_stderr = function() end,
		on_exit = on_exit,
	})
	if state.job <= 0 then
		state.job = nil
		return nil
	end
	return state.job
end

-- ── Peticion asincrona ───────────────────────────────────────────────────────
-- opts: { method, path, query, body, accept, content_type, stateful }
-- cb se invoca con (body|nil). nil = no disponible / HTTP >=400 / fallo.
function M.request_async(opts, cb)
	if not M.available() then
		cb(nil)
		return
	end
	local job = M.ensure()
	if not job then
		cb(nil)
		return
	end

	state.next_id = state.next_id + 1
	local id = state.next_id
	state.pending[id] = cb

	local payload = {
		id = id,
		method = opts.method or "GET",
		path = opts.path,
		query = opts.query,
		body = opts.body,
		accept = opts.accept,
		content_type = opts.content_type,
		stateful = opts.stateful,
	}
	local ok, line = pcall(vim.json.encode, payload)
	if not ok then
		state.pending[id] = nil
		cb(nil)
		return
	end
	vim.fn.chansend(job, line .. "\n")
end

-- ── Parada ───────────────────────────────────────────────────────────────────
function M.stop()
	if state.job then
		pcall(vim.fn.jobstop, state.job)
		state.job = nil
	end
end

return M
