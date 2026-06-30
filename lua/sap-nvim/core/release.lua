-- sap-nvim.core.release
-- Read-only release assistant: professional checklist before CTS release.

local M = {}

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function transport_id(value)
  return trim(value):upper():match("[A-Z0-9]+K%d+")
end

local function status_released(status)
  status = trim(status):upper()
  return status ~= "" and (status == "R" or status == "REL" or status == "RELEASED" or status:find("REL", 1, true) ~= nil)
end

local function task_open(task)
  return not status_released(task and task.status)
end

local function list_value(values)
  if type(values) ~= "table" or #values == 0 then return "?" end
  return table.concat(values, ", ")
end

local function add_check(lines, severity, text)
  lines[#lines + 1] = string.format("  [%s] %s", severity, text)
end

local function severity_for_quality(summary)
  summary = summary or {}
  if (tonumber(summary.errors) or 0) > 0 then return "BLOCK" end
  if (tonumber(summary.warnings) or 0) > 0 then return "WARN" end
  if (tonumber(summary.total) or 0) > 0 then return "OK" end
  return "INFO"
end

local function summarize_qf(qf)
  local ok, quality = pcall(require, "sap-nvim.core.quality")
  if ok and quality._summarize_qf then
    return quality._summarize_qf(qf or {})
  end
  local s = { errors = 0, warnings = 0, info = 0, total = #(qf or {}) }
  for _, item in ipairs(qf or {}) do
    local typ = trim(item.type):upper()
    if typ == "W" then s.warnings = s.warnings + 1
    elseif typ == "I" then s.info = s.info + 1
    else s.errors = s.errors + 1 end
  end
  return s
end

local function latest_quality_history(id)
  local ok, quality = pcall(require, "sap-nvim.core.quality")
  if not ok or not quality._read_history then return nil end
  local entries = quality._read_history()
  id = trim(id):upper()
  for i = #entries, 1, -1 do
    local e = entries[i]
    if type(e) == "table" and (
      trim(e.target):upper() == id
      or (id == "" and trim(e.scope):lower() == "transport" and trim(e.target) ~= "")
    ) then
      return {
        source = "quality history",
        status = e.status,
        at = e.at,
        detail = e.detail,
        summary = {
          errors = tonumber(e.errors) or 0,
          warnings = tonumber(e.warnings) or 0,
          info = tonumber(e.info) or 0,
          total = type(e.findings) == "table" and #e.findings or ((tonumber(e.errors) or 0) + (tonumber(e.warnings) or 0)),
        },
      }
    end
  end
  return nil
end

local function current_quality_snapshot(id)
  local hist = latest_quality_history(id)
  if hist then return hist end

  local info = vim.fn.getqflist({ title = 0, items = 0 })
  local title = tostring(info.title or "")
  local items = info.items or {}
  if #items == 0 then return nil end
  if not title:lower():find("atc", 1, true) and not title:lower():find("quality", 1, true) then
    return nil
  end
  return {
    source = "quickfix: " .. (title ~= "" and title or "ATC"),
    summary = summarize_qf(items),
  }
end

local function consistency_snapshot(report)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready or not adt_http.ready() then
    return { available = false, detail = "ADT no validado" }
  end

  local ok_transport, transport = pcall(require, "sap-nvim.core.transport")
  if not ok_transport or not transport._consistency_paths or not transport._parse_transport_consistency_result then
    return { available = false, detail = "helpers de consistency no disponibles" }
  end

  local paths = transport._consistency_paths(report)
  if #paths == 0 then
    return { available = false, detail = "sin endpoint consistency ADT detectado" }
  end

  local attempts = {}
  for _, path in ipairs(paths) do
    local body, _, code = adt_http.raw({
      method = "GET",
      path = path,
      accept = "application/xml, application/vnd.sap.adt.transportorganizer.v1+xml, */*",
    })
    attempts[#attempts + 1] = { method = "GET", path = path, code = code }
    if tonumber(code) and code >= 200 and code < 300 then
      local result = transport._parse_transport_consistency_result(body, code, path, "GET")
      result.available = true
      result.attempts = attempts
      return result
    end
  end
  return { available = false, detail = "GET consistency ADT no disponible", attempts = attempts }
end

local function inferred_lock_lines(report)
  local lines = {}
  for _, lock in ipairs(report.locks or {}) do
    lines[#lines + 1] = string.format("%s owner=%s %s", lock.object or lock.id or "lock", lock.owner or lock.user or "?", lock.status or "")
  end
  for _, obj in ipairs(report.objects or {}) do
    local owner = obj.locked_by or obj.lock_owner or obj.enqueued_by
    if owner and owner ~= "" then
      lines[#lines + 1] = string.format("%s %s locked_by=%s", obj.object or "?", obj.name or "?", owner)
    end
  end
  return lines
end

function M._parse_transport_id(args)
  return transport_id(args)
end

function M._build_checklist(report, opts)
  opts = opts or {}
  local ok_transport, transport = pcall(require, "sap-nvim.core.transport")
  if ok_transport and transport._analyze_transport_report then
    report = transport._analyze_transport_report(vim.deepcopy(report or {}), opts.transport_opts or {})
  else
    report = report or {}
  end

  local id = report.id or opts.id or "?"
  local open_tasks = {}
  for _, task in ipairs(report.tasks or {}) do
    if task_open(task) then open_tasks[#open_tasks + 1] = task end
  end

  local inactive = report.inactive_objects or {}
  local quality = opts.quality
  local consistency = opts.consistency
  local locks = inferred_lock_lines(report)
  local readiness = report.blocking and "BLOCKED" or "READY"

  local lines = {
    "SAP Release Assistant",
    "Read-only checklist. No release, delete, reassign or task creation was executed.",
    "",
    "Order",
    "  TRKORR      : " .. tostring(id),
    "  Description : " .. (trim(report.desc) ~= "" and report.desc or "?"),
    "  Owner       : " .. (trim(report.owner) ~= "" and report.owner or "?"),
    "  Status      : " .. (trim(report.status) ~= "" and report.status or "?"),
    "  Target      : " .. (trim(report.target) ~= "" and report.target or list_value(report.targets)),
    "  Packages    : " .. list_value(report.packages),
    "  Readiness   : " .. readiness,
    "",
    "Release Order",
  }

  if #(report.tasks or {}) == 0 then
    lines[#lines + 1] = "  1. No tasks detected; verify in SE09/SE10 if this is unexpected."
  else
    for i, task in ipairs(report.tasks or {}) do
      lines[#lines + 1] = string.format(
        "  %d. Task %s owner=%s status=%s%s",
        i,
        task.id or "?",
        task.owner or "?",
        task.status or "?",
        task_open(task) and " (release before request)" or ""
      )
    end
  end
  lines[#lines + 1] = string.format("  %d. Request %s", #(report.tasks or {}) + 1, id)
  lines[#lines + 1] = ""

  lines[#lines + 1] = "Checklist"
  add_check(lines, id ~= "?" and "OK" or "BLOCK", "Technical order id is present")
  add_check(lines, trim(report.owner) ~= "" and "OK" or "WARN", "Owner: " .. (trim(report.owner) ~= "" and report.owner or "not detected"))
  add_check(lines, #open_tasks == 0 and "OK" or "BLOCK", string.format("Open tasks: %d/%d", #open_tasks, #(report.tasks or {})))
  add_check(lines, #(report.objects or {}) > 0 and "OK" or "WARN", string.format("Objects included: %d", #(report.objects or {})))
  add_check(lines, #inactive == 0 and "OK" or "BLOCK", string.format("Inactive objects: %d", #inactive))
  add_check(lines, #(report.targets or {}) == 1 and "OK" or "WARN", "Target: " .. (trim(report.target) ~= "" and report.target or list_value(report.targets)))
  if status_released(report.status) then
    add_check(lines, "BLOCK", "Status suggests the request is already released/not modifiable")
  else
    add_check(lines, "OK", "Status does not look released")
  end

  if quality and quality.summary then
    local s = quality.summary
    add_check(lines, severity_for_quality(s), string.format(
      "ATC/quality from %s: E:%d W:%d I:%d total:%d",
      quality.source or "available data",
      tonumber(s.errors) or 0,
      tonumber(s.warnings) or 0,
      tonumber(s.info) or 0,
      tonumber(s.total) or 0
    ))
  else
    add_check(lines, "INFO", "ATC/quality: no local data available; run :SapQuality atc transport " .. tostring(id))
  end

  if consistency and consistency.available then
    add_check(lines, consistency.ok and "OK" or "BLOCK", string.format(
      "ADT consistency %s HTTP %s E:%d W:%d",
      consistency.endpoint or "?",
      tostring(consistency.code or "?"),
      tonumber(consistency.errors) or 0,
      tonumber(consistency.warnings) or 0
    ))
  elseif consistency then
    add_check(lines, "INFO", "ADT consistency: " .. tostring(consistency.detail or "not available"))
  else
    add_check(lines, "INFO", "ADT consistency: not checked")
  end
  lines[#lines + 1] = ""

  if #open_tasks > 0 then
    lines[#lines + 1] = "Open Tasks"
    for _, task in ipairs(open_tasks) do
      lines[#lines + 1] = string.format("  %s owner=%s status=%s %s", task.id or "?", task.owner or "?", task.status or "?", task.desc or "")
    end
    lines[#lines + 1] = ""
  end

  if #(report.objects or {}) > 0 then
    lines[#lines + 1] = "Objects"
    for _, obj in ipairs(report.objects or {}) do
      lines[#lines + 1] = string.format(
        "  %s %s %s package=%s target=%s%s",
        obj.pgmid or "?",
        obj.object or "?",
        obj.name or "?",
        trim(obj.package) ~= "" and obj.package or "?",
        trim(obj.target) ~= "" and obj.target or "?",
        obj.active_state == "inactive" and " INACTIVE" or ""
      )
      if #lines > (opts.max_object_lines or 140) then
        lines[#lines + 1] = "  ... object list truncated ..."
        break
      end
    end
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "Locks / Status"
  if #locks > 0 then
    for _, line in ipairs(locks) do lines[#lines + 1] = "  " .. line end
  elseif #open_tasks > 0 then
    lines[#lines + 1] = "  No explicit lock data found; open tasks may still hold object locks."
  else
    lines[#lines + 1] = "  No explicit lock data found in available transport data."
  end
  lines[#lines + 1] = ""

  if consistency and consistency.messages and #consistency.messages > 0 then
    lines[#lines + 1] = "ADT Consistency Messages"
    for _, msg in ipairs(consistency.messages) do
      lines[#lines + 1] = string.format("  [%s] %s %s", msg.severity ~= "" and msg.severity or "?", msg.text ~= "" and msg.text or "(no text)", msg.object or "")
    end
    lines[#lines + 1] = ""
  end

  if quality and quality.detail and quality.detail ~= "" then
    lines[#lines + 1] = "Quality Detail"
    lines[#lines + 1] = "  " .. quality.detail:gsub("\n", "\n  ")
    lines[#lines + 1] = ""
  end

  lines[#lines + 1] = "Next"
  lines[#lines + 1] = "  Fix BLOCK items first. This assistant is informational; release stays in :SapTransportRelease."
  lines[#lines + 1] = "  q closes"
  return lines
end

local function show(bufname, lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].modifiable = false
  pcall(vim.api.nvim_buf_set_name, b, bufname)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, math.min(28, math.max(10, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Release assistant: close" })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Release assistant: close" })
  return b
end

function M.show_report(report, opts)
  opts = opts or {}
  opts.quality = opts.quality ~= nil and opts.quality or current_quality_snapshot(report and report.id)
  if opts.check_consistency ~= false and opts.consistency == nil then
    opts.consistency = consistency_snapshot(report or {})
  end
  return show("sap-release-assistant://" .. tostring((report and report.id) or "?"), M._build_checklist(report, opts))
end

function M.from_lines(id, lines, opts)
  local ok, transport = pcall(require, "sap-nvim.core.transport")
  if not ok or not transport._parse_transport_detail then
    notify("Modulo transport no disponible para parsear el detalle.", vim.log.levels.ERROR)
    return nil
  end
  return transport._parse_transport_detail(id, lines or {})
end

function M.open(args)
  local id = transport_id(args or "")
  if not id then
    vim.ui.input({ prompt = "Orden de transporte (TRKORR): " }, function(input)
      if input and trim(input) ~= "" then M.open(input) end
    end)
    return
  end

  notify("Leyendo checklist de release para " .. id .. " (solo lectura)...")
  local ok_transport, transport = pcall(require, "sap-nvim.core.transport")
  if ok_transport and transport.fetch_transport_report then
    transport.fetch_transport_report(id, function(report, err)
      vim.schedule(function()
        if not report then
          notify(err or ("No se pudo leer " .. id), vim.log.levels.ERROR)
          return
        end
        M.show_report(report)
      end)
    end)
    return
  end

  local sapcli = require("sap-nvim.core.sapcli")
  local stdout, stderr = {}, {}
  sapcli.jobstart({ "sapcli", "cts", "list", "transport", id, "-r", "-r" }, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if trim(line) ~= "" then stdout[#stdout + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if trim(line) ~= "" then stderr[#stderr + 1] = line end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #stdout == 0 then
          notify(#stderr > 0 and table.concat(stderr, "\n") or ("No se pudo leer " .. id), vim.log.levels.ERROR)
          return
        end
        local report = M.from_lines(id, stdout)
        if not report then return end
        M.show_report(report)
      end)
    end,
  })
end

function M.setup()
  vim.api.nvim_create_user_command("SapReleaseAssistant", function(args)
    M.open(args.args)
  end, { nargs = "?", desc = "sap-nvim: Checklist read-only antes de liberar una orden" })

  vim.keymap.set("n", "<leader>atR", function()
    M.open("")
  end, { desc = "ABAP: Release assistant (read-only)" })
end

M._current_quality_snapshot = current_quality_snapshot
M._consistency_snapshot = consistency_snapshot

return M
