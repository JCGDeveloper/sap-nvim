-- sap-nvim.core.lsp
-- Real-time ABAP diagnostics via abaplint.
--
-- Finds abaplint.json by walking up from cwd (project root detection).
-- On BufEnter / BufWritePost → lint the saved file (fast, no temp copy).
-- On TextChanged / TextChangedI → debounce 600 ms, write a temp file
--   in the project root so abaplint's glob picks it up, lint, then delete it.
--
-- Results land in vim.diagnostic so they show as virtual text, signs, and
-- hover floats with whatever diagnostic UI the user has configured.

local M = {}

local NS = vim.api.nvim_create_namespace("sap_nvim_abaplint")
local timers = {}

-- ─── Project root ────────────────────────────────────────────────────────────

-- Walk up from start_dir until we find abaplint.json.
-- Returns the directory that contains it, or nil.
local function find_project_root(start_dir)
  local dir = start_dir or vim.fn.getcwd()
  for _ = 1, 10 do
    if vim.fn.filereadable(dir .. "/abaplint.json") == 1 then
      return dir
    end
    local parent = vim.fn.fnamemodify(dir, ":h")
    if parent == dir then break end
    dir = parent
  end
  return nil
end

-- ─── JSON parser ─────────────────────────────────────────────────────────────

local function parse_json(raw, filter_file)
  if raw == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return {} end

  local diags = {}
  for _, issue in ipairs(decoded) do
    -- abaplint flat format: { file, description, key, start, end, severity }
    -- Skip issues from other files when linting the whole project
    if filter_file then
      local issue_file = issue.file or ""
      -- Match by basename in case paths differ
      local bn = vim.fn.fnamemodify(filter_file, ":t")
      if not issue_file:match(vim.pesc(bn)) then
        goto continue
      end
    end

    local s = (issue.severity or ""):lower()
    local sev = vim.diagnostic.severity.HINT
    if     s == "error"       then sev = vim.diagnostic.severity.ERROR
    elseif s == "warning"     then sev = vim.diagnostic.severity.WARN
    elseif s == "information" then sev = vim.diagnostic.severity.INFO
    end

    local row     = math.max(0, (issue.start and issue.start.row or 1) - 1)
    local col     = math.max(0, (issue.start and issue.start.col or 1) - 1)
    local end_row = issue["end"] and math.max(0, issue["end"].row - 1) or row
    local end_col = issue["end"] and math.max(0, issue["end"].col)     or col + 1

    table.insert(diags, {
      lnum     = row,
      col      = col,
      end_lnum = end_row,
      end_col  = end_col,
      severity = sev,
      message  = issue.description or "abaplint",
      source   = "abaplint",
      code     = issue.key,
    })

    ::continue::
  end
  return diags
end

-- ─── Runner ──────────────────────────────────────────────────────────────────

local function run_abaplint(bufnr, root, filter_file, cleanup_path)
  local stdout, stderr_lines = {}, {}

  vim.fn.jobstart(
    { "abaplint", "abaplint.json", "-f", "json" },
    {
      cwd = root,
      on_stdout = function(_, data)
        for _, l in ipairs(data) do
          if l ~= "" then table.insert(stdout, l) end
        end
      end,
      on_stderr = function(_, data)
        for _, l in ipairs(data) do
          if vim.trim(l) ~= "" then table.insert(stderr_lines, l) end
        end
      end,
      on_exit = function(_, _code)
        if cleanup_path then pcall(os.remove, cleanup_path) end

        -- abaplint exits non-zero when it finds issues — that's normal
        local raw = table.concat(stdout, "")
        -- Strip the version line if present ("abaplint X.Y.Z")
        raw = raw:gsub("^abaplint%s+[%d%.]+%s*", "")

        local diags = parse_json(raw, filter_file)

        vim.schedule(function()
          if vim.api.nvim_buf_is_valid(bufnr) then
            vim.diagnostic.set(NS, bufnr, diags)
          end
          -- Surface config/tooling errors (not lint issues)
          if #diags == 0 and #stderr_lines > 0 then
            local first = stderr_lines[1]
            if first:match("SyntaxError") or first:match("TypeError") then
              vim.notify("[sap-nvim] abaplint config error: " .. first, vim.log.levels.WARN)
            end
          end
        end)
      end,
    }
  )
end

-- ─── Lint strategies ─────────────────────────────────────────────────────────

local function lint_on_disk(bufnr)
  -- Objetos SAP remotos: usan el CHECK REAL de SAP (intel.check_syntax, contexto completo del
  -- sistema), no abaplint en aislado (que da falsos positivos "rojo por todos lados").
  if vim.b[bufnr] and vim.b[bufnr].sap_obj then
    vim.diagnostic.reset(NS, bufnr)
    return
  end
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path == "" then return end
  local root = find_project_root(vim.fn.fnamemodify(path, ":h"))
  if not root then return end
  run_abaplint(bufnr, root, path, nil)
end

-- abaplint uses the file extension to determine object type.
-- Plain .cls / .intf are "unknown" — map them to abapGit double extensions
-- (.clas.abap, .intf.abap) so abaplint can run full semantic checks.
local ABAPGIT_EXT = {
  cls  = "clas.abap",
  intf = "intf.abap",
  prog = "prog.abap",
  func = "func.abap",
  fugr = "fugr.abap",
  abap = "prog.abap",
}

local function lint_buffer_content(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  local root = find_project_root(path ~= "" and vim.fn.fnamemodify(path, ":h") or vim.fn.getcwd())
  if not root then return end

  local src_ext = vim.fn.fnamemodify(path, ":e"):lower()
  local lint_ext = ABAPGIT_EXT[src_ext] or "prog.abap"

  local tmp = root .. "/abaplint_lint_" .. bufnr .. "." .. lint_ext
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(table.concat(lines, "\n"))
  f:close()

  run_abaplint(bufnr, root, tmp, tmp)
end

-- ─── Debounce ────────────────────────────────────────────────────────────────

local function schedule_lint(bufnr)
  -- Objetos SAP remotos: no abaplint en aislado (ver lint_on_disk); el check de SAP es el bueno.
  if vim.b[bufnr] and vim.b[bufnr].sap_obj then
    return
  end
  local t = timers[bufnr]
  if t then t:stop(); t:close(); timers[bufnr] = nil end
  local new_t = vim.loop.new_timer()
  timers[bufnr] = new_t
  new_t:start(600, 0, vim.schedule_wrap(function()
    timers[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      lint_buffer_content(bufnr)
    end
  end))
end

-- ─── Setup ───────────────────────────────────────────────────────────────────

function M.setup()
  if vim.fn.executable("abaplint") ~= 1 then return end

  local group = vim.api.nvim_create_augroup("sap_nvim_lsp", { clear = true })
  local pat   = { "*.abap", "*.cls", "*.intf", "*.prog" }

  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = pat, group = group,
    callback = function(ev) lint_on_disk(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = pat, group = group,
    callback = function(ev) lint_on_disk(ev.buf) end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    pattern = pat, group = group,
    callback = function(ev) schedule_lint(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      local t = timers[ev.buf]
      if t then t:stop(); t:close(); timers[ev.buf] = nil end
      -- Clean up any leftover temp file (try all possible extensions)
      local root = find_project_root(vim.fn.getcwd())
      if root then
        for _, ext in ipairs({ "clas.abap", "intf.abap", "prog.abap", "func.abap", "fugr.abap" }) do
          pcall(os.remove, root .. "/abaplint_lint_" .. ev.buf .. "." .. ext)
        end
      end
      vim.diagnostic.reset(NS, ev.buf)
    end,
  })
end

return M
