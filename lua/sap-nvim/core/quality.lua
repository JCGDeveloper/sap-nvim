-- sap-nvim.core.quality
-- Professional quality panel for ATC/AUnit with quickfix and local history.

local M = {}

local sapcli = require("sap-nvim.core.sapcli")
local objtype = require("sap-nvim.core.objtype")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function now()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function json_encode(v)
  if vim.json and vim.json.encode then return vim.json.encode(v) end
  return vim.fn.json_encode(v)
end

local function json_decode(s)
  if vim.json and vim.json.decode then return vim.json.decode(s) end
  return vim.fn.json_decode(s)
end

local function state_dir()
  return vim.fn.stdpath("state") .. "/sap-nvim"
end

local function history_path()
  return state_dir() .. "/quality-history.json"
end

local function read_history()
  local path = history_path()
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, data = pcall(json_decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function write_history(entries)
  pcall(vim.fn.mkdir, state_dir(), "p")
  pcall(vim.fn.writefile, vim.split(json_encode(entries), "\n", { plain = true }), history_path())
end

local function record_history(entry)
  local entries = read_history()
  entry.at = entry.at or now()
  entries[#entries + 1] = entry
  while #entries > 100 do table.remove(entries, 1) end
  write_history(entries)
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
  pcall(vim.api.nvim_win_set_height, 0, math.min(24, math.max(8, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Quality: cerrar" })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Quality: cerrar" })
  vim.keymap.set("n", "o", function() pcall(vim.cmd, "copen") end, { buffer = b, desc = "Quality: quickfix" })
  vim.keymap.set("n", "h", M.show_history, { buffer = b, desc = "Quality: historial" })
  return b
end

local function severity_type(sev)
  sev = tostring(sev or ""):upper()
  if sev:match("^W") or sev == "WARNING" then return "W" end
  if sev:match("^I") or sev == "INFO" or sev == "INFORMATION" then return "I" end
  return "E"
end

local function current_object()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local meta = vim.b[bufnr].sap_obj or {}
  local group = meta.group or objtype.group(filename)
  local name = meta.name or objtype.name(filename)
  name = tostring(name or ""):upper()
  if name == "" then return nil, "Guarda o abre un objeto SAP primero." end
  return {
    scope = "object",
    name = name,
    group = group,
    package = meta.package,
    uri = meta.uri,
    filename = filename,
    bufnr = bufnr,
  }
end

local function parse_scope(args, default_scope)
  args = trim(args)
  if args == "" then
    local obj, err = current_object()
    if default_scope == "package" and obj and obj.package and obj.package ~= "" then
      return { scope = "package", name = obj.package }
    end
    return obj, err
  end
  local scope, rest = args:match("^(%S+)%s+(.+)$")
  if scope and ({ object = true, obj = true, package = true, pkg = true, transport = true, tr = true })[scope:lower()] then
    scope = scope:lower()
    if scope == "obj" then scope = "object" end
    if scope == "pkg" then scope = "package" end
    if scope == "tr" then scope = "transport" end
    return { scope = scope, name = trim(rest):upper() }
  end
  if args:match("^[A-Z0-9]+K%d+$") then return { scope = "transport", name = args:upper() } end
  if args:match("^[$%w_/]+$") then return { scope = default_scope or "package", name = args:upper() } end
  return nil, "Scope no reconocido: " .. args
end

function M._parse_atc_output(lines, opts)
  opts = opts or {}
  local qf, context = {}, nil
  local filename = opts.filename or vim.api.nvim_buf_get_name(0)
  for _, raw in ipairs(lines or {}) do
    local line = trim(raw)
    if line ~= "" then
      local ctx = line:match("^%-%-%s+(.+)$") or line:match("^Object:%s*(.+)$")
      if ctx then
        context = trim(ctx)
      else
        local lnum, col, sev, msg =
          line:match("^[^:]+:(%d+):(%d+):%s*([EWIe wi][A-Za-z]*):%s*(.+)$")
        if not lnum then
          lnum, sev, msg = line:match("^[Ll]ine%s+(%d+):%s*([EWIe wi][A-Za-z]*):%s*(.+)$")
          col = 1
        end
        if not lnum then
          sev, msg = line:match("^%s*([EWIe wi]):%s*(.+)$")
          lnum, col = 0, 1
        end
        if msg then
          qf[#qf + 1] = {
            filename = filename,
            lnum = tonumber(lnum) or 0,
            col = tonumber(col) or 1,
            type = severity_type(sev),
            text = (context and (context .. ": ") or "") .. trim(msg),
          }
        elseif line:match("[Ee]rror") or line:match("[Ww]arning") or line:match("[Ii]nfo") then
          qf[#qf + 1] = { filename = filename, lnum = 0, col = 1, type = "E", text = line }
        end
      end
    end
  end
  return qf
end

function M._summarize_qf(qf)
  local s = { errors = 0, warnings = 0, info = 0, total = #(qf or {}) }
  for _, item in ipairs(qf or {}) do
    if item.type == "W" then s.warnings = s.warnings + 1
    elseif item.type == "I" then s.info = s.info + 1
    else s.errors = s.errors + 1 end
  end
  return s
end

local function set_qf(qf, title)
  vim.fn.setqflist({}, "r", { items = qf or {}, title = title })
  if #(qf or {}) > 0 then pcall(vim.cmd, "copen") end
end

local function panel_lines(run)
  local s = run.summary or M._summarize_qf(run.qf)
  local lines = {
    "SAP Quality",
    "",
    string.format("Run      : %s", run.kind or "?"),
    string.format("Scope    : %s %s", run.scope or "?", run.target or ""),
    string.format("Status   : %s", run.status or "?"),
    string.format("Problems : %d error(s), %d warning(s), %d info", s.errors or 0, s.warnings or 0, s.info or 0),
  }
  if run.command then lines[#lines + 1] = "Command  : " .. run.command end
  if run.helper then lines[#lines + 1] = "Helper   : " .. run.helper end
  if run.detail and run.detail ~= "" then lines[#lines + 1] = "Detail   : " .. run.detail end
  lines[#lines + 1] = ""
  if #(run.qf or {}) == 0 then
    lines[#lines + 1] = "Sin problemas parseados."
  else
    lines[#lines + 1] = "Problemas"
    for _, item in ipairs(run.qf or {}) do
      lines[#lines + 1] = string.format(
        "%s %s:%s  %s",
        item.type or "E",
        item.lnum or 0,
        item.col or 1,
        item.text or ""
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "o abre quickfix · h historial · q cierra"
  return lines
end

local function quality_config()
  local ok, cfg = pcall(require, "sap-nvim.core.config")
  if ok and cfg.quality then return cfg.quality() end
  return {}
end

local function helper_text(summary)
  local cfg = quality_config()
  if cfg.release_activate_helper == false then return nil end
  local errors = summary and summary.errors or 0
  local parts = {}
  if cfg.block_release_on_errors ~= false and errors > 0 then
    parts[#parts + 1] = "release blocked by quality helper"
  else
    parts[#parts + 1] = "release helper: report only"
  end
  if cfg.block_activate_on_errors == true and errors > 0 then
    parts[#parts + 1] = "activate blocked by quality helper"
  else
    parts[#parts + 1] = "activate helper: report only"
  end
  parts[#parts + 1] = "no transport/object was changed"
  return table.concat(parts, "; ")
end

local function finish_run(run)
  run.summary = run.summary or M._summarize_qf(run.qf)
  run.status = run.status or ((run.summary.errors or 0) == 0 and "ok" or "issues")
  run.helper = run.helper or helper_text(run.summary)
  set_qf(run.qf, "SAP Quality: " .. (run.kind or "?") .. " " .. (run.target or ""))
  record_history({
    kind = run.kind,
    scope = run.scope,
    target = run.target,
    status = run.status,
    errors = run.summary.errors,
    warnings = run.summary.warnings,
    info = run.summary.info,
    detail = run.detail,
    command = run.command,
  })
  show("sap-quality://" .. (run.kind or "run"), panel_lines(run))
  notify(string.format(
    "%s %s: %d error(s), %d warning(s)",
    run.kind or "Quality",
    run.status or "?",
    run.summary.errors or 0,
    run.summary.warnings or 0
  ), (run.summary.errors or 0) > 0 and vim.log.levels.WARN or vim.log.levels.INFO)
end

local function run_sapcli(args, on_done)
  local stdout, stderr = {}, {}
  sapcli.jobstart(args, {
    stdout_buffered = true,
    stderr_buffered = true,
    on_stdout = function(_, data)
      for _, l in ipairs(data or {}) do if l ~= "" then stdout[#stdout + 1] = l end end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data or {}) do if trim(l) ~= "" then stderr[#stderr + 1] = l end end
    end,
    on_exit = function(_, code)
      vim.schedule(function() on_done(code, stdout, stderr) end)
    end,
  })
end

local function atc_command(scope)
  if scope.scope == "object" then
    local typ = objtype.atc_type(scope.group)
    return { "sapcli", "atc", "run", typ, scope.name }
  end
  if scope.scope == "package" then
    return { "sapcli", "atc", "run", "package", scope.name }
  end
  return nil
end

function M.run_atc(args)
  local scope, err = parse_scope(args or "", "package")
  if not scope then return notify(err, vim.log.levels.WARN) end
  if scope.scope == "transport" then
    return M.run_transport_atc(scope.name)
  end
  local cmd = atc_command(scope)
  if not cmd then return notify("ATC no soportado para scope " .. tostring(scope.scope), vim.log.levels.WARN) end
  notify("Ejecutando ATC para " .. scope.scope .. " " .. scope.name .. "...")
  run_sapcli(cmd, function(code, stdout, stderr)
    local qf = M._parse_atc_output(stdout, { filename = scope.filename })
    local detail = #stderr > 0 and table.concat(stderr, "\n") or (code ~= 0 and "sapcli exit " .. tostring(code) or "")
    finish_run({
      kind = "ATC",
      scope = scope.scope,
      target = scope.name,
      qf = qf,
      detail = detail,
      command = table.concat(cmd, " "),
    })
  end)
end

function M.run_transport_atc(transport_id)
  transport_id = trim(transport_id):upper()
  if transport_id == "" then return notify("Indica una orden de transporte.", vim.log.levels.WARN) end
  local cmd = { "sapcli", "cts", "list", "transport", transport_id, "-r" }
  notify("Analizando transporte " .. transport_id .. " para quality...")
  run_sapcli(cmd, function(code, stdout, stderr)
    if code ~= 0 or #stdout == 0 then
      finish_run({
        kind = "ATC",
        scope = "transport",
        target = transport_id,
        qf = {},
        status = "blocked",
        command = table.concat(cmd, " "),
        detail = #stderr > 0 and table.concat(stderr, "\n") or "No se pudo leer el transporte.",
        helper = "No se liberó ni modificó el transporte.",
      })
      return
    end
    local ok, transport = pcall(require, "sap-nvim.core.transport")
    local report = ok and transport._parse_transport_detail and transport._parse_transport_detail(transport_id, stdout) or nil
    local packages, seen = {}, {}
    for _, obj in ipairs((report and report.objects) or {}) do
      local pkg = obj.package
      if pkg and pkg ~= "" and not seen[pkg] then seen[pkg] = true; packages[#packages + 1] = pkg end
    end
    if #packages == 0 then
      finish_run({
        kind = "ATC",
        scope = "transport",
        target = transport_id,
        qf = {},
        status = "blocked",
        command = table.concat(cmd, " "),
        detail = "No hay paquetes parseables en el transporte.",
        helper = "Ejecuta :SapTransportReadiness " .. transport_id .. " para el reporte de release.",
      })
      return
    end
    local all_qf, idx = {}, 0
    local function next_pkg()
      idx = idx + 1
      local pkg = packages[idx]
      if not pkg then
        finish_run({
          kind = "ATC",
          scope = "transport",
          target = transport_id,
          qf = all_qf,
          command = "sapcli atc run package <transport packages>",
        })
        return
      end
      local pcmd = { "sapcli", "atc", "run", "package", pkg }
      run_sapcli(pcmd, function(_, out)
        for _, item in ipairs(M._parse_atc_output(out, {})) do
          item.text = "[" .. pkg .. "] " .. item.text
          all_qf[#all_qf + 1] = item
        end
        next_pkg()
      end)
    end
    next_pkg()
  end)
end

function M.run_aunit(args)
  local scope, err = parse_scope(args or "", "object")
  if not scope then return notify(err, vim.log.levels.WARN) end
  if scope.scope ~= "object" then
    return finish_run({
      kind = "AUnit",
      scope = scope.scope,
      target = scope.name,
      status = "blocked",
      qf = {},
      detail = "AUnit por " .. scope.scope .. " no está expuesto por sapcli en este wrapper.",
      helper = "Usa :SapQuality object <CLASE> o :SapAUnitPanel desde una clase.",
    })
  end
  local cmd = { "sapcli", "aunit", "run", "class", scope.name, "--output", "junit4" }
  notify("Ejecutando AUnit para " .. scope.name .. "...")
  run_sapcli(cmd, function(code, stdout, stderr)
    local xml = table.concat(stdout, "\n")
    local failures = require("sap-nvim.core.aunit")._parse_junit4(xml)
    local qf = {}
    for _, f in ipairs(failures) do
      qf[#qf + 1] = {
        filename = scope.filename or vim.api.nvim_buf_get_name(0),
        lnum = f.line or 1,
        col = 1,
        type = "E",
        text = (f.class or scope.name) .. "=>" .. (f.name or "?") .. ": " .. (f.message or "AUnit failure"),
      }
    end
    local total = tonumber(xml:match('tests="(%d+)"')) or 0
    local skipped = tonumber(xml:match('skipped="(%d+)"')) or 0
    finish_run({
      kind = "AUnit",
      scope = "object",
      target = scope.name,
      qf = qf,
      detail = #stderr > 0 and table.concat(stderr, "\n") or (code ~= 0 and "sapcli exit " .. tostring(code) or ""),
      command = table.concat(cmd, " "),
      helper = string.format("JUnit4: %d test(s), %d skipped.", total, skipped),
    })
  end)
end

function M.run(args)
  args = trim(args or "")
  if args == "" then
    M.run_atc("")
    M.run_aunit("")
    return
  end
  local first, rest = args:match("^(%S+)%s*(.*)$")
  first = (first or ""):lower()
  if first == "atc" then return M.run_atc(rest) end
  if first == "aunit" or first == "unit" then return M.run_aunit(rest) end
  return M.run_atc(args)
end

function M.show_history()
  local entries = read_history()
  local lines = { "Historial local de calidad", "" }
  if #entries == 0 then
    lines[#lines + 1] = "Sin ejecuciones registradas."
  else
    for i = #entries, 1, -1 do
      local e = entries[i]
      lines[#lines + 1] = string.format(
        "%s  %-6s %-9s %-24s %-8s E:%s W:%s %s",
        e.at or "?",
        e.kind or "?",
        e.scope or "?",
        e.target or "-",
        e.status or "?",
        tostring(e.errors or 0),
        tostring(e.warnings or 0),
        e.detail or ""
      )
    end
  end
  show("sap-quality-history://local", lines)
end

function M.setup()
  vim.api.nvim_create_user_command("SapQuality", function(args) M.run(args.args) end,
    { nargs = "*", desc = "sap-nvim: Panel de calidad ATC/AUnit" })
  vim.api.nvim_create_user_command("SapAtcPanel", function(args) M.run_atc(args.args) end,
    { nargs = "*", desc = "sap-nvim: Panel ATC" })
  vim.api.nvim_create_user_command("SapAUnitPanel", function(args) M.run_aunit(args.args) end,
    { nargs = "*", desc = "sap-nvim: Panel AUnit" })
  vim.api.nvim_create_user_command("SapQualityHistory", M.show_history,
    { desc = "sap-nvim: Historial local de calidad" })

  vim.keymap.set("n", "<leader>aK", function() M.run_atc("") end, { desc = "ABAP: ATC panel" })
  vim.keymap.set("n", "<leader>aqp", function() M.run("") end, { desc = "ABAP: Quality panel" })
  vim.keymap.set("n", "<leader>aqh", M.show_history, { desc = "ABAP: Historial quality" })
end

M._history_path = history_path
M._read_history = read_history
M._record_history = record_history
M._parse_scope = parse_scope

return M
