-- sap-nvim.core.statusline
-- Shows the active SAP connection in the statusline (lualine-compatible).
-- Usage in lualine config:
--   require('lualine').setup({ sections = { lualine_x = { require('sap-nvim.core.statusline').component } } })

local M = {}

local _cache = nil         -- { sysid, client, user } or nil
local _last_check = 0      -- os.time() of last parse

local REFRESH_INTERVAL = 30  -- seconds between config re-reads

-- Read connection details from ~/.sapcli/config.yml
local function read_context()
  local config_path = vim.fn.expand("~/.sapcli/config.yml")
  local f = io.open(config_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  local current = content:match("current%-context:%s*([%w_%-]+)")
  if not current then return nil end

  local in_ctx = false
  local result = { name = current }

  for line in content:gmatch("[^\r\n]+") do
    if line:match("^" .. vim.pesc(current) .. ":%s*$") then
      in_ctx = true
    elseif in_ctx and not line:match("^%s") then
      break
    elseif in_ctx then
      local k, v = line:match("^%s+(%w+):%s*(.+)$")
      if k and v then
        result[k] = vim.trim(v)
      end
    end
  end

  return {
    sysid  = (result.sysid or result.name or "???"):upper():sub(1, 3),
    client = result.client or "???",
    user   = result.user and result.user:upper() or "???",
    ctx    = current,
  }
end

local function get_cached()
  local now = os.time()
  if not _cache or (now - _last_check) >= REFRESH_INTERVAL then
    _cache = read_context()
    _last_check = now
  end
  return _cache
end

-- Force a cache refresh (call after :SapSetup changes the active context)
function M.refresh()
  _cache = nil
  _last_check = 0
  local ctx = get_cached()
  if ctx then
    vim.g.sap_nvim_status = ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user
  else
    vim.g.sap_nvim_status = ""
  end
end

-- Returns a short string like "DEV/100/JCGOMEZ" or "" when not configured.
-- Suitable for any statusline that can call a Lua function.
function M.get_string()
  local ctx = get_cached()
  if not ctx then return "" end
  return ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user
end

-- lualine component — add it to lualine_x or any section:
--   { require('sap-nvim.core.statusline').component, color = { fg = '#e8a87c' } }
M.component = {
  function()
    local ctx = get_cached()
    if not ctx then return "" end
    return " " .. ctx.sysid .. " · " .. ctx.client .. " · " .. ctx.user
  end,
  cond = function()
    local ft = vim.bo.filetype
    return ft == "abap" or ft == "cls" or ft == "sap"
  end,
  color = { fg = "#e8a87c", gui = "bold" },
}

-- Built-in statusline snippet (for users without lualine).
-- Appends SAP info to the right side of the statusline on ABAP buffers.
local function apply_native_statusline()
  if vim.bo.filetype ~= "abap" then return end
  local ctx = get_cached()
  if not ctx then return end
  local sap_part = " [SAP: " .. ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user .. "]"
  -- Only set if lualine is not active
  local has_lualine = pcall(require, "lualine")
  if not has_lualine then
    vim.opt_local.statusline = "%f %m%=%y" .. sap_part .. " %l:%c "
  end
end

function M.setup()
  -- Prime the cache on startup
  M.refresh()

  -- Show connection on startup if configured
  local ctx = get_cached()
  if ctx then
    vim.notify(
      "[sap-nvim] Conectado a " .. ctx.sysid .. "/" .. ctx.client .. " como " .. ctx.user,
      vim.log.levels.INFO
    )
  end

  -- Update native statusline when entering ABAP buffers
  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = { "*.abap", "*.cls", "*.intf", "*.func", "*.fugr", "*.tabl", "*.ddls" },
    callback = apply_native_statusline,
    group = vim.api.nvim_create_augroup("sap_nvim_statusline", { clear = true }),
  })

  -- Expose a command to show current connection
  vim.api.nvim_create_user_command("SapStatus", function()
    M.refresh()
    local ctx = get_cached()
    if ctx then
      vim.notify(
        "[sap-nvim] Sistema: " .. ctx.sysid
          .. "  Cliente: " .. ctx.client
          .. "  Usuario: " .. ctx.user
          .. "  Contexto: " .. ctx.ctx,
        vim.log.levels.INFO
      )
    else
      vim.notify("[sap-nvim] Sin conexion SAP configurada. Usá :SapSetup.", vim.log.levels.WARN)
    end
  end, { desc = "sap-nvim: Mostrar conexion SAP activa" })

  vim.keymap.set("n", "<leader>asi", function()
    vim.cmd("SapStatus")
  end, { desc = "ABAP: Info de conexion activa" })
end

return M
