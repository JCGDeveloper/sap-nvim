-- sap-nvim.core.statusline
-- Shows the active SAP connection in the statusline (lualine-compatible).
-- Usage in lualine config:
--   require('lualine').setup({ sections = { lualine_x = { require('sap-nvim.core.statusline').component } } })

local M = {}

local _cache = nil         -- { sysid, client, user } or nil
local _last_check = 0      -- os.time() of last parse
local _has_lualine = nil   -- cached lualine presence check

local REFRESH_INTERVAL = 30  -- seconds between config re-reads

local function field_in_block(content, header, key)
  local in_block = false
  for line in (content .. "\n"):gmatch("([^\n]*)\n") do
    if line:match("^%s*" .. vim.pesc(header) .. ":%s*$") then
      in_block = true
    elseif in_block and line:match("^%S") then
      break
    elseif in_block then
      local v = line:match("^%s+" .. vim.pesc(key) .. ":%s*(.+)%s*$")
      if v then return (v:gsub("^['\"]", ""):gsub("['\"]%s*$", "")) end
    end
  end
  return nil
end

local function active_profile()
  local ok, cfg = pcall(require, "sap-nvim.core.config")
  if ok and cfg.profile_name then
    return cfg.profile_name():upper()
  end
  return "DEV"
end

-- Read connection details from ~/.sapcli/config.yml
local function read_context()
  local config_path = vim.fn.expand("~/.sapcli/config.yml")
  local f = io.open(config_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  local current = content:match("current%-context:%s*([%w_%-]+)")
  if not current then return nil end

  local conn = field_in_block(content, current, "connection") or current
  local user_ref = field_in_block(content, current, "user") or (current .. "-user")
  local sysid = field_in_block(content, conn, "sysid") or field_in_block(content, conn, "sid")
  local client = field_in_block(content, conn, "client")
  local user = field_in_block(content, user_ref, "user")

  return {
    sysid  = ((sysid or conn or current or "???"):upper():match("[A-Z0-9]+") or "???"):sub(1, 3),
    client = client or "???",
    user   = user and user:upper() or "???",
    ctx    = current,
    profile = active_profile(),
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
    vim.g.sap_nvim_status = ctx.profile .. ":" .. ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user
  else
    vim.g.sap_nvim_status = ""
  end
end

-- Returns a short string like "DEV/100/JCGOMEZ" or "" when not configured.
-- Suitable for any statusline that can call a Lua function.
function M.get_string()
  local ctx = get_cached()
  if not ctx then return "" end
  return ctx.profile .. ":" .. ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user
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
    return " " .. ctx.profile .. " · " .. ctx.sysid .. " · " .. ctx.client .. " · " .. ctx.user .. activation_indicator() .. caps_badge()
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
    local sap_part = " [SAP: " .. ctx.profile .. ":" .. ctx.sysid .. "/" .. ctx.client .. "/" .. ctx.user .. activation_indicator() .. "]"
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
          .. "  Perfil: " .. ctx.profile
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
