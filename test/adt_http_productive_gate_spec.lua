vim.opt.rtp:append(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.sapcli", "p")
vim.env.HOME = tmp
vim.env.XDG_STATE_HOME = tmp .. "/state"

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

package.loaded["sap-nvim.core.secret"] = {
  get = function() return "secret" end,
  set = function() end,
  clear = function() end,
}

local config = require("sap-nvim.core.config")
config.setup({ profile = "prod", security = { verify_tls = true } })

local notifications = {}
vim.notify = function(msg)
  notifications[#notifications + 1] = msg
end

local system_calls = 0
local old_system = vim.fn.system
vim.fn.system = function()
  system_calls = system_calls + 1
  return ""
end

package.loaded["sap-nvim.core.adt_http"] = nil
local adt = require("sap-nvim.core.adt_http")
adt.mark_validated()

local body, _, code = adt.raw({
  method = "POST",
  path = "/sap/bc/adt/packages",
  body = "<package/>",
  content_type = "application/xml",
})

vim.fn.system = old_system

if body ~= nil or code ~= 0 then
  error("blocked ADT create returned a response")
end
if system_calls ~= 0 then
  error("blocked ADT create spawned curl")
end
local audit = table.concat(vim.fn.readfile(config.audit_path()), "\n")
if not audit:find('"reason":"read_only"', 1, true) then
  error("ADT read_only block was not audited")
end
if not audit:find('"sysid":"PRD"', 1, true) then
  error("ADT audit does not include sysid")
end
if not notifications[1] or not notifications[1]:find("solo lectura", 1, true) then
  error("ADT read_only block did not notify")
end

local routes = {
  "/sap/bc/adt/ddic/tables",
  "/sap/bc/adt/ddic/structures",
  "/sap/bc/adt/ddic/dataelements",
  "/sap/bc/adt/ddic/domains",
  "/sap/bc/adt/ddic/tabletypes",
  "/sap/bc/adt/ddic/ddlx/sources",
  "/sap/bc/adt/acm/dcl/sources",
  "/sap/bc/adt/bo/behaviordefinitions",
  "/sap/bc/adt/ddic/srvd/sources",
}
for _, path in ipairs(routes) do
  local action = adt._classify_sensitive({ method = "POST", path = path })
  if not action or action.kind ~= "create_object" or action.allow ~= "allow_create_objects" then
    error("ADT create route is not gated: " .. path)
  end
end

print("ADT_HTTP_PRODUCTIVE_GATE_OK")
