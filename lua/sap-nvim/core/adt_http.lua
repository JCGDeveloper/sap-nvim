-- sap-nvim.core.adt_http
-- Cliente HTTP directo contra la API REST de ADT (la misma que usa la extensión
-- `abap-remote-fs` de VSCode). sapcli NO expone completion/hover/navegación del sistema;
-- esto sí. Es la BASE de la "inteligencia" tipo VSCode: code completion (métodos de las
-- clases que llamas), element info (hover), navegación a definición y referencias.
--
-- Lee las credenciales de ~/.sapcli/config.yml (contexto actual). Usa `curl` (estándar)
-- vía vim.fn.system (sync, para completado on-demand) o jobstart (async).
--
-- SEGURIDAD: solo hace GET/POST de ADT de lectura/análisis (completion, elementinfo,
-- navegación). No escribe objetos por aquí (eso sigue por sapcli con su lock/transporte).

local M = {}

local secret = require("sap-nvim.core.secret")

-- active_ctx: contexto elegido en runtime (login). passwords: contraseñas EN MEMORIA
-- (nunca se escriben a disco), por contexto. La persistencia "estilo VSCode" (recordar entre
-- sesiones) la da el keyring del kernel (core.secret), no el disco.
-- auth_locked: FRENO ANTI-BLOQUEO. Cuando SAP rechaza la auth (401), lo activamos para DEJAR
-- DE MANDAR la contraseña errónea: es justo el martilleo de logins fallidos (uno por tecla en
-- el completado + daemon) lo que bloquea el usuario en SAP. Mientras esté activo, creds()
-- devuelve nil → nada de red. Se baja con un re-login explícito (use_connection).
local state = { creds = nil, token = nil, cookies = nil, active_ctx = nil, passwords = {}, auth_locked = false }

-- Resuelve la contraseña de `ctx`: 1º la de ESTA sesión (memoria), 2º la del keyring
-- (recordada estilo VSCode), 3º la de config.yml (texto plano, último recurso).
local function resolve_pass(ctx, cfg_pass)
  local p = state.passwords[ctx]
  if p and p ~= "" then return p end
  p = secret.get(ctx)
  if p and p ~= "" then return p end
  return cfg_pass
end

