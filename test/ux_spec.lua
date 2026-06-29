-- Offline regression tests for home/log UX helpers.

vim.env.XDG_STATE_HOME = "/tmp/sap-nvim-ux-test-" .. tostring(vim.fn.getpid())
vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg) print(msg) end

local log = require("sap-nvim.core.log")
local home = require("sap-nvim.core.home")

log.setup({})
home.setup({})

if vim.fn.exists(":SapLogs") ~= 2 then error("SapLogs command missing") end
if vim.fn.exists(":SapLogsExport") ~= 2 then error("SapLogsExport command missing") end
if vim.fn.exists(":SapHome") ~= 2 then error("SapHome command missing") end

log.clear()
log.add("password: secret SAP_PASSWORD=hidden visible", vim.log.levels.WARN)
local entries = log.entries()
if #entries ~= 1 then error("log entry was not recorded") end
if entries[1].message:find("secret", 1, true) or entries[1].message:find("hidden", 1, true) then
  error("log sanitizer leaked a password")
end

local path, count = log.export()
if count ~= 1 or vim.fn.filereadable(path) ~= 1 then
  error("log export failed")
end

local keys = {}
for _, action in ipairs(home._menu) do
  keys[action.key] = action.desc
end
for _, key in ipairs({ "e", "i", "I", "D", "l" }) do
  if not keys[key] then
    error("home menu missing key " .. key)
  end
end
if keys.Q or keys.v then
  error("home menu must not include object-dependent Quality/Revisions actions")
end
if keys.q ~= "Salir" then
  error("home q action should remain exit")
end

print("UX_SPEC_OK")
