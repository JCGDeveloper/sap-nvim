-- sap-nvim.core.diff
-- Compare the current buffer with the active version in the SAP system.
-- Like "Compare With > Latest from Repository" in Eclipse.

local M = {}
local adt = require("sap-nvim.core.adt")
local sapcli = require("sap-nvim.core.sapcli")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Mapea la extensión del fichero → builder del comando sapcli read (FALLBACK).
local READERS = {
  abap = function(name) return { "sapcli", "program",   "read", name } end,
  prog = function(name) return { "sapcli", "program",   "read", name } end,
  cls  = function(name) return { "sapcli", "class",     "read", name } end,
  intf = function(name) return { "sapcli", "interface", "read", name } end,
}
-- Lista ordenada estable para mostrar
local SUPPORTED_EXTS = { "abap", "cls", "intf", "prog" }

local function open_diff(obj_name, system_lines)
  local cur_win  = vim.api.nvim_get_current_win()
  local cur_buf  = vim.api.nvim_get_current_buf()

  -- Scratch buffer with system source (read-only)
  local sys_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(sys_buf, 0, -1, false, system_lines)
  vim.bo[sys_buf].filetype    = vim.bo[cur_buf].filetype
  vim.bo[sys_buf].readonly    = true
  vim.bo[sys_buf].modifiable  = false
  vim.bo[sys_buf].bufhidden   = "wipe"
  pcall(vim.api.nvim_buf_set_name, sys_buf, obj_name .. " [SAP sistema]")

  -- Open a vertical split with the system buffer on the right
  vim.cmd("vsplit")
  local sys_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(sys_win, sys_buf)

  -- Activate diff mode on both sides
  vim.api.nvim_win_call(cur_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(sys_win, function() vim.cmd("diffthis") end)

  local function close_diff()
    -- Turn off diff in both windows before closing
    pcall(vim.api.nvim_win_call, cur_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_win_call, sys_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_buf_delete, sys_buf, { force = true })
  end

  -- 'q' on the system buffer closes the diff
  vim.keymap.set("n", "q", close_diff, { buffer = sys_buf, nowait = true, desc = "Cerrar diff SAP" })

  -- Also clean up if the scratch buffer is deleted any other way
  vim.api.nvim_create_autocmd("BufDelete", {
    buffer = sys_buf,
    once = true,
    callback = function()
      pcall(vim.api.nvim_win_call, cur_win, function() vim.cmd("diffoff") end)
    end,
  })

  notify("]c / [c para navegar diferencias · 'q' para cerrar el diff")
end

function M.diff_with_system()
  if not adt.is_configured() then
    notify("No hay conexion SAP configurada. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  local bufname  = vim.api.nvim_buf_get_name(0)
  local obj_name = vim.fn.fnamemodify(bufname, ":t:r"):upper()
  local ext      = vim.fn.fnamemodify(bufname, ":e"):lower()

  if obj_name == "" then
    notify("Guardá el archivo primero.", vim.log.levels.WARN)
    return
  end

  local reader = READERS[ext]
  if not reader then
    notify("Diff no soportado para ." .. ext .. ". Soportados: " ..
      table.concat(SUPPORTED_EXTS, ", "), vim.log.levels.WARN)
    return
  end

  notify("Obteniendo fuente del sistema para " .. obj_name .. "...")
  local lines  = {}
  local stderr = {}

  sapcli.jobstart(reader(obj_name), {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        -- jobstart always appends a trailing "" sentinel — skip it
        if line ~= "" then table.insert(lines, line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #lines == 0 then
          local err = #stderr > 0 and stderr[1] or "Sin respuesta del sistema (code " .. code .. ")"
          notify("Error obteniendo fuente: " .. err, vim.log.levels.ERROR)
          return
        end
        open_diff(obj_name, lines)
      end)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("SapDiff", function()
    M.diff_with_system()
  end, { desc = "sap-nvim: Comparar buffer local con version activa en SAP" })

  vim.keymap.set("n", "<leader>aD", M.diff_with_system, { desc = "ABAP: Diff contra sistema SAP" })
end

return M
