-- sap-nvim.core.lsp
-- Real-time ABAP diagnostics via abaplint.
--
-- On BufEnter / BufWritePost → lint file on disk (fast, no temp copy).
-- On TextChanged / TextChangedI → debounce 600 ms, write temp file, lint
--   from buffer content so you see errors before saving.
--
-- Diagnostics land in Neovim's built-in diagnostic system, so they appear
-- inline (virtual text / signs / float) with whatever UI the user has set up.

local M = {}

local NS = vim.api.nvim_create_namespace("sap_nvim_abaplint")

-- Per-buffer debounce timers (uv handles)
local timers = {}

-- ─── JSON parser ────────────────────────────────────────────────────────────

local function parse_json(raw)
  if raw == "" then return {} end
  local ok, decoded = pcall(vim.json.decode, raw)
  if not ok or type(decoded) ~= "table" then return {} end

  local diags = {}
  for _, file_result in ipairs(decoded) do
    for _, issue in ipairs(file_result.issues or {}) do
      local s = (issue.severity or ""):lower()
      local sev = vim.diagnostic.severity.HINT
      if     s == "error"       then sev = vim.diagnostic.severity.ERROR
      elseif s == "warning"     then sev = vim.diagnostic.severity.WARN
      elseif s == "information" then sev = vim.diagnostic.severity.INFO
      end

      -- abaplint rows/cols are 1-indexed; Neovim wants 0-indexed
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
        message  = issue.message or "abaplint",
        source   = "abaplint",
        code     = issue.key,
      })
    end
  end
  return diags
end

-- ─── Runner ─────────────────────────────────────────────────────────────────

local function run_abaplint(bufnr, filepath, cleanup)
  local stdout, stderr = {}, {}

  vim.fn.jobstart({ "abaplint", "--format", "json", filepath }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(stdout, l) end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      if cleanup then pcall(os.remove, filepath) end

      local raw = table.concat(stdout, "")
      local diags = parse_json(raw)

      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(bufnr) then return end
        vim.diagnostic.set(NS, bufnr, diags)

        -- If abaplint itself errored (bad config, missing file), surface it once
        if code ~= 0 and #diags == 0 and #stderr > 0 then
          vim.notify("[sap-nvim] abaplint: " .. stderr[1], vim.log.levels.WARN)
        end
      end)
    end,
  })
end

local function lint_from_disk(bufnr)
  local path = vim.api.nvim_buf_get_name(bufnr)
  if path ~= "" then run_abaplint(bufnr, path, false) end
end

local function lint_from_buffer(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local tmp = vim.fn.tempname() .. ".abap"
  local f = io.open(tmp, "w")
  if not f then return end
  f:write(table.concat(lines, "\n"))
  f:close()
  run_abaplint(bufnr, tmp, true)
end

-- ─── Debounce ───────────────────────────────────────────────────────────────

local function schedule_lint(bufnr)
  local t = timers[bufnr]
  if t then
    t:stop()
    t:close()
    timers[bufnr] = nil
  end
  local new_t = vim.loop.new_timer()
  timers[bufnr] = new_t
  new_t:start(600, 0, vim.schedule_wrap(function()
    timers[bufnr] = nil
    if vim.api.nvim_buf_is_valid(bufnr) then
      lint_from_buffer(bufnr)
    end
  end))
end

-- ─── Setup ──────────────────────────────────────────────────────────────────

function M.setup(opts)
  opts = opts or {}

  if vim.fn.executable("abaplint") ~= 1 then
    -- Silent — not everyone has abaplint; other features still work
    return
  end

  local group = vim.api.nvim_create_augroup("sap_nvim_lsp", { clear = true })
  local pat   = { "*.abap", "*.cls", "*.intf", "*.prog" }

  -- First open: lint from disk immediately
  vim.api.nvim_create_autocmd("BufEnter", {
    pattern = pat, group = group,
    callback = function(ev) lint_from_disk(ev.buf) end,
  })

  -- After save: lint from disk (authoritative, no temp copy)
  vim.api.nvim_create_autocmd("BufWritePost", {
    pattern = pat, group = group,
    callback = function(ev) lint_from_disk(ev.buf) end,
  })

  -- While typing: debounced lint from buffer content
  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    pattern = pat, group = group,
    callback = function(ev) schedule_lint(ev.buf) end,
  })

  -- Clean up on buffer close
  vim.api.nvim_create_autocmd("BufDelete", {
    group = group,
    callback = function(ev)
      local t = timers[ev.buf]
      if t then t:stop(); t:close(); timers[ev.buf] = nil end
      vim.diagnostic.reset(NS, ev.buf)
    end,
  })
end

return M
