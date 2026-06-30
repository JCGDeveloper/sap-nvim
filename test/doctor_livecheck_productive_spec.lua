vim.opt.rtp:append(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.sapcli", "p")
vim.env.HOME = tmp
vim.env.XDG_STATE_HOME = tmp .. "/state"

local config_path = tmp .. "/.sapcli/config.yml"
vim.fn.writefile({
  "current-context: prd",
  "contexts:",
  "  prd:",
  "    connection: prd-conn",
  "    user: prd-user",
  "connections:",
  "  prd-conn:",
  "    sysid: PRD",
  "    ashost: prd.example",
  "    port: 44300",
  "    client: 100",
  "    ssl: true",
  "users:",
  "  prd-user:",
  "    user: DEVELOPER",
  "    password: plaintext-secret",
}, config_path)
vim.loop.fs_chmod(config_path, 420) -- 0644, intentionally unsafe for the check.

local ca_file = tmp .. "/prd-ca.pem"
vim.fn.writefile({ "CA" }, ca_file)

local config = require("sap-nvim.core.config")
config.setup({
  profile = "prod",
  security = { verify_tls = true, ca_file = ca_file },
})

local adt_stub = {
  ready = function() return false end,
  needs_login = function() return true end,
  context_info = function()
    return { sysid = "PRD", client = "100", user = "DEVELOPER", context = "prd" }
  end,
}

local doctor = require("sap-nvim.core.doctor")
local lines = table.concat(doctor._productive_readiness_lines({ adt_http = adt_stub }), "\n")

local function must_find(needle)
  if not lines:find(needle, 1, true) then
    error("missing readiness line: " .. needle .. "\n" .. lines)
  end
end

must_find("perfil activo: PROD (dev/qa/prod)")
must_find("current-context: prd")
must_find("~/.sapcli/config.yml permisos 0600 (644)")
must_find("~/.sapcli/config.yml sin password legacy")
must_find("TLS verify_tls requerido/listo")
must_find("CA file legible: " .. ca_file)
must_find("safe_mode activo")
must_find("prod read_only por defecto")
must_find("create bloqueado en prod salvo opt-in")
must_find("write/activate bloqueado en prod salvo opt-in")
must_find("release transporte bloqueado en prod salvo opt-in")
must_find("debug set-variable bloqueado")
must_find("conexión ADT: pausada/no validada; posible 401 previo, usa :SapRelogin")
must_find("contexto visible: PRD/100/DEVELOPER")

if not doctor._legacy_password_present("password: first-line-secret\n") then
  error("legacy password on first line was not detected")
end

local livecheck = require("sap-nvim.core.livecheck")
package.loaded["sap-nvim.core.adt_http"] = adt_stub
local summary = table.concat(livecheck._readiness_summary(config), "\n")
if not summary:find("Perfil: PROD", 1, true) then error("livecheck summary misses profile") end
if not summary:find("Conexión: pausada/no validada; posible 401 previo", 1, true) then
  error("livecheck summary misses paused connection state")
end
if not summary:find("safe_mode=true", 1, true) then error("livecheck summary misses safe_mode") end

print("DOCTOR_LIVECHECK_PRODUCTIVE_OK")
