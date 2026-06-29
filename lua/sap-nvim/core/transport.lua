-- sap-nvim.core.transport
-- CTS transport cockpit: orders, tasks, included objects and safe actions.

local M = {}
local sapcli = require("sap-nvim.core.sapcli")
local adt = require("sap-nvim.core.adt")
local state_by_buf = {}
local HISTORY_LIMIT = 200

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function extract_id(line)
  return tostring(line or ""):match("[A-Z0-9]+K%d+") or tostring(line or ""):match("^(%S+)")
end

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function unxml(s)
  return (tostring(s or ""))
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&amp;", "&")
end

local function xmlesc(s)
  return (tostring(s or "")):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

local function xml_attr(attrs, name)
  if not attrs then return nil end
  return unxml(attrs:match('[%w_:]*' .. name .. '="([^"]*)"') or attrs:match(name .. '="([^"]*)"'))
end

local function productive()
  local ok, cfg = pcall(function()
    return require("sap-nvim.core.config").productive()
  end)
  return (ok and cfg) or {}
end

local function safe_mode()
  local cfg = productive()
  return cfg.safe_mode ~= false
end

local function history_path()
  return vim.fn.stdpath("state") .. "/sap-nvim/transport-history.json"
end

local function now_stamp()
  return os.date("!%Y-%m-%dT%H:%M:%SZ")
end

local function read_history()
  local path = history_path()
  local f = io.open(path, "r")
  if not f then return {} end
  local body = f:read("*a") or ""
  f:close()
  if body == "" then return {} end
  local ok, data = pcall(vim.json.decode, body)
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function write_history(entries)
  local path = history_path()
  vim.fn.mkdir(vim.fn.fnamemodify(path, ":h"), "p")
  local f = io.open(path, "w")
  if not f then return false end
  f:write(vim.json.encode(entries or {}))
  f:close()
  return true
end

local function record_history(action, transport_id, result, detail)
  local entries = read_history()
  entries[#entries + 1] = {
    at = now_stamp(),
    action = action,
    transport = transport_id,
    result = result or "ok",
    detail = detail,
  }
  while #entries > HISTORY_LIMIT do
    table.remove(entries, 1)
  end
  write_history(entries)
end

local function confirm_destructive(id, prompt, cb)
  local cfg = productive()
  if not cfg.confirm_destructive then
    return vim.ui.select({ "No", "Sí" }, { prompt = prompt }, function(choice)
      cb(choice and choice:match("^Sí") ~= nil)
    end)
  end
  vim.ui.input({ prompt = prompt .. " Escribe '" .. id .. "' para confirmar: " }, function(input)
    cb(input and vim.trim(input):upper() == id:upper())
  end)
end

local function transport_delete_allowed()
  return productive().allow_delete_transports == true
end

local function transport_reassign_allowed()
  return productive().allow_reassign_transports == true
end

local function ensure_ready()
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if ok_http and adt_http.ready() then
    return true
  end
  notify("Conexión SAP no validada. Usa :SapLogin.", vim.log.levels.WARN)
  return false
end

local function object_uri(pgmid, object, name)
  pgmid = trim(pgmid):upper()
  object = trim(object):upper()
  name = trim(name)
  if name == "" then return nil end
  local lname = name:lower()
  if pgmid == "LIMU" and object == "REPS" then
    return "/sap/bc/adt/programs/includes/" .. lname
  elseif object == "PROG" then
    return "/sap/bc/adt/programs/programs/" .. lname
  elseif object == "REPS" or object == "REPT" or object == "REPU" then
    return "/sap/bc/adt/programs/programs/" .. lname .. "/source/main"
  elseif object == "CLAS" then
    return "/sap/bc/adt/oo/classes/" .. lname
  elseif object == "INTF" then
    return "/sap/bc/adt/oo/interfaces/" .. lname
  elseif object == "FUGR" then
    return "/sap/bc/adt/functions/groups/" .. lname
  elseif object == "DDLS" then
    return "/sap/bc/adt/ddic/ddl/sources/" .. lname
  elseif object == "TABL" or object == "STRU" then
    return "/sap/bc/adt/ddic/tables/" .. lname
  elseif object == "DTEL" then
    return "/sap/bc/adt/ddic/dataelements/" .. lname
  elseif object == "DOMA" then
    return "/sap/bc/adt/ddic/domains/" .. lname
  end
  return nil
end

local function normalize_active_state(value)
  value = trim(value):lower()
  if value == "" then return nil end
  if value:find("inactive", 1, true) or value == "i" or value == "false" then return "inactive" end
  if value:find("active", 1, true) or value == "a" or value == "true" then return "active" end
  return nil
end

local function parse_active_state(line)
  local low = tostring(line or ""):lower()
  local value = line:match("[Aa]ctive[Ss]tate[%s:=]+([%w_%-]+)")
    or line:match("[Aa]ctivation[Ss]tate[%s:=]+([%w_%-]+)")
    or line:match("[Ss]tate[%s:=]+([%w_%-]+)")
    or line:match("[Ss]tatus[%s:=]+([%w_%-]+)")
  local normalized = normalize_active_state(value)
  if normalized then return normalized end
  if low:find("inactive", 1, true) or low:find("inactivo", 1, true) then return "inactive" end
  if low:find("active", 1, true) or low:find("activo", 1, true) then return "active" end
  return nil
end

