-- sap-nvim.core.whereused
-- Where-used list: find all ABAP objects that reference the current object.
-- Results load into the quickfix list so the user can jump between them.

local M = {}
local adt = require("sap-nvim.core.adt")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local CMDS = {
  abap = function(name) return { "sapcli", "program",   "whereused", name } end,
  prog = function(name) return { "sapcli", "program",   "whereused", name } end,
  cls  = function(name) return { "sapcli", "class",     "whereused", name } end,
  intf = function(name) return { "sapcli", "interface", "whereused", name } end,
}

local EXTENSIONS = { "abap", "cls", "intf", "func", "fugr", "tabl", "ddls", "bdef", "stru", "dtel" }

local function find_local(obj_name)
  local cwd = vim.fn.getcwd()
  for _, ext in ipairs(EXTENSIONS) do
    local path = cwd .. "/" .. obj_name:lower() .. "." .. ext
    local f = io.open(path, "r")
    if f then f:close() return path end
  end
  return nil
end

local function do_whereused(obj_name, cmd)
  notify("Buscando referencias a " .. obj_name .. "...")
  local lines, stderr = {}, {}

  vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(lines, l) end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #lines == 0 then
          local msg = #stderr > 0 and stderr[1] or "Sin referencias para " .. obj_name
          notify(msg, vim.log.levels.WARN)
          return
        end

        local qf = {}
        for _, line in ipairs(lines) do
          local ref = vim.trim(line)
          if ref ~= "" then
            local path = find_local(ref)
            table.insert(qf, {
              filename = path or "",
              lnum     = 1,
              col      = 1,
              text     = ref .. (path and "  [local]" or "  [sistema]"),
              type     = "I",
            })
          end
        end

        if #qf == 0 then
          notify("Sin referencias para " .. obj_name, vim.log.levels.WARN)
          return
        end

        vim.fn.setqflist({}, "r")
        vim.fn.setqflist(qf, "r")
        vim.fn.setqflist({}, "a", { title = "Where-used: " .. obj_name })
        vim.cmd("copen")
        notify(#qf .. " referencia(s) encontrada(s) para " .. obj_name)
      end)
    end,
  })
end

function M.whereused()
  if not adt.is_configured() then
    notify("No hay conexion SAP. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  local bufname  = vim.api.nvim_buf_get_name(0)
  local obj_name = vim.fn.fnamemodify(bufname, ":t:r"):upper()
  local ext      = vim.fn.fnamemodify(bufname, ":e"):lower()
  local cmd_fn   = CMDS[ext]

  if obj_name == "" or not cmd_fn then
    vim.ui.input({
      prompt = "Objeto ABAP para where-used: ",
      default = obj_name ~= "" and obj_name or "Z",
    }, function(name)
      if not name or name == "" then return end
      name = name:upper()
      local fn = CMDS["abap"]
      do_whereused(name, fn(name))
    end)
    return
  end

  do_whereused(obj_name, cmd_fn(obj_name))
end

function M.setup()
  vim.api.nvim_create_user_command("SapWhereUsed", function()
    M.whereused()
  end, { desc = "sap-nvim: Where-used list del objeto actual" })

  vim.keymap.set("n", "<leader>aw", M.whereused, { desc = "ABAP: Where-used list" })
end

return M
