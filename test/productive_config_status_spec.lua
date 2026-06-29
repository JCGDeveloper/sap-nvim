vim.opt.rtp:append(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.sapcli", "p")
vim.env.HOME = tmp
vim.env.XDG_STATE_HOME = tmp .. "/state"

local config = require("sap-nvim.core.config")
config.setup({ profile = "prod", security = { verify_tls = true } })

local prod = config.productive()
if config.profile_name() ~= "prod" then error("profile prod was not selected") end
if prod.read_only ~= true then error("prod profile must be read-only by default") end
if prod.allow_create_objects ~= false then error("prod create must be blocked by default") end
if prod.allow_write_objects ~= false then error("prod write must be blocked by default") end
if prod.allow_release_transports ~= false then error("prod release must be blocked by default") end

config.audit("blocked", { action_kind = "write_object", target = "ZREP" })
local audit = table.concat(vim.fn.readfile(config.audit_path()), "\n")
if not audit:find('"profile":"prod"', 1, true) then error("audit log does not include profile") end
if not audit:find('"target":"ZREP"', 1, true) then error("audit log does not include target") end

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
}, tmp .. "/.sapcli/config.yml")

local status = require("sap-nvim.core.statusline")
status.refresh()
local s = status.get_string()
if s ~= "PROD:PRD/100/DEVELOPER" then
  error("unexpected status string: " .. tostring(s))
end

print("PRODUCTIVE_CONFIG_STATUS_OK")