-- ── Parseo del config.yml de sapcli (YAML simple, sin librería) ──────────────
local function read_config()
  local f = io.open(vim.fn.expand("~/.sapcli/config.yml"), "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  return txt
end

-- Valor de `key` dentro del bloque indentado que empieza en `header:`.
local function field_in_block(txt, header, key)
  local in_block = false
  for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*" .. vim.pesc(header) .. ":%s*$") then
      in_block = true
    elseif in_block and line:match("^%S") then
      break -- siguiente sección de nivel 0
    elseif in_block then
      local v = line:match("^%s+" .. vim.pesc(key) .. ":%s*(.+)%s*$")
      if v then
        return (v:gsub("^['\"]", ""):gsub("['\"]%s*$", ""))
      end
    end
  end
  return nil
end

-- Construye las credenciales del contexto `ctx`. La password puede FALTAR (login pendiente).
local function parse_connection(txt, ctx)
  local conn = field_in_block(txt, ctx, "connection") or ctx
  local user_key = field_in_block(txt, ctx, "user") or (ctx .. "-user")
  local host = field_in_block(txt, conn, "ashost")
  local user = field_in_block(txt, user_key, "user")
  if not host or not user then
    return nil
  end
  local port = field_in_block(txt, conn, "port")
  local client = field_in_block(txt, conn, "client")
  local ssl = field_in_block(txt, conn, "ssl")
  local desc = field_in_block(txt, conn, "description")
  local pass = field_in_block(txt, user_key, "password")
  host = host:gsub("^https?://", "")
  local scheme = (ssl == "false") and "http" or "https"
  local base = scheme .. "://" .. host .. (port and (":" .. port) or "")
  return {
    context = ctx,
    connection = conn,
    description = desc or ctx,
    host = host,
    client = client or "",
    user = user,
    pass = pass,
    base = base,
  }
end

-- Nombres de contexto (las claves bajo `contexts:`).
local function list_context_names(txt)
  local names, in_block = {}, false
  for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^contexts:%s*$") then
      in_block = true
    elseif in_block and line:match("^%S") then
      break
    elseif in_block then
      local name = line:match("^%s+([%w_%-]+):%s*$")
      if name then
        names[#names + 1] = name
      end
    end
  end
  return names
end

local function active_context(txt)
  return state.active_ctx or txt:match("current%-context:%s*([%w_%-]+)")
end

-- Lista de conexiones disponibles (para el selector de login).
function M.list_connections()
  local txt = read_config()
  if not txt then
    return {}
  end
  local out = {}
  for _, ctx in ipairs(list_context_names(txt)) do
    local c = parse_connection(txt, ctx)
    if c then
      out[#out + 1] = c
    end
  end
  return out
end

-- Selecciona la conexión activa + (opcional) password. La password se guarda en memoria Y,
-- salvo opts.persist == false, en el keyring del kernel (recordar estilo VSCode: la tecleas una
-- vez y se reusa entre sesiones de nvim). Un re-login SIEMPRE baja el freno anti-bloqueo.
-- Invalida credenciales/token/cookies para forzar sesión limpia con la nueva conexión.
function M.use_connection(ctx, password, opts)
  opts = opts or {}
  state.active_ctx = ctx
  state.auth_locked = false -- re-login intencionado → reanudamos la actividad de red
  if password and password ~= "" then
    state.passwords[ctx] = password
    if opts.persist ~= false then
      pcall(secret.set, ctx, password)
    end
  end
  state.creds = nil
  state.token = nil
  pcall(os.remove, vim.fn.stdpath("cache") .. "/sap-nvim/adt_cookies.txt")
  -- El daemon captura las credenciales al ARRANCAR (env vars): si no lo reiniciamos,
  -- seguiría autenticando con la conexión/contraseña anteriores -> 401. Lo paramos para
  -- que el siguiente request lo relance con las credenciales nuevas.
  pcall(function()
    require("sap-nvim.core.adt_daemon").stop()
  end)
end

-- ¿La respuesta es una página de error de SAP (401/login) en vez de datos? Cuando las
-- credenciales fallan, ADT devuelve HTML ("Nicht autorisiert"/"Unauthorized") con 200/401.
function M.is_auth_error(body)
  if not body or body == "" then
    return false
  end
  return body:match("^%s*<!?[Hh][Tt][Mm][Ll]") ~= nil
    or body:match("^%s*<!DOCTYPE") ~= nil
    or body:find("Nicht autorisiert", 1, true) ~= nil
    or body:find("Unauthorized", 1, true) ~= nil
    or body:find("Logon failed", 1, true) ~= nil
end

function M.creds()
  if state.auth_locked then
    return nil -- freno anti-bloqueo activo: NO mandamos credenciales hasta un re-login
  end
  if state.creds then
    return state.creds
  end
  local txt = read_config()
  if not txt then
    return nil
  end
  local ctx = active_context(txt)
  if not ctx then
    return nil
  end
  local c = parse_connection(txt, ctx)
  if not c then
    return nil
  end
  local pass = resolve_pass(ctx, c.pass)
  if not pass or pass == "" then
    return nil -- falta password → login pendiente (M.needs_login() == true)
  end
  c.pass = pass
  state.creds = c
  return c
end

-- ¿Hay conexión configurada (host/user) pero falta la contraseña? (para disparar el login)
function M.needs_login()
  if state.auth_locked then
    return true -- SAP rechazó la auth → hay que volver a teclear la contraseña
  end
  local txt = read_config()
  if not txt then
    return false
  end
  local ctx = active_context(txt)
  local c = ctx and parse_connection(txt, ctx)
  if not c then
    return false
  end
  local pass = resolve_pass(ctx, c.pass)
  return pass == nil or pass == ""
end

-- ── Freno anti-bloqueo ───────────────────────────────────────────────────────
-- SAP bloquea el usuario tras N logins fallidos (login/fails_to_user_lock, por defecto 5). El
-- completado dispara una petición ADT por tecla (+ daemon + warmup): con una contraseña errónea
-- eso son N fallos en segundos → usuario bloqueado. En cuanto detectamos el 401/página de login
-- de SAP, ACTIVAMOS el freno: paramos el daemon, olvidamos la contraseña errónea (memoria +
-- keyring) y avisamos UNA vez. A partir de ahí creds() devuelve nil → cero red — hasta :SapRelogin.
function M.on_auth_failure()
  if state.auth_locked then
    return
  end
  state.auth_locked = true
  state.creds = nil
  state.token = nil
  local txt = read_config()
  local ctx = state.active_ctx or (txt and active_context(txt))
  if ctx then
    state.passwords[ctx] = nil
    pcall(secret.clear, ctx)
  end
  pcall(function()
    require("sap-nvim.core.adt_daemon").stop()
  end)
  vim.schedule(function()
    vim.notify(
      "[sap-nvim] SAP rechazó la autenticación (401). Conexión PAUSADA para NO bloquear tu "
        .. "usuario. Verifica la contraseña y reconecta con :SapRelogin.",
      vim.log.levels.ERROR
    )
  end)
end

-- Inspecciona un body de respuesta; si es la página de error/login de SAP, dispara el freno.
-- Devuelve el body intacto para no alterar a los llamantes.
local function check_auth(body)
  if body and M.is_auth_error(body) then
    M.on_auth_failure()
  end
  return body
end

function M.is_available()
  return M.creds() ~= nil and vim.fn.executable("curl") == 1
end

-- ── CSRF token + cookies (necesarios para POST) ──────────────────────────────
local function cookie_file()
  local dir = vim.fn.stdpath("cache") .. "/sap-nvim"
  vim.fn.mkdir(dir, "p")
  return dir .. "/adt_cookies.txt"
end

-- Credenciales para curl SIN exponerlas en argv (cualquiera con `ps` vería `-u user:pass`).
-- En su lugar pasamos `-K -` y curl lee `user = "u:p"` de STDIN. La contraseña NO toca disco
-- (igual que el resto del módulo) ni la línea de comandos. En POST el cuerpo va por
-- `--data-binary @fichero`, así que STDIN queda libre para esta config.
local function curl_cfg(c)
  local esc = function(s) return (tostring(s or "")):gsub("\\", "\\\\"):gsub('"', '\\"') end
  return 'user = "' .. esc(c.user .. ":" .. c.pass) .. '"\n'
end

-- Obtiene (y cachea) el token CSRF y el cookie-jar de la sesión. Sync.
local function ensure_token(c)
  if state.token then return state.token end
  local hdr = vim.fn.tempname()
  vim.fn.system({
    "curl", "-sk", "-K", "-",
    "-c", cookie_file(), "-H", "X-CSRF-Token: Fetch",
    "-D", hdr, "-o", "/dev/null",
    c.base .. "/sap/bc/adt/core/discovery?sap-client=" .. c.client,
  }, curl_cfg(c))
  local lines = vim.fn.readfile(hdr); pcall(os.remove, hdr)
  for _, l in ipairs(lines) do
    local t = l:match("^[Xx]%-[Cc][Ss][Rr][Ff]%-[Tt]oken:%s*(%S+)")
    if t then state.token = t; break end
  end
  return state.token
end

-- ── Petición genérica ────────────────────────────────────────────────────────
-- opts: { method="GET"|"POST", path=..., query={k=v}, body=<string>, accept=... }
-- Devuelve el body (string) o nil + error. Sync (vim.fn.system).
function M.request(opts)
  local c = M.creds()
  if not c then return nil, "Sin credenciales SAP (config.yml)" end

  local url = c.base .. opts.path
  local sep = opts.path:find("?") and "&" or "?"
  url = url .. sep .. "sap-client=" .. c.client
  if opts.query then
    for k, v in pairs(opts.query) do url = url .. "&" .. k .. "=" .. v end
  end

  local args = { "curl", "-sk", "-K", "-", "-b", cookie_file() }
  if opts.accept then vim.list_extend(args, { "-H", "Accept: " .. opts.accept }) end
  if (opts.method or "GET"):upper() == "POST" then
    local token = ensure_token(c)
    if token then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. token }) end
    vim.list_extend(args, { "-H", "Content-Type: " .. (opts.content_type or "text/plain") })
    local bodyfile = vim.fn.tempname()
    vim.fn.writefile(vim.split(opts.body or "", "\n"), bodyfile)
    vim.list_extend(args, { "--data-binary", "@" .. bodyfile })
    vim.list_extend(args, { url })
    local out = vim.fn.system(args, curl_cfg(c))
    pcall(os.remove, bodyfile)
    return check_auth(out)
  else
    vim.list_extend(args, { url })
    return check_auth(vim.fn.system(args, curl_cfg(c)))
  end
end

-- ── Petición ASYNC (para completado en cada tecla, sin bloquear) ─────────────
-- Construye los argumentos de curl (compartido con la versión sync).
local function build_args(c, opts)
  local url = c.base .. opts.path
  local sep = opts.path:find("?") and "&" or "?"
  url = url .. sep .. "sap-client=" .. c.client
  if opts.query then
    for k, v in pairs(opts.query) do url = url .. "&" .. k .. "=" .. v end
  end
  local args = { "curl", "-sk", "-K", "-", "-b", cookie_file() }
  if opts.accept then vim.list_extend(args, { "-H", "Accept: " .. opts.accept }) end
  local bodyfile
  if (opts.method or "GET"):upper() == "POST" then
    local token = ensure_token(c) -- sync, cacheado tras la 1ª vez (GET rápido)
    if token then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. token }) end
    vim.list_extend(args, { "-H", "Content-Type: " .. (opts.content_type or "text/plain") })
    bodyfile = vim.fn.tempname()
    vim.fn.writefile(vim.split(opts.body or "", "\n"), bodyfile)
    vim.list_extend(args, { "--data-binary", "@" .. bodyfile })
  end
  vim.list_extend(args, { url })
  return args, bodyfile
