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

local state = { creds = nil, token = nil, cookies = nil }

-- ── Parseo del config.yml de sapcli (YAML simple, sin librería) ──────────────
local function parse_creds()
  local path = vim.fn.expand("~/.sapcli/config.yml")
  local f = io.open(path, "r")
  if not f then return nil end
  local txt = f:read("*a"); f:close()

  local ctx = txt:match("current%-context:%s*([%w_%-]+)")
  if not ctx then return nil end

  -- Devuelve el valor `key` dentro del bloque indentado que empieza en `header:`.
  local function field_in_block(header, key)
    local in_block = false
    for line in (txt .. "\n"):gmatch("([^\n]*)\n") do
      if line:match("^%s*" .. vim.pesc(header) .. ":%s*$") then
        in_block = true
      elseif in_block and line:match("^%S") then
        break -- siguiente sección de nivel 0
      elseif in_block then
        local v = line:match("^%s+" .. vim.pesc(key) .. ":%s*(.+)%s*$")
        if v then return (v:gsub("^['\"]", ""):gsub("['\"]%s*$", "")) end
      end
    end
    return nil
  end

  local conn = field_in_block(ctx, "connection") or ctx
  local user_key = field_in_block(ctx, "user") or (ctx .. "-user")
  local host = field_in_block(conn, "ashost")
  local port = field_in_block(conn, "port")
  local client = field_in_block(conn, "client")
  local ssl = field_in_block(conn, "ssl")
  local user = field_in_block(user_key, "user")
  local pass = field_in_block(user_key, "password")
  if not (host and user and pass) then return nil end

  host = host:gsub("^https?://", "")
  local scheme = (ssl == "false") and "http" or "https"
  local base = scheme .. "://" .. host .. (port and (":" .. port) or "")
  return { base = base, client = client or "", user = user, pass = pass }
end

function M.creds()
  if not state.creds then state.creds = parse_creds() end
  return state.creds
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

-- Obtiene (y cachea) el token CSRF y el cookie-jar de la sesión. Sync.
local function ensure_token(c)
  if state.token then return state.token end
  local hdr = vim.fn.tempname()
  vim.fn.system({
    "curl", "-sk", "-u", c.user .. ":" .. c.pass,
    "-c", cookie_file(), "-H", "X-CSRF-Token: Fetch",
    "-D", hdr, "-o", "/dev/null",
    c.base .. "/sap/bc/adt/core/discovery?sap-client=" .. c.client,
  })
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

  local args = { "curl", "-sk", "-u", c.user .. ":" .. c.pass, "-b", cookie_file() }
  if opts.accept then vim.list_extend(args, { "-H", "Accept: " .. opts.accept }) end
  if (opts.method or "GET"):upper() == "POST" then
    local token = ensure_token(c)
    if token then vim.list_extend(args, { "-H", "X-CSRF-Token: " .. token }) end
    vim.list_extend(args, { "-H", "Content-Type: " .. (opts.content_type or "text/plain") })
    local bodyfile = vim.fn.tempname()
    vim.fn.writefile(vim.split(opts.body or "", "\n"), bodyfile)
    vim.list_extend(args, { "--data-binary", "@" .. bodyfile })
    vim.list_extend(args, { url })
    local out = vim.fn.system(args)
    pcall(os.remove, bodyfile)
    return out
  else
    vim.list_extend(args, { url })
    return vim.fn.system(args)
  end
end

-- Invalida el token (p.ej. si un POST devuelve 403 CSRF). El siguiente lo re-obtiene.
function M.reset_token() state.token = nil end

return M