local function parse_transport_line(line)
  line = trim(line)
  local id = extract_id(line)
  local rest = id and trim(line:gsub(id, "", 1)) or line
  local status = rest:match("%[([^%]]+)%]") or rest:match("[Ss]tatus[%s:=]+([%w_%-]+)")
  local owner = rest:match("[Oo]wner[%s:=]+([%w_%-]+)") or rest:match("[Uu]ser[%s:=]+([%w_%-]+)")
  local target = rest:match("[Tt]arget[%s:=]+([%w_%-]+)") or rest:match("[Ss]ystem[%s:=]+([%w_%-]+)")
  local desc = rest
    :gsub("%[[^%]]+%]", "")
    :gsub("[Oo]wner[%s:=]+[%w_%-]+", "")
    :gsub("[Uu]ser[%s:=]+[%w_%-]+", "")
    :gsub("[Tt]arget[%s:=]+[%w_%-]+", "")
    :gsub("[Ss]ystem[%s:=]+[%w_%-]+", "")
  return {
    id = id,
    raw = line,
    status = status,
    owner = owner,
    target = target,
    desc = trim(desc),
    tasks = {},
    objects = {},
    warnings = {},
    blocking = false,
  }
end

local function add_task(report, task)
  if not task or not task.id or task.id == "" or task.id == report.id then return end
  report._task_seen = report._task_seen or {}
  if report._task_seen[task.id] then return end
  report._task_seen[task.id] = true
  report.tasks[#report.tasks + 1] = task
end

local function add_object(report, obj)
  if not obj or trim(obj.name) == "" then return end
  obj.pgmid = trim(obj.pgmid):upper()
  obj.object = trim(obj.object):upper()
  obj.name = trim(obj.name):upper()
  obj.package = trim(obj.package):upper()
  obj.target = trim(obj.target):upper()
  obj.active_state = normalize_active_state(obj.active_state)
  obj.uri = obj.uri or object_uri(obj.pgmid, obj.object, obj.name)
  local key = table.concat({ obj.pgmid, obj.object, obj.name, obj.package, obj.target }, "|")
  report._obj_seen = report._obj_seen or {}
  if report._obj_seen[key] then return end
  report._obj_seen[key] = true
  report.objects[#report.objects + 1] = obj
end

local function parse_adt_tree(report, body)
  for attrs in body:gmatch("<[%w_:]*request%s+([^>]*)/?>") do
    local number = xml_attr(attrs, "number") or xml_attr(attrs, "trkorr") or xml_attr(attrs, "id")
    if number and number ~= "" then
      local req = {
        id = number,
        owner = xml_attr(attrs, "owner") or xml_attr(attrs, "as4user"),
        status = xml_attr(attrs, "status"),
        type = xml_attr(attrs, "type"),
        desc = xml_attr(attrs, "desc") or xml_attr(attrs, "description"),
        target = xml_attr(attrs, "target") or xml_attr(attrs, "system"),
      }
      if number == report.id then
        report.owner = report.owner or req.owner
        report.status = report.status or req.status
        report.desc = report.desc ~= "" and report.desc or (req.desc or "")
        report.target = report.target or req.target
      else
        add_task(report, req)
      end
    end
  end

  for attrs in body:gmatch("<[%w_:]*object%s+([^>]*)/?>") do
    local name = xml_attr(attrs, "name") or xml_attr(attrs, "objName") or xml_attr(attrs, "obj_name")
    local object = xml_attr(attrs, "type") or xml_attr(attrs, "object")
    local pgmid = xml_attr(attrs, "pgmid") or xml_attr(attrs, "pgmId") or "R3TR"
    if name and object then
      add_object(report, {
        pgmid = pgmid,
        object = object,
        name = name,
        package = xml_attr(attrs, "package") or xml_attr(attrs, "devclass"),
        target = xml_attr(attrs, "target") or xml_attr(attrs, "system"),
        active_state = xml_attr(attrs, "activeState") or xml_attr(attrs, "activationState")
          or xml_attr(attrs, "state") or xml_attr(attrs, "status"),
        uri = xml_attr(attrs, "uri") or xml_attr(attrs, "href"),
      })
    end
  end
end

local function parse_text_detail(report, lines)
  local pending
  for _, line in ipairs(lines or {}) do
    local t = trim(line)
    if t ~= "" then
      local low = t:lower()
      local found_id = t:match("[A-Z0-9]+K%d+")
      if found_id and found_id ~= report.id then
        add_task(report, {
          id = found_id,
          owner = t:match("[Oo]wner[%s:=]+([%w_%-]+)") or t:match("[Uu]ser[%s:=]+([%w_%-]+)"),
          status = t:match("%[([^%]]+)%]") or t:match("[Ss]tatus[%s:=]+([%w_%-]+)"),
          type = low:find("task", 1, true) and "task" or nil,
          desc = t,
        })
      end

      report.owner = report.owner or t:match("[Oo]wner[%s:=]+([%w_%-]+)") or t:match("AS4USER[%s:=]+([%w_%-]+)")
      report.status = report.status or t:match("[Ss]tatus[%s:=]+([%w_%-]+)")
      report.target = report.target or t:match("[Tt]arget[%s:=]+([%w_%-]+)") or t:match("[Ss]ystem[%s:=]+([%w_%-]+)")
      report.package = report.package or t:match("[Pp]ackage[%s:=]+([$%w_%-/]+)") or t:match("DEVCLASS[%s:=]+([$%w_%-/]+)")

      local pgmid, object, name = t:match("PGMID[%s:=]+(%u+).-[Oo][Bb][Jj][Ee][Cc][Tt][%s:=]+(%u+).-[Oo][Bb][Jj]_?[Nn][Aa][Mm][Ee][%s:=]+([%w_/$%-]+)")
      local package = t:match("DEVCLASS[%s:=]+([$%w_%-/]+)") or t:match("[Pp]ackage[%s:=]+([$%w_%-/]+)")
      local target = t:match("[Tt]arget[%s:=]+([%w_%-]+)") or t:match("[Ss]ystem[%s:=]+([%w_%-]+)")
      local active_state = parse_active_state(t)
      if not pgmid then
        pgmid, object, name = t:match("%f[%u](R3TR)%s+(%u+)%s+([%w_/$%-]+)")
      end
      if not pgmid then
        pgmid, object, name = t:match("%f[%u](LIMU)%s+(%u+)%s+([%w_/$%-]+)")
      end
      if pgmid and object and name and object ~= "TASK" and object ~= "TRKORR" then
        add_object(report, {
          pgmid = pgmid,
          object = object,
          name = name,
          package = package,
          target = target,
          active_state = active_state,
        })
        pending = report.objects[#report.objects]
      elseif pending then
        pending.package = pending.package ~= "" and pending.package or trim(package):upper()
        pending.target = pending.target ~= "" and pending.target or trim(target):upper()
        pending.active_state = pending.active_state or active_state
      end
    end
  end
end

function M._parse_transport_detail(id, lines)
  local report = parse_transport_line(id or "")
  report.id = id or report.id
  report.lines = vim.deepcopy(lines or {})
  local body = table.concat(lines or {}, "\n")
  if body:find("<", 1, true) and body:find("request", 1, true) then
    parse_adt_tree(report, body)
  end
  parse_text_detail(report, lines or {})
  return M._analyze_transport_report(report)
end

local function sorted_keys(set)
  local out = {}
  for k in pairs(set) do out[#out + 1] = k end
  table.sort(out)
  return out
end

function M._analyze_transport_report(report, opts)
  opts = opts or {}
  report = report or {}
  report.tasks = report.tasks or {}
  report.objects = report.objects or {}
  report.warnings = {}
  report.blocking = false
  local strict = opts.safe_mode
  if strict == nil then strict = safe_mode() end

  local packages, targets = {}, {}
  local inactive = {}
  for _, obj in ipairs(report.objects) do
    if obj.package and obj.package ~= "" then packages[obj.package] = true end
    if obj.target and obj.target ~= "" then targets[obj.target] = true end
    obj.active_state = normalize_active_state(obj.active_state)
    if obj.active_state == "inactive" then inactive[#inactive + 1] = obj end
  end
  if report.package and report.package ~= "" then packages[report.package] = true end
  if report.target and report.target ~= "" then targets[report.target] = true end
  for _, task in ipairs(report.tasks) do
    if task.target and task.target ~= "" then targets[task.target] = true end
  end

  local package_list = sorted_keys(packages)
  local target_list = sorted_keys(targets)
  report.packages = package_list
  report.targets = target_list
  report.inactive_objects = inactive

  local function warn(text, block)
    report.warnings[#report.warnings + 1] = { text = text, block = block == true }
    if block then report.blocking = true end
  end

  if report.detail_error and report.detail_error ~= "" then
    warn(report.detail_error, false)
  end
  if #report.objects == 0 then
    warn("sin objetos incluidos detectados; revisa el detalle antes de liberar", strict)
  end
  if #package_list > 1 then
    warn("mezcla paquetes: " .. table.concat(package_list, ", "), strict)
  end
  if #target_list > 1 then
    warn("mezcla sistemas/targets: " .. table.concat(target_list, ", "), strict)
  end
  if #target_list == 0 then
    warn("sin sistema destino detectado", false)
  end
  for _, target in ipairs(target_list) do
    if M._is_productive_target(target, opts) then
      warn("destino productivo detectado: " .. target, strict)
    end
  end
  if #inactive > 0 then
    local names = {}
    for _, obj in ipairs(inactive) do names[#names + 1] = (obj.object or "?") .. " " .. (obj.name or "?") end
    warn("objetos inactivos dentro: " .. table.concat(names, ", "), true)
  end
  for _, task in ipairs(report.tasks) do
    local task_status = trim(task.status):upper()
    if task_status ~= "" and not (task_status:find("REL", 1, true) or task_status == "R" or task_status == "RELEASED") then
      warn("tarea no liberada: " .. (task.id or "?") .. " estado=" .. task_status, strict)
    end
  end
  local status = trim(report.status):upper()
  if status ~= "" and (status:find("REL", 1, true) or status == "R" or status == "RELEASED") then
    warn("la orden parece liberada o no modificable (estado " .. status .. ")", true)
  end

  report.readiness = {
    ok = not report.blocking,
    safe_mode = strict == true,
    warning_count = #report.warnings,
    blocking_count = 0,
  }
  for _, warning in ipairs(report.warnings) do
    if warning.block then report.readiness.blocking_count = report.readiness.blocking_count + 1 end
  end

  return report
end

function M._is_productive_target(target, opts)
  target = trim(target):upper()
  if target == "" then return false end
  local configured = opts and opts.productive_targets
  if configured == nil then
    local cfg = productive()
    configured = cfg.productive_targets or cfg.production_targets or cfg.prod_targets
  end
  if type(configured) == "table" then
    for _, value in ipairs(configured) do
      if trim(value):upper() == target then return true end
    end
  end
  return target == "PRD" or target == "PROD" or target == "P01" or target == "PR1"
    or target:find("PRD", 1, true) ~= nil or target:find("PROD", 1, true) ~= nil
end

function M._readiness(report, opts)
  local analyzed = M._analyze_transport_report(vim.deepcopy(report or {}), opts)
  return analyzed.readiness, analyzed
end

local function object_key(obj)
  return table.concat({ obj.pgmid or "", obj.object or "", obj.name or "" }, " ")
end

function M._compare_transport_reports(left, right)
  left = M._analyze_transport_report(vim.deepcopy(left or {}), { safe_mode = false })
  right = M._analyze_transport_report(vim.deepcopy(right or {}), { safe_mode = false })
  local lset, rset = {}, {}
  for _, obj in ipairs(left.objects or {}) do lset[object_key(obj)] = obj end
  for _, obj in ipairs(right.objects or {}) do rset[object_key(obj)] = obj end
  local only_left, only_right, common, changed = {}, {}, {}, {}
  for key, obj in pairs(lset) do
    if rset[key] then
      common[#common + 1] = key
      if trim(obj.package):upper() ~= trim(rset[key].package):upper()
        or trim(obj.target):upper() ~= trim(rset[key].target):upper() then
        changed[#changed + 1] = {
          key = key,
          left_package = obj.package,
          right_package = rset[key].package,
          left_target = obj.target,
          right_target = rset[key].target,
        }
      end
    else
      only_left[#only_left + 1] = key
    end
  end
  for key in pairs(rset) do
    if not lset[key] then only_right[#only_right + 1] = key end
  end
  table.sort(only_left)
  table.sort(only_right)
  table.sort(common)
  table.sort(changed, function(a, b) return a.key < b.key end)
  return {
    left = left.id,
    right = right.id,
    only_left = only_left,
    only_right = only_right,
    common = common,
    changed = changed,
  }
end

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
local function show(bufname, lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, b, bufname)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
  return b
end

local function report_lines(report)
  report = M._analyze_transport_report(report or {})
  local lines = {}
  local readiness = report.blocking and "BLOQUEADO" or "READY"
  lines[#lines + 1] = string.format(
    "%s  %s  estado=%s  owner=%s  target=%s  paquetes=%s",
    report.id or "?",
    readiness,
    report.status or "?",
    report.owner or "?",
    report.target or (#(report.targets or {}) == 1 and report.targets[1] or "?"),
    #(report.packages or {}) > 0 and table.concat(report.packages, ",") or "?"
  )
  if report.desc and report.desc ~= "" then
    lines[#lines + 1] = "  " .. report.desc
  end
  if #report.warnings > 0 then
    for _, warning in ipairs(report.warnings) do
      lines[#lines + 1] = string.format("  %s %s", warning.block and "BLOQUEO:" or "WARN:", warning.text)
    end
  end
  lines[#lines + 1] = string.format("  Tareas (%d)", #(report.tasks or {}))
  for _, task in ipairs(report.tasks or {}) do
    lines[#lines + 1] = string.format(
      "    %s  estado=%s  owner=%s  %s",
      task.id or "?",
      task.status or "?",
      task.owner or "?",
      task.desc or task.type or ""
    )
  end
  lines[#lines + 1] = string.format("  Objetos (%d)", #(report.objects or {}))
  for _, obj in ipairs(report.objects or {}) do
    lines[#lines + 1] = string.format(
      "    %s %s %s  package=%s target=%s%s",
      obj.pgmid or "?",
      obj.object or "?",
      obj.name or "?",
      obj.package ~= "" and obj.package or "?",
      obj.target ~= "" and obj.target or "?",
      obj.active_state == "inactive" and " INACTIVO" or ""
    )
  end
  return lines
end

local function selected_report()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buf[bufnr]
  if not state then return nil end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = state.line_to_id[row]
  return id and state.reports[id] or nil
end

local function render_dashboard(bufnr)
  local state = state_by_buf[bufnr]
  if not state then return end
  local lines = {
    "SAP Transportes",
    "r refrescar | <CR> copiar | k readiness | l liberar | c detalle | x comparar | h historial | o owner | d borrar",
    "",
  }
  local line_to_id = {}
  for _, report in ipairs(state.order) do
    local start = #lines + 1
    for _, line in ipairs(report_lines(report)) do
      lines[#lines + 1] = line
    end
    for i = start, #lines do
      line_to_id[i] = report.id
    end
    lines[#lines + 1] = ""
  end
  state.line_to_id = line_to_id
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function open_dashboard(reports)
  local b = vim.api.nvim_create_buf(true, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].modifiable = false
  pcall(vim.api.nvim_buf_set_name, b, "sap-transports://orders")
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, 24)
  local by_id = {}
  for _, report in ipairs(reports or {}) do
    by_id[report.id] = report
  end
  state_by_buf[b] = { order = reports or {}, reports = by_id, line_to_id = {} }
  render_dashboard(b)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Transportes: cerrar" })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Transportes: cerrar" })
  vim.keymap.set("n", "r", M.list_transports, { buffer = b, desc = "Transportes: refrescar" })
  vim.keymap.set("n", "<CR>", function()
    local report = selected_report()
    if report and report.id then
      pcall(vim.fn.setreg, "+", report.id)
      notify("Orden " .. report.id .. " copiada al portapapeles.")
    end
  end, { buffer = b, desc = "Transportes: copiar orden" })
  vim.keymap.set("n", "c", function()
    local report = selected_report()
    if report and report.id then M.transport_contents(report.id) end
  end, { buffer = b, desc = "Transportes: detalle" })
  vim.keymap.set("n", "k", function()
    local report = selected_report()
    if report then M.show_readiness(report) end
  end, { buffer = b, desc = "Transportes: readiness" })
  vim.keymap.set("n", "l", function()
    local report = selected_report()
    if report and report.id then M.release_transport_id(report.id, { report = report }) end
  end, { buffer = b, desc = "Transportes: liberar con checks" })
  vim.keymap.set("n", "o", M.reassign_transport, { buffer = b, desc = "Transportes: reasignar owner" })
  vim.keymap.set("n", "d", M.delete_transport, { buffer = b, desc = "Transportes: borrar" })
  vim.keymap.set("n", "x", M.compare_transports, { buffer = b, desc = "Transportes: comparar" })
  vim.keymap.set("n", "h", M.show_history, { buffer = b, desc = "Transportes: historial" })
  return b
end

local function fetch_transport_detail(id, cb)
  local stdout, stderr = {}, {}
  sapcli.jobstart({ "sapcli", "cts", "list", "transport", id, "-r" }, {
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
      if code == 0 and #stdout > 0 then
        record_history("read", id, "ok", "detalle")
        cb(M._parse_transport_detail(id, stdout), nil)
      else
        record_history("read", id, "error", #stderr > 0 and stderr[1] or "sin detalle")
        cb(nil, #stderr > 0 and stderr[1] or ("No se pudo leer detalle de " .. id))
      end
    end,
  })
end

local function fetch_reports(cb)
  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    if not transports or #transports == 0 then
      cb(nil, err or "No hay órdenes de transporte abiertas.")
      return
    end

    local reports, idx = {}, 0
    local function next_one()
      idx = idx + 1
      local line = transports[idx]
      if not line then
        record_history("list", nil, "ok", tostring(#reports) .. " orden(es)")
        cb(reports, nil)
        return
      end
      local basic = parse_transport_line(line)
      if not basic.id then
        reports[#reports + 1] = M._analyze_transport_report(basic)
        next_one()
        return
      end
      fetch_transport_detail(basic.id, function(detail, detail_err)
        if detail then
          detail.raw = basic.raw
          detail.owner = detail.owner or basic.owner
          detail.status = detail.status or basic.status
          detail.target = detail.target or basic.target
          detail.desc = detail.desc ~= "" and detail.desc or basic.desc
          reports[#reports + 1] = M._analyze_transport_report(detail)
        else
          basic.detail_error = detail_err or "sin detalle"
          reports[#reports + 1] = M._analyze_transport_report(basic)
        end
        next_one()
      end)
    end
    next_one()
  end)
end

-- Show picker of open transport orders; <cr> copies the ID to the clipboard.
function M.list_transports()
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  fetch_reports(function(reports, err)
    vim.schedule(function()
      if not reports or #reports == 0 then
        record_history("list", nil, "empty", err or "sin órdenes")
        notify(err or "No hay órdenes de transporte abiertas.", vim.log.levels.WARN)
        return
      end
      open_dashboard(reports)
    end)
  end)
end

-- Create a new workbench transport order
function M.create_transport()
  local ok_cts, cts = pcall(require, "sap-nvim.core.cts")
  if ok_cts and cts.create_transport then
    cts.create_transport()
    return
  end
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({
    prompt = "Descripción de la orden de transporte: ",
  }, function(desc)
    if not desc or desc == "" then return end

    notify("Creando orden de transporte...")
    local stdout = {}
    local stderr = {}

    sapcli.jobstart({ "sapcli", "cts", "create", "transport", desc }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stdout, line) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stderr, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 and #stdout > 0 then
            local id = extract_id(stdout[1]) or stdout[1]
            vim.fn.setreg("+", id)
            notify("Orden creada: " .. id .. " (copiada al portapapeles)")
          else
            local msg = #stderr > 0 and stderr[1] or ("Error creando transporte (code " .. code .. ")")
            notify(msg, vim.log.levels.ERROR)
          end
        end)
      end,
    })
  end)
end

local function check_objects(report)
  local out = {}
  for _, obj in ipairs(report.objects or {}) do
    if obj.uri then
      out[#out + 1] = {
        name = obj.name,
        group = obj.object:lower(),
        uri = obj.uri:gsub("/source/main$", ""),
      }
    end
  end
  return out
end

local function run_release_checks(report, cb)
  local objects = check_objects(report)
  if #objects == 0 then
    cb({ ok = true, skipped = true, warnings = { "sin URI ADT de objetos; check ABAP omitido" }, qf = {} })
    return
  end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available() then
    cb({ ok = true, skipped = true, warnings = { "ADT checkrun no disponible; check ABAP omitido" }, qf = {} })
    return
  end

  local xml = {
    '<?xml version="1.0" encoding="UTF-8"?><chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" xmlns:adtcore="http://www.sap.com/adt/core">',
  }
  for _, obj in ipairs(objects) do
    xml[#xml + 1] = '<chkrun:checkObject adtcore:uri="' .. xmlesc(obj.uri) .. '" chkrun:version="active"></chkrun:checkObject>'
  end
  xml[#xml + 1] = "</chkrun:checkObjectList>"

  local body, _, code = adt_http.raw({
    method = "POST",
    path = "/sap/bc/adt/checkruns",
    query = { reporters = "abapCheckRun" },
    content_type = "application/vnd.sap.adt.checkobjects+xml",
    body = table.concat(xml, ""),
    accept = "application/xml",
  })
  if tonumber(code) == nil or code < 200 or code >= 300 then
    cb({ ok = false, hard_error = "checkrun falló (HTTP " .. tostring(code) .. ")", qf = {} })
    return
  end
  local qf = adt._parse_checkrun_response(body, objects, {})
  local errors, warnings = 0, 0
  for _, item in ipairs(qf) do
    if item.type == "W" or item.type == "I" then warnings = warnings + 1 else errors = errors + 1 end
  end
  cb({ ok = errors == 0, qf = qf, errors = errors, warnings_count = warnings })
end

local function release_after_checks(report)
  report = M._analyze_transport_report(report)
  if report.blocking then
    show("sap-transport-blocked://" .. (report.id or "?"), report_lines(report))
    record_history("release", report.id, "blocked", "readiness")
    notify("Liberación bloqueada por safe_mode. Revisa paquetes/sistemas/estado.", vim.log.levels.ERROR)
    return
  end

  notify("Ejecutando checks antes de liberar " .. report.id .. "...")
  run_release_checks(report, function(check)
    vim.schedule(function()
      if not check.ok then
        if check.qf and #check.qf > 0 then
          vim.fn.setqflist(check.qf, "r")
          vim.cmd("copen")
        end
        record_history("release", report.id, "blocked", check.hard_error or ("checks " .. tostring(check.errors or 0)))
        notify(check.hard_error or ("Checks con " .. tostring(check.errors or 0) .. " error(es). No se libera."), vim.log.levels.ERROR)
        return
      end
      local extra = ""
      if check.skipped then
        extra = " Checks omitidos: " .. table.concat(check.warnings or {}, "; ") .. "."
      elseif (check.warnings_count or 0) > 0 then
        extra = " Checks OK con " .. tostring(check.warnings_count) .. " warning(s)."
      end
      confirm_destructive(report.id, "Confirmar liberación irreversible de " .. report.id .. "." .. extra, function(confirm)
        if not confirm then return end

        notify("Liberando " .. report.id .. "...")
        record_history("release", report.id, "confirmed", "sapcli cts release")
        local stderr = {}
        sapcli.jobstart({ "sapcli", "cts", "release", report.id }, {
          stderr_buffered = true,
          on_stderr = function(_, data)
            for _, line in ipairs(data or {}) do
              if trim(line) ~= "" then stderr[#stderr + 1] = line end
            end
          end,
          on_exit = function(_, code)
            vim.schedule(function()
              if code == 0 then
                record_history("release", report.id, "ok", "liberada")
                notify("Orden liberada: " .. report.id)
              else
                record_history("release", report.id, "error", #stderr > 0 and stderr[1] or "sapcli error")
                notify(#stderr > 0 and stderr[1] or ("Error liberando " .. report.id), vim.log.levels.ERROR)
              end
            end)
          end,
        })
      end)
    end)
  end)
end

function M.release_transport_id(id, opts)
  opts = opts or {}
  id = trim(id):upper()
  if id == "" then return end
  if opts.report then
    release_after_checks(opts.report)
    return
  end
  fetch_transport_detail(id, function(report, err)
    vim.schedule(function()
      if not report then
        notify(err or ("No se pudo leer detalle de " .. id), vim.log.levels.ERROR)
        return
      end
      release_after_checks(report)
    end)
  end)
end

-- Release a transport order (shows picker first)
function M.release_transport(id)
  if id and trim(id) ~= "" then
    if not ensure_ready() then return end
    M.release_transport_id(id)
    return
  end
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  fetch_reports(function(reports, err)
    vim.schedule(function()
      if not reports or #reports == 0 then
        notify((err or "No hay órdenes abiertas para liberar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(reports, {
        prompt = "Seleccionar orden a LIBERAR con checks:",
        format_item = function(item)
          return string.format("%s  estado=%s owner=%s objetos=%d%s",
            item.id or "?",
            item.status or "?",
            item.owner or "?",
            #(item.objects or {}),
            item.blocking and "  BLOQUEADA" or "")
        end,
      }, function(choice)
        if choice and choice.id then release_after_checks(choice) end
      end)
    end)
  end)
end

-- Borrar una orden de transporte (muestra selector y confirma; §7 destructivo)
function M.delete_transport()
  local ok_cts, cts = pcall(require, "sap-nvim.core.cts")
  if ok_cts and cts.delete_transport then
    cts.delete_transport()
    return
  end
  if not transport_delete_allowed() then
    notify(
      "Borrado de transportes desactivado por seguridad. Para habilitarlo: productive.allow_delete_transports = true.",
      vim.log.levels.WARN
    )
    return
  end
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes abiertas para borrar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden a BORRAR (irreversible):",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if not id then return end

        confirm_destructive(id, "Confirmar borrado irreversible de " .. id .. ".", function(confirm)
          if not confirm then return end

          notify("Borrando " .. id .. "...")
          sapcli.jobstart({ "sapcli", "cts", "delete", "transport", id }, {
            on_exit = function(_, code)
              vim.schedule(function()
                if code == 0 then
                  notify("Orden borrada: " .. id)
                else
                  notify("Error borrando " .. id, vim.log.levels.ERROR)
                end
              end)
            end,
          })
        end)
      end)
    end)
  end)
end

-- Reasignar una orden de transporte a otro owner
function M.reassign_transport()
  if not transport_reassign_allowed() then
    notify(
      "Reasignación de transportes desactivada por seguridad. Para habilitarla: productive.allow_reassign_transports = true.",
      vim.log.levels.WARN
    )
    return
  end
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes abiertas para reasignar."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden a REASIGNAR:",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if not id then return end

        vim.ui.input({ prompt = "Nuevo owner para " .. id .. ": " }, function(owner)
          if not owner or vim.trim(owner) == "" then return end
          owner = vim.trim(owner)

          confirm_destructive(id, "Confirmar reasignación de " .. id .. " a " .. owner .. ".", function(confirm)
            if not confirm then return end

            notify("Reasignando " .. id .. " a " .. owner .. "...")
            sapcli.jobstart({ "sapcli", "cts", "reassign", "transport", id, owner }, {
              on_exit = function(_, code)
                vim.schedule(function()
                  if code == 0 then
                    notify("Orden " .. id .. " reasignada a " .. owner)
                  else
                    notify("Error reasignando " .. id, vim.log.levels.ERROR)
                  end
                end)
              end,
            })
          end)
        end)
      end)
    end)
  end)
end

-- Ver el CONTENIDO/detalle de una orden de transporte (objetos incluidos).
-- Muestra selector de órdenes y luego `sapcli cts list transport ID -r` (-r = detalle).
function M.transport_contents(id)
  if not ensure_ready() then return end
  if not adt.is_configured() then
    notify("No hay conexión SAP configurada.", vim.log.levels.WARN)
    return
  end

  local function show_contents(id)
    notify("Leyendo contenido de " .. id .. "...")
    local stdout, stderr = {}, {}
    sapcli.jobstart({ "sapcli", "cts", "list", "transport", id, "-r" }, {
      on_stdout = function(_, data)
        for _, line in ipairs(data) do
          if line ~= "" then table.insert(stdout, line) end
        end
      end,
      on_stderr = function(_, data)
        for _, line in ipairs(data) do
          if vim.trim(line) ~= "" then table.insert(stderr, line) end
        end
      end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 or #stdout == 0 then
            local msg = #stderr > 0 and stderr[1] or ("No se pudo leer el contenido de " .. id)
            notify(msg, vim.log.levels.WARN)
            return
          end
          record_history("read", id, "ok", "contenido")
          local lines = report_lines(M._parse_transport_detail(id, stdout))
          lines[#lines + 1] = ""
          lines[#lines + 1] = "Salida original"
          for _, line in ipairs(stdout) do lines[#lines + 1] = line end
          show("sap-transport://" .. id, lines)
        end)
      end,
    })
  end

  if id and trim(id) ~= "" then
    show_contents(trim(id):upper())
    return
  end

  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      if not transports or #transports == 0 then
        notify((err or "No hay órdenes de transporte abiertas."), vim.log.levels.WARN)
        return
      end

      vim.ui.select(transports, {
        prompt = "Seleccionar orden para ver su contenido:",
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local id = extract_id(choice)
        if id then show_contents(id) end
      end)
    end)
  end)
end

function M.show_readiness(report_or_id)
  if type(report_or_id) == "table" then
    local _, analyzed = M._readiness(report_or_id)
    record_history("readiness", analyzed.id, analyzed.blocking and "blocked" or "ok", "local")
    show("sap-transport-readiness://" .. (analyzed.id or "?"), report_lines(analyzed))
    return
  end
  local id = trim(report_or_id):upper()
  if id == "" then
    local report = selected_report()
    if report then M.show_readiness(report) end
    return
  end
  if not ensure_ready() then return end
  fetch_transport_detail(id, function(report, err)
    vim.schedule(function()
      if not report then
        record_history("readiness", id, "error", err or "sin detalle")
        notify(err or ("No se pudo calcular readiness de " .. id), vim.log.levels.ERROR)
        return
      end
      M.show_readiness(report)
    end)
  end)
end

local function compare_lines(diff)
  local lines = {
    string.format("Comparación %s <-> %s", diff.left or "?", diff.right or "?"),
    string.format("comunes=%d solo_izquierda=%d solo_derecha=%d cambios=%d",
      #(diff.common or {}), #(diff.only_left or {}), #(diff.only_right or {}), #(diff.changed or {})),
    "",
  }
  local function add_section(title, values)
    lines[#lines + 1] = title .. " (" .. tostring(#values) .. ")"
    for _, value in ipairs(values) do lines[#lines + 1] = "  " .. value end
    lines[#lines + 1] = ""
  end
  add_section("Solo " .. (diff.left or "izquierda"), diff.only_left or {})
  add_section("Solo " .. (diff.right or "derecha"), diff.only_right or {})
  lines[#lines + 1] = "Cambios package/target (" .. tostring(#(diff.changed or {})) .. ")"
  for _, change in ipairs(diff.changed or {}) do
    lines[#lines + 1] = string.format(
      "  %s  package %s -> %s  target %s -> %s",
      change.key,
      change.left_package or "?",
      change.right_package or "?",
      change.left_target or "?",
      change.right_target or "?"
    )
  end
  return lines
end

function M.compare_transports(args)
  args = trim(args or "")
  local ids = {}
  for id in args:gmatch("[A-Z0-9]+K%d+") do ids[#ids + 1] = id end

  local function run(left_id, right_id)
    fetch_transport_detail(left_id, function(left, lerr)
      if not left then
        vim.schedule(function() notify(lerr or ("No se pudo leer " .. left_id), vim.log.levels.ERROR) end)
        return
      end
      fetch_transport_detail(right_id, function(right, rerr)
        vim.schedule(function()
          if not right then
            notify(rerr or ("No se pudo leer " .. right_id), vim.log.levels.ERROR)
            return
          end
          local diff = M._compare_transport_reports(left, right)
          record_history("compare", left_id .. " " .. right_id, "ok", "objetos")
          show("sap-transport-compare://" .. left_id .. "-" .. right_id, compare_lines(diff))
        end)
      end)
    end)
  end

  if #ids >= 2 then
    if not ensure_ready() then return end
    run(ids[1], ids[2])
    return
  end

  if not ensure_ready() then return end
  fetch_reports(function(reports, err)
    vim.schedule(function()
      if not reports or #reports < 2 then
        notify(err or "Se necesitan al menos dos transportes para comparar.", vim.log.levels.WARN)
        return
      end
      vim.ui.select(reports, { prompt = "Transporte base:", format_item = function(item) return item.id end }, function(left)
        if not left then return end
        vim.ui.select(reports, { prompt = "Comparar contra:", format_item = function(item) return item.id end }, function(right)
          if right and right.id and right.id ~= left.id then run(left.id, right.id) end
        end)
      end)
    end)
  end)
end

function M.show_history()
  local entries = read_history()
  local lines = { "Historial local de transportes", "" }
  if #entries == 0 then
    lines[#lines + 1] = "Sin acciones registradas."
  else
    for i = #entries, 1, -1 do
      local e = entries[i]
      lines[#lines + 1] = string.format(
        "%s  %-9s %-10s %-12s %s",
        e.at or "?",
        e.action or "?",
        e.transport or "-",
        e.result or "?",
        e.detail or ""
      )
    end
  end
  show("sap-transport-history://local", lines)
end

function M.setup()
  vim.api.nvim_create_user_command("SapTransports", function()
    M.list_transports()
  end, { desc = "sap-nvim: Vista única de transportes" })

  vim.api.nvim_create_user_command("SapTransportCreate", function()
    M.create_transport()
  end, { desc = "sap-nvim: Crear orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportRelease", function(args)
    M.release_transport(args.args)
  end, { nargs = "?", desc = "sap-nvim: Liberar orden de transporte con checks" })

  vim.api.nvim_create_user_command("SapTransportDelete", function()
    M.delete_transport()
  end, { desc = "sap-nvim: Borrar orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportReassign", function()
    M.reassign_transport()
  end, { desc = "sap-nvim: Reasignar orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportContents", function(args)
    M.transport_contents(args.args)
  end, { nargs = "?", desc = "sap-nvim: Ver contenido de una orden de transporte" })

  vim.api.nvim_create_user_command("SapTransportReadiness", function(args)
    M.show_readiness(args.args)
  end, { nargs = "?", desc = "sap-nvim: Readiness de una orden antes de liberar" })

  vim.api.nvim_create_user_command("SapTransportCompare", function(args)
    M.compare_transports(args.args)
  end, { nargs = "*", desc = "sap-nvim: Comparar dos órdenes de transporte" })

  vim.api.nvim_create_user_command("SapTransportHistory", function()
    M.show_history()
  end, { desc = "sap-nvim: Historial local de transportes" })

  vim.keymap.set("n", "<leader>atl", M.list_transports,    { desc = "ABAP: Listar transportes" })
  vim.keymap.set("n", "<leader>atc", M.create_transport,   { desc = "ABAP: Crear transporte" })
  vim.keymap.set("n", "<leader>atr", M.release_transport,  { desc = "ABAP: Liberar transporte" })
  vim.keymap.set("n", "<leader>atd", M.delete_transport,   { desc = "ABAP: Borrar transporte" })
  vim.keymap.set("n", "<leader>ato", M.reassign_transport, { desc = "ABAP: Reasignar transporte (owner)" })
  vim.keymap.set("n", "<leader>att", M.transport_contents, { desc = "ABAP: Ver contenido de una orden" })
  vim.keymap.set("n", "<leader>atk", M.show_readiness,      { desc = "ABAP: Readiness de transporte" })
  vim.keymap.set("n", "<leader>atx", M.compare_transports,  { desc = "ABAP: Comparar transportes" })
  vim.keymap.set("n", "<leader>ath", M.show_history,        { desc = "ABAP: Historial de transportes" })
end

M._parse_transport_line = parse_transport_line
M._history_path = history_path
M._read_history = read_history
M._record_history = record_history
M._compare_lines = compare_lines
M._report_lines = report_lines

return M