end

-- Implementación con curl (un proceso por llamada). Fallback del daemon persistente.
local function curl_request_async(opts, cb)
  local c = M.creds()
  if not c then cb(nil); return end
  local args, bodyfile = build_args(c, opts)
  local out = {}
  local job = vim.fn.jobstart(args, {
    stdout_buffered = true,
    on_stdout = function(_, data) for _, l in ipairs(data) do out[#out + 1] = l end end,
    on_exit = function()
      if bodyfile then pcall(os.remove, bodyfile) end
      cb(check_auth(table.concat(out, "\n")))
    end,
  })
  -- Las credenciales van por STDIN (`-K -`), no por argv. Cerramos stdin para que curl
  -- termine de leer la config y continúe con la petición.
  if job and job > 0 then
    pcall(vim.fn.chansend, job, curl_cfg(c))
    pcall(vim.fn.chanclose, job, "stdin")
  end
  return job
end

-- Solo se desactiva si el daemon NI ARRANCA (no por un timeout puntual).
local daemon_dead = false

local function daemon_mod()
  if daemon_dead then return nil end
  local ok, d = pcall(require, "sap-nvim.core.adt_daemon")
  if ok and d and d.available() then return d end
  return nil
end

-- Calienta la CONEXIÓN PERSISTENTE (arranca el daemon + login) al abrir un objeto, para que
-- la 1ª propuesta ya vaya caliente y con el token CSRF establecido — como VSCode al abrir el
-- FS remoto. Resuelve TANTO la latencia como el "0 intermitente" (token frío) del completado.
function M.warmup()
  local d = daemon_mod()
  if d and pcall(d.ensure) == false then daemon_dead = true end
end

-- cb(body|nil). No bloquea. Prefiere la conexión PERSISTENTE (daemon, como VSCode): token
-- CSRF + cookies una vez, socket caliente -> rápido y SIN el 0 intermitente del token frío.
-- Si el daemon no responde a tiempo o devuelve nil, cae a curl SOLO esa vez (el daemon sigue
-- activo). Si ni arranca, se marca muerto y se usa curl. Nunca rompe el completado.
function M.request_async(opts, cb)
  if not M.creds() then cb(nil); return end
  local d = daemon_mod()
  if not d then curl_request_async(opts, cb); return end
  if pcall(d.ensure) == false then daemon_dead = true; curl_request_async(opts, cb); return end

  local answered = false
  vim.defer_fn(function()
    if answered then return end
    answered = true
    curl_request_async(opts, cb) -- fallback puntual; el daemon sigue para la próxima
  end, 12000)
  d.request_async(opts, function(body)
    if answered then return end
    answered = true
    if body then cb(body) else curl_request_async(opts, cb) end
  end)
end

-- :SapDaemonTest -> prueba el camino del daemon y reporta count+latencia (verificar en vivo).
function M.daemon_self_test(opts, cb)
  local d = daemon_mod()
  if not d then cb(nil, "daemon no disponible"); return end
  pcall(d.ensure)
  local t0 = vim.loop.hrtime()
  d.request_async(opts, function(body)
    cb(body, string.format("%.0f ms", (vim.loop.hrtime() - t0) / 1e6))
  end)
end

-- ── Petición CRUDA flexible (para lock/PUT/unlock de text elements, etc.) ────
-- opts: { method, path, query, body, accept, content_type, stateful, headers={..} }
-- Devuelve body (string), headers (string), http_code (number). Sync.
function M.raw(opts)
  local c = M.creds()
  if not c then return nil, nil, 0 end
  local url = c.base .. opts.path
  local sep = opts.path:find("?") and "&" or "?"
  url = url .. sep .. "sap-client=" .. c.client
  if opts.query then for k, v in pairs(opts.query) do url = url .. "&" .. k .. "=" .. v end end

  local method = (opts.method or "GET"):upper()
  local args = { "curl", "-sk", "-K", "-", "-b", cookie_file(), "-c", cookie_file() }
  vim.list_extend(args, { "-X", method })
  if method ~= "GET" then
    local token = ensure_token(c)
    if token then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. token }) end
  end
  if opts.stateful then vim.list_extend(args, { "-H", "X-sap-adt-sessiontype: stateful" }) end
  if opts.accept then vim.list_extend(args, { "-H", "Accept: " .. opts.accept }) end
  if opts.content_type then vim.list_extend(args, { "-H", "Content-Type: " .. opts.content_type }) end
  for _, h in ipairs(opts.headers or {}) do vim.list_extend(args, { "-H", h }) end

  local bodyfile
  if opts.body then
    bodyfile = vim.fn.tempname()
    vim.fn.writefile(vim.split(opts.body, "\n"), bodyfile)
    vim.list_extend(args, { "--data-binary", "@" .. bodyfile })
  end
  local hdrfile = vim.fn.tempname()
  vim.list_extend(args, { "-D", hdrfile, url })

  local body = vim.fn.system(args, curl_cfg(c))
  local headers, code = "", 0
  pcall(function()
    headers = table.concat(vim.fn.readfile(hdrfile), "\n")
    code = tonumber(headers:match("HTTP/[%d%.]+%s+(%d+)")) or 0
  end)
  if bodyfile then pcall(os.remove, bodyfile) end
  pcall(os.remove, hdrfile)
  if code == 401 or M.is_auth_error(body) then
    M.on_auth_failure()
  end
  return body, headers, code
end

-- Invalida el token (p.ej. si un POST devuelve 403 CSRF). El siguiente lo re-obtiene.
function M.reset_token() state.token = nil end

return M
