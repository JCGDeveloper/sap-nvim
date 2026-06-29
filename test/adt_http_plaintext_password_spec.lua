-- Offline regression test: plaintext password in ~/.sapcli/config.yml is ignored by default.
--
-- Run:
--   nvim --headless -u NONE -i NONE -S test/adt_http_plaintext_password_spec.lua

vim.opt.rtp:append(vim.fn.getcwd())

local tmp = vim.fn.tempname()
vim.fn.mkdir(tmp .. "/.sapcli", "p")
vim.env.HOME = tmp
vim.notify = function(msg)
	print(msg)
end

vim.fn.writefile({
	"current-context: dev",
	"contexts:",
	"  dev:",
	"    connection: dev-conn",
	"    user: dev-user",
	"connections:",
	"  dev-conn:",
	"    ashost: sap.example",
	"    port: 44300",
	"    client: 100",
	"    ssl: true",
	"users:",
	"  dev-user:",
	"    user: DEVELOPER",
	"    password: plaintext-secret",
}, tmp .. "/.sapcli/config.yml")

package.loaded["sap-nvim.core.secret"] = {
	get = function()
		return nil
	end,
	set = function() end,
	clear = function() end,
}

package.loaded["sap-nvim.core.config"] = nil
local config = require("sap-nvim.core.config")
config.setup({})
package.loaded["sap-nvim.core.adt_http"] = nil
local adt = require("sap-nvim.core.adt_http")

if adt.creds() ~= nil then
	error("plaintext password was accepted without opt-in")
end

config.setup({ security = { allow_plaintext_password = true } })
package.loaded["sap-nvim.core.adt_http"] = nil
adt = require("sap-nvim.core.adt_http")

local creds = adt.creds()
if not creds or creds.pass ~= "plaintext-secret" then
	error("plaintext password opt-in did not work")
end

print("ADT_HTTP_PLAINTEXT_PASSWORD_OK")
