-- sap-nvim.core.log
-- Local session log viewer/exporter. It never stores secrets and does not contact SAP.

local M = {}

local entries = {}
local max_entries = 500

local function state_dir()
  local dir = vim.fn.stdpath("state") .. "/sap-nvim"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function log_path()
  return state_dir() .. "/session.log"
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function level_name(level)
  if level == vim.log.levels.ERROR then return "ERROR" end
  if level == vim.log.levels.WARN then return "WARN" end
  if level == vim.log.levels.DEBUG then return "DEBUG" end
  if level == vim.log.levels.TRACE then return "TRACE" end
  return "INFO"
end

local function sanitize(msg)
  msg = tostring(msg or "")
  msg = msg:gsub("([Pp]assword%s*[:=]%s*)%S+", "%1***")
  msg = msg:gsub("([Ss][Aa][Pp]_[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*)%S+", "%1***")
  msg = msg:gsub("([Ss][Aa][Pp]%-[Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*)%S+", "%1***")
  msg = msg:gsub("([Ss][Aa][Pp][Pp][Aa][Ss][Ss][Ww][Oo][Rr][Dd]%s*[:=]%s*)%S+", "%1***")
  return msg
end

function M.add(msg, level, meta)
  local item = {
    ts = now(),
    level = level_name(level),
    message = sanitize(msg),
    meta = meta or {},
  }
  entries[#entries + 1] = item
  if #entries > max_entries then
    table.remove(entries, 1)
  end
  return item
end

function M.entries()
  return vim.deepcopy(entries)
end

local function encode_line(item)
  local ok, encoded = pcall(vim.json.encode, item)
  if ok then return encoded end
  return string.format("[%s] %s %s", item.ts, item.level, item.message)
end

function M.export(path)
  path = path and path ~= "" and vim.fn.expand(path) or log_path()
  local lines = {}
  for _, item in ipairs(entries) do
    lines[#lines + 1] = encode_line(item)
  end
  pcall(vim.fn.mkdir, vim.fn.fnamemodify(path, ":h"), "p")
  vim.fn.writefile(lines, path)
  return path, #lines
end

local function render_lines()
  local lines = {
    "SAP Logs",
    "",
    "q cerrar  r refrescar  e exportar",
    "",
  }
  if #entries == 0 then
    lines[#lines + 1] = "(sin logs en esta sesion)"
    return lines
  end
  for _, item in ipairs(entries) do
    lines[#lines + 1] = string.format("%s  %-5s  %s", item.ts, item.level, item.message)
  end
  return lines
end

function M.open()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "saplogs"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://logs")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines())
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_win_set_height, 0, 14)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", function() pcall(vim.api.nvim_win_close, 0, true) end, opts)
  vim.keymap.set("n", "r", function()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines())
    vim.bo[buf].modifiable = false
  end, opts)
  vim.keymap.set("n", "e", function()
    local path, count = M.export()
    vim.notify("[sap-nvim] Logs exportados: " .. path .. " (" .. count .. " lineas)", vim.log.levels.INFO)
  end, opts)
end

function M.clear()
  entries = {}
end

function M.setup(opts)
  opts = opts or {}
  max_entries = tonumber(opts.log and opts.log.max_entries) or max_entries

  vim.api.nvim_create_user_command("SapLogs", M.open, { desc = "sap-nvim: Ver logs locales de sesion" })
  vim.api.nvim_create_user_command("SapLogsExport", function(args)
    local path, count = M.export(args.args ~= "" and args.args or nil)
    vim.notify("[sap-nvim] Logs exportados: " .. path .. " (" .. count .. " lineas)", vim.log.levels.INFO)
  end, { nargs = "?", complete = "file", desc = "sap-nvim: Exportar logs locales" })
  vim.api.nvim_create_user_command("SapLogsClear", function()
    M.clear()
    vim.notify("[sap-nvim] Logs locales limpiados.", vim.log.levels.INFO)
  end, { desc = "sap-nvim: Limpiar logs locales" })
end

M._sanitize = sanitize
M._render_lines = render_lines

return M
