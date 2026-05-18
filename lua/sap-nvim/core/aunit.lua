-- sap-nvim.core.aunit
-- Run ABAP Unit tests and load failures into the quickfix list.
-- Parses JUnit4 XML output from sapcli so you can jump to failing tests.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Minimal JUnit4 XML parser — no external deps.
-- Returns { { class, name, message, line } } for each failure/error.
local function parse_junit4(xml)
  local failures = {}

  -- Iterate over <testcase ...> blocks
  for block in xml:gmatch("<testcase(.-)/>") do
    -- Skipped (no failure child) — ignore
    _ = block
  end

  for block in xml:gmatch("<testcase(.-)>(.-)</testcase>") do
    local attrs  = block:match("^([^>]*)")  or ""
    local body   = block:match(">(.*)")     or block

    local classname = attrs:match('classname="([^"]*)"') or ""
    local testname  = attrs:match('name="([^"]*)"')      or ""

    -- <failure ...> or <error ...>
    local fail_msg = body:match('<failure[^>]*message="([^"]*)"')
                  or body:match('<error[^>]*message="([^"]*)"')
                  or body:match('<failure[^>]*>(.-)</failure>')
                  or body:match('<error[^>]*>(.-)</error>')

    if fail_msg then
      -- Try to extract line number from the failure body text
      local body_text = body:match('<failure[^>]*>(.-)</failure>')
                     or body:match('<error[^>]*>(.-)</error>')
                     or ""
      local lnum = body_text:match("[Ll]ine%s*(%d+)")
                or body_text:match("[Rr]ow%s*(%d+)")
                or body_text:match("%((%d+)%)")
      table.insert(failures, {
        class   = classname,
        name    = testname,
        message = vim.trim(fail_msg):gsub("\n", " "),
        line    = tonumber(lnum) or 1,
      })
    end
  end

  return failures
end

-- Find the local .cls file for a class name
local function find_local_cls(classname)
  local cwd  = vim.fn.getcwd()
  local name = classname:lower()
  for _, ext in ipairs({ "cls", "abap" }) do
    local path = cwd .. "/" .. name .. "." .. ext
    local f = io.open(path, "r")
    if f then f:close() return path end
  end
  return ""
end

-- Run AUnit for the current buffer's class and show results in quickfix.
function M.run_aunit()
  local bufname  = vim.api.nvim_buf_get_name(0)
  local obj_name = vim.fn.fnamemodify(bufname, ":t:r"):upper()
  local filename = bufname

  if obj_name == "" then
    notify("Guardá el archivo primero.", vim.log.levels.WARN)
    return
  end

  pcall(vim.cmd, "write")
  notify("Ejecutando AUnit para " .. obj_name .. "...")

  local xml_lines = {}
  local stderr    = {}

  vim.fn.jobstart({ "sapcli", "aunit", "run", "class", obj_name, "--output", "junit4" }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(xml_lines, l) end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        local xml = table.concat(xml_lines, "\n")

        -- Extract summary from XML attributes
        local total    = xml:match('tests="(%d+)"')    or "?"
        local failures = xml:match('failures="(%d+)"') or "0"
        local errors   = xml:match('errors="(%d+)"')   or "0"
        local skipped  = xml:match('skipped="(%d+)"')  or "0"

        local fail_list = parse_junit4(xml)

        if #fail_list == 0 then
          -- All green (or couldn't parse)
          local msg = code == 0
            and ("AUnit OK — " .. total .. " tests, " .. skipped .. " skipped")
            or  ("AUnit fallaron — ver stderr: " .. (stderr[1] or "sin detalles"))
          local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
          notify(msg, lvl)
          -- Clear stale quickfix
          vim.fn.setqflist({}, "r", { title = "AUnit OK: " .. obj_name })
          return
        end

        -- Build quickfix entries for each failure
        local qf = {}
        for _, f in ipairs(fail_list) do
          local path = find_local_cls(f.class) ~= "" and find_local_cls(f.class) or filename
          table.insert(qf, {
            filename = path,
            lnum     = f.line,
            col      = 1,
            text     = f.class .. "=>" .. f.name .. ": " .. f.message,
            type     = "E",
          })
        end

        vim.fn.setqflist({}, "r")
        vim.fn.setqflist(qf, "r")
        vim.fn.setqflist({}, "a", {
          title = string.format("AUnit %s — %s tests, %s fail, %s err, %s skip",
            obj_name, total, failures, errors, skipped),
        })
        vim.cmd("copen")
        vim.cmd("cfirst")
        notify(
          #fail_list .. " test(s) fallaron en " .. obj_name .. ". Ver quickfix.",
          vim.log.levels.ERROR
        )
      end)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("SapAUnit", function()
    M.run_aunit()
  end, { desc = "sap-nvim: Ejecutar AUnit y ver fallos en quickfix" })

  -- Override the basic keymap with the richer quickfix version
  vim.keymap.set("n", "<leader>aT", M.run_aunit, { desc = "ABAP: AUnit → quickfix" })
end

return M
