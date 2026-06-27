-- sap-nvim.core.statusline
-- Shows the active SAP connection in the statusline (lualine-compatible).
-- Usage in lualine config:
--   require('lualine').setup({ sections = { lualine_x = { require('sap-nvim.core.statusline').component } } })

local M = {}

local _cache = nil         -- { sysid, client, user } or nil
local _last_check = 0      -- os.time() of last parse
local _has_lualine = nil   -- cached lualine presence check

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

-- Returns a short activation indicator for the current buffer: "[OK]", "[ERR]", or "".
local function activation_indicator()
  local status = vim.b.sap_activation_status
  if status == "OK"  then return " [OK]" end
  if status == "ERR" then return " [ERR]" end
  return ""
end

-- Badge compacto de capacidades del objeto abierto, estilo Eclipse: "[V E A T]".
-- Cada letra aparece si la capacidad está; si no, se atenúa con "-". ASCII, legible en
-- cualquier terminal. Lee vim.b.sap_caps (cacheado por source.open); vacío si no hay objeto.
local function caps_badge()
  local caps = vim.b.sap_caps
  if not caps or not caps.view then return "" end
  local function flag(on, letter) return on and letter or "-" end
  return " [" .. flag(caps.view, "V")
    .. " " .. flag(caps.edit, "E")
    .. " " .. flag(caps.activate, "A")
    .. " " .. flag(caps.transport, "T") .. "]"
end

-- lualine component — add it to lualine_x or any section:
--   { require('sap-nvim.core.statusline').component, color = { fg = '#e8a87c' } }
M.component = {
  function()
    local ctx = get_cached()
    if not ctx then return "" end
    return " " .. ctx.sysid .. " · " .. ctx.client .. " · " .. ctx.user .. activation_indicator() .. caps_badge()
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
  -- Cache the lualine check — only compute once per session
  if _has_lualine == nil then
    _has_lualine = pcall(require, "lualine")
  end
  if not _has_lualine then
    local sap_part = " [SAP: " .. ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user .. activation_indicator() .. "]"
    vim.opt_local.statusline = "%f %m%=%y" .. sap_part .. caps_badge() .. " %l:%c "
  end
end

function M.setup()
  -- Prime the cache on startup
  M.refresh()

  -- Connection info is visible in the statusline — no startup notification needed

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

  -- Muestra las 4 capacidades del objeto abierto y, si algo está denegado, el motivo.
  vim.api.nvim_create_user_command("SapCaps", function()
    local bufnr = vim.api.nvim_get_current_buf()
    local ok, caps = pcall(function()
      return require("sap-nvim.core.source").capabilities(bufnr)
    end)
    if not ok or not caps or not caps.view then
      vim.notify("[sap-nvim] No hay objeto SAP abierto en este buffer.", vim.log.levels.WARN)
      return
    end
    local function mark(on) return on and "SÍ" or "no" end
    local lines = {
      "[sap-nvim] Capacidades del objeto:",
      "  VER       : " .. mark(caps.view),
      "  EDITAR    : " .. mark(caps.edit),
      "  ACTIVAR   : " .. mark(caps.activate),
      "  TRANSPORTAR: " .. mark(caps.transport),
    }
    if caps.reason and not (caps.edit and caps.activate and caps.transport) then
      table.insert(lines, "  Motivo    : " .. caps.reason)
    end
    vim.notify(table.concat(lines, "\n"), vim.log.levels.INFO)
  end, { desc = "sap-nvim: Mostrar capacidades (VER/EDITAR/ACTIVAR/TRANSPORTAR) del objeto" })

  vim.keymap.set("n", "<leader>asc", function()
    vim.cmd("SapCaps")
  end, { desc = "ABAP: Capacidades del objeto abierto" })
end

return M
