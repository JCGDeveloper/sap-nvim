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

local function url_decode(s)
  return (tostring(s or ""):gsub("%%(%x%x)", function(hex)
    return string.char(tonumber(hex, 16))
  end))
end

local function adt_path(value)
  value = unxml(tostring(value or ""))
  if value == "" then return nil end
  value = value:gsub("^https?://[^/]+", "")
  value = value:gsub("[#?].*$", "")
  value = url_decode(value)
  if not value:match("^/") then return nil end
  return value
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

local CTS_GROUP = {
  PROG = "program",
  REPS = "include",
  REPT = "include",
  REPU = "include",
  CLAS = "class",
  INTF = "interface",
  FUGR = "functiongroup",
  DDLS = "ddls",
  DDLX = "ddlx",
  DCLS = "dcl",
  TABL = "table",
  STRU = "structure",
  DTEL = "dataelement",
  DOMA = "domain",
  TTYP = "tabletype",
  MSAG = "messageclass",
  TRAN = "transaction",
  SRVD = "srvd",
  BDEF = "bdef",
}

local function object_group(obj)
  obj = obj or {}
  local pgmid = trim(obj.pgmid):upper()
  local object = trim(obj.object):upper()
  if pgmid == "R3TR" and object == "PROG" then return "program" end
  if pgmid == "LIMU" and (object == "REPS" or object == "REPT" or object == "REPU") then return "include" end
  return CTS_GROUP[object]
end

local function is_cts_object_code(value)
  value = trim(value):upper()
  return value ~= "" and CTS_GROUP[value] ~= nil
end

local function object_source_uri(obj)
  obj = obj or {}
  local uri = obj.uri or object_uri(obj.pgmid, obj.object, obj.name)
  if not uri or uri == "" then return nil end
  uri = uri:gsub("%?.*$", ""):gsub("#.*$", "")
  if uri:match("/source/main$") then return uri end
  return uri:gsub("/$", "") .. "/source/main"
end

local function object_label(obj)
  local group = object_group(obj) or "?"
  return string.format(
    "%s %s %s  %-13s package=%s target=%s",
    obj.pgmid or "?",
    obj.object or "?",
    obj.name or "?",
    group,
    obj.package ~= "" and obj.package or "?",
    obj.target ~= "" and obj.target or "?"
  )
end

local function object_matches(obj, query)
  query = trim(query):upper()
  if query == "" then return true end
  local hay = table.concat({
    obj.pgmid or "",
    obj.object or "",
    obj.name or "",
    obj.package or "",
    obj.target or "",
    object_group(obj) or "",
  }, " "):upper()
  for token in query:gmatch("%S+") do
    if not hay:find(token, 1, true) then return false end
  end
  return true
end

local function filter_transport_objects(report, query)
  local out = {}
  for _, obj in ipairs((report and report.objects) or {}) do
    if object_matches(obj, query) then out[#out + 1] = obj end
  end
  table.sort(out, function(a, b)
    return table.concat({ a.object or "", a.name or "", a.package or "" }, "|")
      < table.concat({ b.object or "", b.name or "", b.package or "" }, "|")
  end)
  return out
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
  local desc
  if (not status or not owner) and rest ~= "" then
    local pos_status, pos_owner, pos_desc = rest:match("^(%S+)%s+(%S+)%s*(.*)$")
    if pos_status and pos_owner then
      status = status or pos_status
      owner = owner or pos_owner
      desc = pos_desc
    end
  end
  desc = desc or rest
      :gsub("%[[^%]]+%]", "")
      :gsub("[Ss]tatus[%s:=]+[%w_%-]+", "")
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

  for attrs in body:gmatch("<[%w_:]*task%s+([^>]*)/?>") do
    local number = xml_attr(attrs, "number") or xml_attr(attrs, "trkorr") or xml_attr(attrs, "id")
    if number and number ~= "" and number ~= report.id then
      add_task(report, {
        id = number,
        owner = xml_attr(attrs, "owner") or xml_attr(attrs, "as4user"),
        status = xml_attr(attrs, "status"),
        type = xml_attr(attrs, "type") or "task",
        desc = xml_attr(attrs, "desc") or xml_attr(attrs, "description"),
        target = xml_attr(attrs, "target") or xml_attr(attrs, "system"),
      })
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

  for attrs in body:gmatch("<[%w_:]*abap_object%s+([^>]*)/?>") do
    local name = xml_attr(attrs, "name") or xml_attr(attrs, "objName") or xml_attr(attrs, "obj_name")
    local object = xml_attr(attrs, "type") or xml_attr(attrs, "object")
    local pgmid = xml_attr(attrs, "pgmid") or xml_attr(attrs, "pgmId") or "R3TR"
    if name and object then
      add_object(report, {
        pgmid = pgmid,
        object = object,
        name = name,
        package = xml_attr(attrs, "package") or xml_attr(attrs, "devclass"),
        target = xml_attr(attrs, "target") or xml_attr(attrs, "system") or report.target,
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
      if found_id and found_id == report.id then
        local header = parse_transport_line(t)
        report.owner = report.owner or header.owner
        report.status = report.status or header.status
        report.target = report.target or header.target
        report.desc = report.desc ~= "" and report.desc or (header.desc or "")
      end
      if found_id and found_id ~= report.id then
        local rest = trim(t:gsub(found_id, "", 1))
        local pos_status, pos_owner, pos_desc = rest:match("^(%S+)%s+(%S+)%s*(.*)$")
        add_task(report, {
          id = found_id,
          owner = t:match("[Oo]wner[%s:=]+([%w_%-]+)") or t:match("[Uu]ser[%s:=]+([%w_%-]+)") or pos_owner,
          status = t:match("%[([^%]]+)%]") or t:match("[Ss]tatus[%s:=]+([%w_%-]+)") or pos_status,
          type = low:find("task", 1, true) and "task" or nil,
          desc = trim(pos_desc or t),
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
      if not pgmid then
        local object2, name2 = t:match("^(%u[%u%d][%u%d][%u%d]?)%s+([%w_/$%-]+)%s*$")
        if is_cts_object_code(object2) then
          pgmid, object, name = "R3TR", object2, name2
        end
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

local function parse_adt_links(body)
  local links = {}
  body = tostring(body or "")
  for attrs in body:gmatch("<[%w_:]*link%s+([^>]*)/?>") do
    local href = xml_attr(attrs, "href")
    if href and href ~= "" then
      links[#links + 1] = {
        href = href,
        path = adt_path(href),
        rel = xml_attr(attrs, "rel") or "",
        title = xml_attr(attrs, "title") or "",
        type = xml_attr(attrs, "type") or "",
      }
    end
  end
  return links
end

local function tag_name(raw)
  return tostring(raw or ""):match("^/?[%w_]+:?([%w_%-]+)") or tostring(raw or "")
end

local function parse_adt_messages(body)
  local messages = {}
  body = tostring(body or "")
  for raw_tag, attrs, text in body:gmatch("<([%w_:]*[Mm]essage)%s*([^>]*)>(.-)</%1>") do
    messages[#messages + 1] = {
      kind = tag_name(raw_tag),
      severity = xml_attr(attrs, "severity") or xml_attr(attrs, "type") or xml_attr(attrs, "priority")
        or xml_attr(attrs, "msgty") or xml_attr(attrs, "messageType") or "",
      text = trim(xml_attr(attrs, "shortText") or xml_attr(attrs, "text") or xml_attr(attrs, "description") or text),
      object = xml_attr(attrs, "object") or xml_attr(attrs, "uri") or "",
    }
  end
  for raw_tag, attrs in body:gmatch("<([%w_:]*[Mm]essage)%s+([^>]*)/>") do
    messages[#messages + 1] = {
      kind = tag_name(raw_tag),
      severity = xml_attr(attrs, "severity") or xml_attr(attrs, "type") or xml_attr(attrs, "priority")
        or xml_attr(attrs, "msgty") or xml_attr(attrs, "messageType") or "",
      text = trim(xml_attr(attrs, "shortText") or xml_attr(attrs, "text") or xml_attr(attrs, "description") or ""),
      object = xml_attr(attrs, "object") or xml_attr(attrs, "uri") or "",
    }
  end
  return messages
end

local function parse_transport_consistency_result(body, code, endpoint, method)
  local messages = parse_adt_messages(body)
  local errors, warnings = 0, 0
  for _, msg in ipairs(messages) do
    local sev = trim(msg.severity):upper()
    local text = trim(msg.text):lower()
    if sev == "E" or sev == "A" or sev == "ERROR" or text:find("error", 1, true) then
      errors = errors + 1
    elseif sev == "W" or sev == "WARNING" or text:find("warning", 1, true) then
      warnings = warnings + 1
    end
  end
  return {
    endpoint = endpoint,
    method = method or "GET",
    code = tonumber(code) or 0,
    ok = (tonumber(code) or 0) >= 200 and (tonumber(code) or 0) < 300 and errors == 0,
    errors = errors,
    warnings = warnings,
    messages = messages,
    raw = tostring(body or ""),
  }
end

local function consistency_lines(result, attempts)
  local lines = {
    "Consistency check ADT",
    string.format(
      "%s %s  HTTP %s  errores=%d warnings=%d",
      result and result.method or "?",
      result and result.endpoint or "?",
      tostring(result and result.code or 0),
      result and result.errors or 0,
      result and result.warnings or 0
    ),
    result and result.ok and "Resultado: OK para el endpoint ADT consultado." or "Resultado: revisar mensajes/HTTP; no se liberó nada.",
    "",
  }
  if result and #(result.messages or {}) > 0 then
    lines[#lines + 1] = "Mensajes"
    for _, msg in ipairs(result.messages) do
      lines[#lines + 1] = string.format("  [%s] %s %s", msg.severity ~= "" and msg.severity or "?", msg.text ~= "" and msg.text or "(sin texto)", msg.object or "")
    end
    lines[#lines + 1] = ""
  end
  if attempts and #attempts > 0 then
    lines[#lines + 1] = "Intentos"
    for _, attempt in ipairs(attempts) do
      lines[#lines + 1] = string.format("  %s %s -> HTTP %s", attempt.method or "GET", attempt.path or "?", tostring(attempt.code or 0))
    end
    lines[#lines + 1] = ""
  end
  if result and result.raw ~= "" then
    lines[#lines + 1] = "Respuesta ADT"
    for _, line in ipairs(vim.split(result.raw:gsub("\r", ""), "\n", { plain = true })) do
      if trim(line) ~= "" then lines[#lines + 1] = line end
      if #lines > 160 then
        lines[#lines + 1] = "... respuesta truncada ..."
        break
      end
    end
  end
  return lines
end

local function parse_release_jobs(body, code, endpoint)
  local jobs = {}
  body = tostring(body or "")
  for raw_tag, attrs in body:gmatch("<([%w_:]*release[%w_%-]*)%s+([^>]*)/?>") do
    if tag_name(raw_tag):lower():find("job", 1, true) then
      jobs[#jobs + 1] = {
        id = xml_attr(attrs, "id") or xml_attr(attrs, "jobId") or xml_attr(attrs, "name") or "",
        status = xml_attr(attrs, "status") or xml_attr(attrs, "state") or "",
        user = xml_attr(attrs, "user") or xml_attr(attrs, "owner") or xml_attr(attrs, "createdBy") or "",
        text = xml_attr(attrs, "text") or xml_attr(attrs, "description") or xml_attr(attrs, "shortText") or "",
        path = adt_path(xml_attr(attrs, "href") or xml_attr(attrs, "uri") or ""),
      }
    end
  end
  return {
    endpoint = endpoint,
    code = tonumber(code) or 0,
    ok = (tonumber(code) or 0) >= 200 and (tonumber(code) or 0) < 300,
    jobs = jobs,
    messages = parse_adt_messages(body),
    raw = body,
  }
end

local function release_job_lines(results)
  local lines = { "Release jobs ADT", "Consulta de estado; no ejecuta release ni crea jobs.", "" }
  for _, result in ipairs(results or {}) do
    lines[#lines + 1] = string.format("%s  HTTP %s  jobs=%d", result.endpoint or "?", tostring(result.code or 0), #(result.jobs or {}))
    for _, job in ipairs(result.jobs or {}) do
      lines[#lines + 1] = string.format(
        "  %s  estado=%s  user=%s  %s",
        job.id ~= "" and job.id or "?",
        job.status ~= "" and job.status or "?",
        job.user ~= "" and job.user or "?",
        job.text or ""
      )
    end
    for _, msg in ipairs(result.messages or {}) do
      lines[#lines + 1] = string.format("  mensaje [%s] %s", msg.severity ~= "" and msg.severity or "?", msg.text ~= "" and msg.text or "(sin texto)")
    end
    if result.raw ~= "" and #(result.jobs or {}) == 0 and #(result.messages or {}) == 0 then
      lines[#lines + 1] = "  Respuesta sin jobs parseables; se incluye XML bruto abajo."
    end
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Respuesta ADT"
  for _, result in ipairs(results or {}) do
    if result.raw ~= "" then
      lines[#lines + 1] = "--- " .. (result.endpoint or "?") .. " ---"
      for _, line in ipairs(vim.split(result.raw:gsub("\r", ""), "\n", { plain = true })) do
        if trim(line) ~= "" then lines[#lines + 1] = line end
        if #lines > 180 then
          lines[#lines + 1] = "... respuesta truncada ..."
          return lines
        end
      end
    end
  end
  return lines
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
    trim(report.target) ~= "" and report.target or (#(report.targets or {}) == 1 and report.targets[1] or "?"),
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

local fetch_transport_detail
local fetch_reports

local function selected_report()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buf[bufnr]
  if not state then return nil end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  local id = state.line_to_id[row]
  return id and state.reports[id] or nil
end

local function selected_object()
  local bufnr = vim.api.nvim_get_current_buf()
  local state = state_by_buf[bufnr]
  if not state or not state.line_to_object then return nil end
  local row = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_to_object[row]
end

local function with_transport_report(id, cb)
  id = trim(id):upper()
  if id == "" then
    local report = selected_report()
    if report then return cb(report) end
    notify("Indica una orden de transporte.", vim.log.levels.WARN)
    return
  end
  if not ensure_ready() then return end
  fetch_transport_detail(id, function(report, err)
    vim.schedule(function()
      if not report then
        notify(err or ("No se pudo leer detalle de " .. id), vim.log.levels.ERROR)
        return
      end
      cb(report)
    end)
  end)
end

local function parse_order_args(args)
  args = trim(args or "")
  local id = args:upper():match("[A-Z0-9]+K%d+")
  local query = args
  if id then
    query = trim(query:gsub("[A-Za-z0-9]+[Kk]%d+", "", 1))
  end
  return id, query
end

local function unique_paths(paths)
  local out, seen = {}, {}
  for _, path in ipairs(paths or {}) do
    path = adt_path(path) or path
    if path and path ~= "" and not seen[path] then
      seen[path] = true
      out[#out + 1] = path
    end
  end
  return out
end

local function report_xml_body(report)
  return table.concat((report and report.lines) or {}, "\n")
end

local function transport_link_paths(report, tokens)
  local paths = {}
  local body = report_xml_body(report)
  for _, link in ipairs(parse_adt_links(body)) do
    local hay = table.concat({ link.href or "", link.path or "", link.rel or "", link.title or "", link.type or "" }, " "):lower()
    for _, token in ipairs(tokens or {}) do
      if hay:find(token, 1, true) then
        paths[#paths + 1] = link.path or adt_path(link.href)
        break
      end
    end
  end
  return unique_paths(paths)
end

local function consistency_paths(report)
  local id = trim((report and report.id) or ""):upper()
  local paths = transport_link_paths(report, { "consistencycheck", "consistency-check", "readiness" })
  if id ~= "" then
    paths[#paths + 1] = "/sap/bc/adt/cts/transportrequests/" .. id .. "/consistencychecks"
  end
  return unique_paths(paths)
end

local function release_job_paths(report)
  local id = trim((report and report.id) or ""):upper()
  local paths = transport_link_paths(report, { "releasejob", "release-job", "newreleasejob", "new-release-job" })
  if id ~= "" then
    paths[#paths + 1] = "/sap/bc/adt/cts/transportrequests/" .. id .. "/releasejobs"
    paths[#paths + 1] = "/sap/bc/adt/cts/transportrequests/" .. id .. "/newreleasejobs"
  end
  return unique_paths(paths)
end

local function run_remote_consistency(report, cb)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready() then
    cb(nil, "ADT no validado")
    return
  end
  local attempts = {}
  for _, path in ipairs(consistency_paths(report)) do
    local body, _, code = adt_http.raw({
      method = "GET",
      path = path,
      accept = "application/xml, application/vnd.sap.adt.transportorganizer.v1+xml, */*",
    })
    attempts[#attempts + 1] = { method = "GET", path = path, code = code }
    if tonumber(code) and code >= 200 and code < 300 then
      cb(parse_transport_consistency_result(body, code, path, "GET"), nil, attempts)
      return
    end
    if code == 405 or code == 501 then
      local post_body, _, post_code = adt_http.raw({
        method = "POST",
        path = path,
        content_type = "application/xml",
        body = "",
        accept = "application/xml, application/vnd.sap.adt.transportorganizer.v1+xml, */*",
      })
      attempts[#attempts + 1] = { method = "POST", path = path, code = post_code }
      if tonumber(post_code) and post_code >= 200 and post_code < 300 then
        cb(parse_transport_consistency_result(post_body, post_code, path, "POST"), nil, attempts)
        return
      end
    end
  end
  cb(nil, "endpoint consistencychecks no disponible", attempts)
end

local function run_release_jobs(report, cb)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready() then
    cb(nil, "ADT no validado")
    return
  end
  local results = {}
  for _, path in ipairs(release_job_paths(report)) do
    local body, _, code = adt_http.raw({
      method = "GET",
      path = path,
      accept = "application/xml, application/vnd.sap.adt.transportorganizer.v1+xml, */*",
    })
    results[#results + 1] = parse_release_jobs(body, code, path)
  end
  cb(results, nil)
end

local function open_object_in_editor(obj)
  local group = object_group(obj)
  if not group then
    notify("Tipo CTS no soportado para abrir: " .. tostring(obj.object), vim.log.levels.WARN)
    return false
  end
  local ok, source = pcall(require, "sap-nvim.core.source")
  if not ok or not source.open then
    notify("Módulo source no disponible para abrir objetos.", vim.log.levels.ERROR)
    return false
  end
  source.open(obj.name, group, { uri = obj.uri, package = obj.package })
  return true
end

local function open_object_in_gui(obj)
  local uri = obj.uri or object_uri(obj.pgmid, obj.object, obj.name)
  if not uri or uri == "" then
    notify("No hay URI ADT para abrir " .. tostring(obj.name) .. " en SAP GUI.", vim.log.levels.WARN)
    return false
  end
  local ok, sapgui = pcall(require, "sap-nvim.core.sapgui")
  if not ok or not sapgui.open then
    notify("SAP GUI no disponible; abriendo en editor.", vim.log.levels.WARN)
    return open_object_in_editor(obj)
  end
  sapgui.open({
    type = "Transaction",
    command = "*SADT_START_WB_URI",
    params = { { "D_OBJECT_URI", uri:gsub("/source/main$", "") } },
    okcode = "OKAY",
  }, { desktop = true })
  return true
end

local function buffer_matches_object(bufnr, obj)
  local meta = vim.b[bufnr].sap_obj
  if not meta then return false end
  return trim(meta.name):upper() == trim(obj.name):upper()
    and trim(meta.group):lower() == trim(object_group(obj)):lower()
end

local function local_object_lines(obj)
  local cur = vim.api.nvim_get_current_buf()
  if buffer_matches_object(cur, obj) then
    return vim.api.nvim_buf_get_lines(cur, 0, -1, false), "buffer local"
  end
  for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_loaded(bufnr) and buffer_matches_object(bufnr, obj) then
      return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "buffer local"
    end
  end
  return nil
end

local function read_object_source(obj, version)
  local uri = object_source_uri(obj)
  if not uri then return nil, "sin URI de código fuente" end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready() then return nil, "conexión ADT no validada" end
  local body, _, code = adt_http.raw({
    method = "GET",
    path = uri,
    query = version and { version = version } or nil,
    accept = "text/plain",
  })
  if not body or tonumber(code) == nil or code < 200 or code >= 300 then
    return nil, "HTTP " .. tostring(code or 0)
  end
  return vim.split((body or ""):gsub("\r", ""), "\n", { plain = true }), nil, uri
end

local function open_source_diff(obj, left_title, left_lines, right_title, right_lines)
  local left_buf = vim.api.nvim_create_buf(false, true)
  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_lines or {})
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_lines or {})
  for _, b in ipairs({ left_buf, right_buf }) do
    vim.bo[b].filetype = "abap"
    vim.bo[b].readonly = true
    vim.bo[b].modifiable = false
    vim.bo[b].bufhidden = "wipe"
  end
  pcall(vim.api.nvim_buf_set_name, left_buf, (obj.name or "SAP") .. " [" .. left_title .. "]")
  pcall(vim.api.nvim_buf_set_name, right_buf, (obj.name or "SAP") .. " [" .. right_title .. "]")

  vim.cmd("vsplit")
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)
  vim.api.nvim_win_call(left_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(right_win, function() vim.cmd("diffthis") end)

  local function close_diff()
    pcall(vim.api.nvim_win_call, left_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_win_call, right_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
    pcall(vim.api.nvim_buf_delete, right_buf, { force = true })
  end
  vim.keymap.set("n", "q", close_diff, { buffer = left_buf, nowait = true, desc = "Cerrar diff transporte" })
  vim.keymap.set("n", "q", close_diff, { buffer = right_buf, nowait = true, desc = "Cerrar diff transporte" })
  notify("Diff de " .. (obj.name or "?") .. ": ]c / [c navega diferencias, q cierra.")
end

local function object_list_lines(report, query)
  local objects = filter_transport_objects(report, query)
  local lines = {
    "Objetos de transporte " .. tostring(report.id or "?"),
    "f filtrar | <CR> abrir | d diff transporte/activo-local | g SAP GUI | y copiar | q cerrar",
    string.format("Filtro: %s  Objetos: %d/%d", trim(query) ~= "" and query or "(sin filtro)", #objects, #((report and report.objects) or {})),
    "",
  }
  local line_to_object = {}
  for _, obj in ipairs(objects) do
    local row = #lines + 1
    lines[row] = object_label(obj)
    line_to_object[row] = obj
  end
  if #objects == 0 then
    lines[#lines + 1] = "Sin objetos para ese filtro."
  end
  return lines, line_to_object
end

local function render_object_list(bufnr)
  local state = state_by_buf[bufnr]
  if not state then return end
  local lines, line_to_object = object_list_lines(state.report, state.query)
  state.line_to_object = line_to_object
  vim.bo[bufnr].modifiable = true
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.bo[bufnr].modifiable = false
end

local function open_object_list(report, query)
  local b = vim.api.nvim_create_buf(true, true)
  vim.bo[b].buftype = "nofile"
  vim.bo[b].bufhidden = "wipe"
  vim.bo[b].modifiable = false
  pcall(vim.api.nvim_buf_set_name, b, "sap-transport-objects://" .. tostring(report.id or "?"))
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, 20)
  state_by_buf[b] = { report = report, query = query or "", line_to_object = {} }
  render_object_list(b)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Objetos transporte: cerrar" })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true, desc = "Objetos transporte: cerrar" })
  vim.keymap.set("n", "<CR>", function()
    local obj = selected_object()
    if obj then open_object_in_editor(obj) end
  end, { buffer = b, desc = "Objetos transporte: abrir" })
  vim.keymap.set("n", "g", function()
    local obj = selected_object()
    if obj then open_object_in_gui(obj) end
  end, { buffer = b, desc = "Objetos transporte: SAP GUI" })
  vim.keymap.set("n", "d", function()
    local obj = selected_object()
    if obj then M.diff_transport_object(obj) end
  end, { buffer = b, desc = "Objetos transporte: diff" })
  vim.keymap.set("n", "y", function()
    local obj = selected_object()
    if obj then
      local text = table.concat({ obj.pgmid or "", obj.object or "", obj.name or "" }, " ")
      pcall(vim.fn.setreg, "+", text)
      notify("Objeto copiado: " .. text)
    end
  end, { buffer = b, desc = "Objetos transporte: copiar" })
  vim.keymap.set("n", "f", function()
    vim.ui.input({ prompt = "Filtro objetos: ", default = state_by_buf[b].query or "" }, function(input)
      if input == nil then return end
      state_by_buf[b].query = input
      render_object_list(b)
    end)
  end, { buffer = b, desc = "Objetos transporte: filtrar" })
  return b
end

local function render_dashboard(bufnr)
  local state = state_by_buf[bufnr]
  if not state then return end
  local lines = {
    "SAP Transportes",
    "r refrescar | <CR> copiar | b objetos | e abrir obj | v GUI | z diff obj | k readiness | K check ADT | j jobs | a acciones | l liberar | c detalle | x comparar | h historial | o owner | d borrar",
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
  vim.keymap.set("n", "b", function()
    local report = selected_report()
    if report then open_object_list(report, "") end
  end, { buffer = b, desc = "Transportes: objetos" })
  vim.keymap.set("n", "e", function()
    local report = selected_report()
    if report then M.open_transport_object(report) end
  end, { buffer = b, desc = "Transportes: abrir objeto" })
  vim.keymap.set("n", "v", function()
    local report = selected_report()
    if report then M.open_transport_object_gui(report) end
  end, { buffer = b, desc = "Transportes: objeto en SAP GUI" })
  vim.keymap.set("n", "z", function()
    local report = selected_report()
    if report then M.diff_transport_object(report) end
  end, { buffer = b, desc = "Transportes: diff objeto" })
  vim.keymap.set("n", "k", function()
    local report = selected_report()
    if report then M.show_readiness(report) end
  end, { buffer = b, desc = "Transportes: readiness" })
  vim.keymap.set("n", "K", function()
    local report = selected_report()
    if report and report.id then M.show_transport_consistency(report.id) end
  end, { buffer = b, desc = "Transportes: consistency ADT" })
  vim.keymap.set("n", "j", function()
    local report = selected_report()
    if report and report.id then M.show_release_jobs(report.id) end
  end, { buffer = b, desc = "Transportes: release jobs" })
  vim.keymap.set("n", "a", function()
    local report = selected_report()
    if report and report.id then M.show_transport_actions(report.id) end
  end, { buffer = b, desc = "Transportes: acciones CTS" })
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

local function extract_transport_request_xml(body, id)
  body = tostring(body or "")
  id = trim(id):upper()
  if body == "" or id == "" then return nil end
  local pattern = '<[%w_:]*request%s+[^>]*[%w_:]*number="' .. vim.pesc(id) .. '"[^>]*>'
  local start_pos, open_end = body:find(pattern)
  if not start_pos then return nil end
  local close_start, close_end = body:find("</[%w_:]*request>", open_end + 1)
  if not close_start then
    return body:sub(start_pos, open_end)
  end
  return body:sub(start_pos, close_end)
end

local function fetch_transport_detail_adt(id)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready() then return nil, "ADT no validado" end
  local creds = adt_http.creds and adt_http.creds() or nil
  local user = creds and creds.user or nil
  if not user or user == "" then
    local ctx = adt.get_current_context and adt.get_current_context() or nil
    user = ctx and ctx.user or nil
  end
  if not user or user == "" then return nil, "usuario SAP desconocido" end

  local body, _, code = adt_http.raw({
    method = "GET",
    path = "/sap/bc/adt/cts/transportrequests",
    query = {
      user = user:upper(),
      target = "true",
      requestType = "KWT",
      requestStatus = "DR",
    },
    accept = "application/vnd.sap.adt.transportorganizertree.v1+xml, application/vnd.sap.adt.transportorganizer.v1+xml",
  })
  if tonumber(code) == nil or code < 200 or code >= 300 or not body or body == "" then
    return nil, "ADT transportrequests HTTP " .. tostring(code or 0)
  end
  local block = extract_transport_request_xml(body, id)
  if not block then return nil, "orden no encontrada en árbol ADT" end
  local report = M._parse_transport_detail(id, { block })
  report.source = "adt"
  return report, nil
end

fetch_transport_detail = function(id, cb)
  local adt_report = fetch_transport_detail_adt(id)
  if adt_report and ((adt_report.objects and #adt_report.objects > 0) or (adt_report.tasks and #adt_report.tasks > 0)) then
    record_history("read", id, "ok", "detalle ADT")
    cb(adt_report, nil)
    return
  end

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

fetch_reports = function(cb)
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

function M.fetch_transport_report(id, cb)
  id = trim(id):upper()
  if id == "" then
    cb(nil, "Falta la orden de transporte.")
    return
  end
  if not ensure_ready() then
    cb(nil, "Conexión SAP no validada.")
    return
  end
  fetch_transport_detail(id, cb)
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

local function choose_transport_object(report, query, prompt, cb)
  local objects = filter_transport_objects(report, query)
  if #objects == 0 then
    notify("No hay objetos en " .. tostring(report.id or "?") .. " para el filtro indicado.", vim.log.levels.WARN)
    return
  end
  if #objects == 1 then
    cb(objects[1])
    return
  end
  vim.ui.select(objects, {
    prompt = prompt or ("Objeto de " .. tostring(report.id or "?") .. ":"),
    format_item = object_label,
  }, function(choice)
    if choice then cb(choice) end
  end)
end

local function select_report_or_fetch(id, cb)
  id = trim(id):upper()
  if id ~= "" then
    with_transport_report(id, cb)
    return
  end
  local report = selected_report()
  if report then
    cb(report)
    return
  end
  if not ensure_ready() then return end
  fetch_reports(function(reports, err)
    vim.schedule(function()
      if not reports or #reports == 0 then
        notify(err or "No hay órdenes de transporte abiertas.", vim.log.levels.WARN)
        return
      end
      vim.ui.select(reports, {
        prompt = "Orden de transporte:",
        format_item = function(item)
          return string.format("%s  owner=%s objetos=%d", item.id or "?", item.owner or "?", #(item.objects or {}))
        end,
      }, function(choice)
        if choice then cb(choice) end
      end)
    end)
  end)
end

function M.list_transport_objects(args)
  if type(args) == "table" and args.objects then
    open_object_list(args, "")
    return
  end
  local id, query = parse_order_args(args)
  select_report_or_fetch(id, function(report)
    open_object_list(report, query)
  end)
end

function M.open_transport_object(target, query)
  if type(target) == "table" and target.name and target.object and not target.objects then
    open_object_in_editor(target)
    return
  end
  if type(target) == "table" and target.objects then
    choose_transport_object(target, query or "", "Objeto a abrir:", open_object_in_editor)
    return
  end
  local id, q = parse_order_args(target)
  select_report_or_fetch(id, function(report)
    choose_transport_object(report, q, "Objeto a abrir:", open_object_in_editor)
  end)
end

function M.open_transport_object_gui(target, query)
  if type(target) == "table" and target.name and target.object and not target.objects then
    open_object_in_gui(target)
    return
  end
  if type(target) == "table" and target.objects then
    choose_transport_object(target, query or "", "Objeto para abrir en SAP GUI:", open_object_in_gui)
    return
  end
  local id, q = parse_order_args(target)
  select_report_or_fetch(id, function(report)
    choose_transport_object(report, q, "Objeto para abrir en SAP GUI:", open_object_in_gui)
  end)
end

function M.diff_transport_object(target, query)
  if type(target) == "table" and target.objects then
    choose_transport_object(target, query or "", "Objeto a comparar:", M.diff_transport_object)
    return
  end
  if type(target) ~= "table" or not target.name then
    local id, q = parse_order_args(target)
    select_report_or_fetch(id, function(report)
      choose_transport_object(report, q, "Objeto a comparar:", M.diff_transport_object)
    end)
    return
  end

  local obj = target
  local group = object_group(obj)
  if not group then
    notify("Tipo CTS no soportado para diff: " .. tostring(obj.object), vim.log.levels.WARN)
    return
  end
  notify("Leyendo " .. obj.name .. " para diff de transporte...")
  local left, left_err = read_object_source(obj, "inactive")
  local left_title = "transporte/inactive"
  if not left or #left == 0 then
    left, left_title = local_object_lines(obj)
  end
  local right, right_err = read_object_source(obj, "active")
  if not right or #right == 0 then
    notify("No se pudo leer versión activa de " .. obj.name .. ": " .. tostring(right_err), vim.log.levels.ERROR)
    return
  end
  if not left or #left == 0 then
    notify(
      "No hay versión inactive ni buffer local para " .. obj.name .. " (" .. tostring(left_err or "sin fuente") .. ").",
      vim.log.levels.WARN
    )
    return
  end
  record_history("diff-object", obj.name, "ok", (left_title or "local") .. " vs active")
  open_source_diff(obj, left_title or "local", left, "active", right)
end

function M.open_transport_gui(args)
  local id = parse_order_args(args)
  id = id or (selected_report() and selected_report().id) or ""
  id = trim(id):upper()
  if id == "" then
    notify("Indica una orden para abrir en GUI.", vim.log.levels.WARN)
    return
  end
  pcall(vim.fn.setreg, "+", id)
  record_history("gui", id, "copied", "SE09")
  notify("Orden " .. id .. " copiada. Abriendo SE09; pega o busca la orden allí.")
  local ok, sapgui = pcall(require, "sap-nvim.core.sapgui")
  if ok and sapgui.transaction then
    sapgui.transaction("SE09", { desktop = true })
    return
  end
  local ok_web, gui = pcall(require, "sap-nvim.core.gui")
  if ok_web and gui.run_transaction then
    gui.run_transaction("SE09")
  end
end

function M.show_transport_consistency(args)
  local id = parse_order_args(args)
  id = id or (selected_report() and selected_report().id) or ""
  if trim(id) == "" then
    notify("Indica una orden para consultar consistencychecks.", vim.log.levels.WARN)
    return
  end
  with_transport_report(id, function(report)
    notify("Consultando consistencychecks ADT de " .. tostring(report.id or id) .. "...")
    run_remote_consistency(report, function(result, err, attempts)
      vim.schedule(function()
        if result then
          record_history("consistency", report.id, result.ok and "ok" or "blocked", result.method .. " " .. result.endpoint)
          show("sap-transport-consistency://" .. (report.id or id), consistency_lines(result, attempts))
          return
        end
        record_history("consistency", report.id or id, "unavailable", err or "sin endpoint")
        show("sap-transport-consistency://" .. (report.id or id), consistency_lines({
          endpoint = consistency_paths(report)[1] or "?",
          method = "GET",
          code = 0,
          ok = false,
          errors = 0,
          warnings = 0,
          messages = { { severity = "W", text = err or "No disponible", object = "" } },
          raw = "",
        }, attempts))
      end)
    end)
  end)
end

function M.show_release_jobs(args)
  local id = parse_order_args(args)
  id = id or (selected_report() and selected_report().id) or ""
  if trim(id) == "" then
    notify("Indica una orden para consultar releasejobs.", vim.log.levels.WARN)
    return
  end
  with_transport_report(id, function(report)
    notify("Consultando releasejobs ADT de " .. tostring(report.id or id) .. "...")
    run_release_jobs(report, function(results, err)
      vim.schedule(function()
        if not results then
          record_history("releasejobs", report.id or id, "error", err or "sin endpoint")
          show("sap-transport-releasejobs://" .. (report.id or id), {
            "Release jobs ADT",
            "Consulta de estado; no ejecuta release ni crea jobs.",
            "",
            err or "No se pudo consultar releasejobs.",
          })
          return
        end
        record_history("releasejobs", report.id or id, "ok", tostring(#results) .. " endpoint(s)")
        show("sap-transport-releasejobs://" .. (report.id or id), release_job_lines(results))
      end)
    end)
  end)
end

local function transport_task_post_allowed()
  return productive().allow_transport_task_post == true
end

local function task_xml(id, user)
  return '<?xml version="1.0" encoding="ASCII"?>\n'
    .. '<tm:root xmlns:tm="http://www.sap.com/cts/adt/tm" tm:number="'
    .. xmlesc(trim(id):upper())
    .. '" tm:targetuser="'
    .. xmlesc(trim(user):upper())
    .. '" tm:useraction="newtask"/>'
end

function M._transport_new_task_plan(id, user)
  id = trim(id):upper()
  user = trim(user):upper()
  if id == "" then
    return { executable = false, reason = "missing_id", message = "Falta el código técnico de la orden (TRKORR, ej. S4FK901640)." }
  end
  if not id:match("^[A-Z0-9]+K%d+$") then
    return { executable = false, reason = "invalid_id", message = "Orden inválida: escribe el código TRKORR, no la descripción/nombre." }
  end
  if user == "" then
    return { executable = false, reason = "missing_user", message = "Falta el usuario SAP para crear la tarea." }
  end
  if not transport_task_post_allowed() then
    return {
      executable = false,
      reason = "opt_in_required",
      message = "Crear tareas por ADT está desactivado. Habilita productive.allow_transport_task_post=true y confirma el TRKORR exacto.",
    }
  end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.ready() then
    return { executable = false, reason = "not_ready", message = "Conexión ADT no validada; no se modifica CTS." }
  end
  return {
    executable = true,
    reason = "ready",
    method = "POST",
    path = "/sap/bc/adt/cts/transportrequests/" .. id .. "/tasks",
    body = task_xml(id, user),
    message = "Crear tarea CTS por ADT para " .. user .. " en " .. id .. ".",
  }
end

function M.create_transport_task(args)
  local id, rest = parse_order_args(args)
  local user = trim(rest):match("^(%S+)") or ""
  id = id or (selected_report() and selected_report().id) or ""
  local function run(tr, uname)
    local plan = M._transport_new_task_plan(tr, uname)
    if not plan.executable then
      notify(plan.message, vim.log.levels.WARN)
      if trim(tr) ~= "" then M.open_transport_gui(tr) end
      return
    end
    confirm_destructive(trim(tr):upper(), "Confirmar creación de tarea CTS para " .. trim(uname):upper() .. " en " .. trim(tr):upper() .. ".", function(confirm)
      if not confirm then return end
      local adt_http = require("sap-nvim.core.adt_http")
      local body, _, code = adt_http.raw({
        method = "POST",
        path = plan.path,
        content_type = "text/plain; charset=utf-8",
        body = plan.body,
        accept = "application/xml, application/vnd.sap.adt.transportorganizer.v1+xml, */*",
      })
      vim.schedule(function()
        if tonumber(code) and code >= 200 and code < 300 then
          record_history("newtask", trim(tr):upper(), "ok", trim(uname):upper())
          show("sap-transport-newtask://" .. trim(tr):upper(), {
            "Tarea CTS creada por ADT",
            "Orden: " .. trim(tr):upper(),
            "Usuario: " .. trim(uname):upper(),
            "HTTP: " .. tostring(code),
            "",
            body or "",
          })
        else
          record_history("newtask", trim(tr):upper(), "error", "HTTP " .. tostring(code or 0))
          notify("No se pudo crear la tarea CTS (HTTP " .. tostring(code or 0) .. ").", vim.log.levels.ERROR)
          if body and body ~= "" then show("sap-transport-newtask://" .. trim(tr):upper(), vim.split(body:gsub("\r", ""), "\n", { plain = true })) end
        end
      end)
    end)
  end
  if trim(id) == "" then
    vim.ui.input({ prompt = "Código de orden de transporte (TRKORR): " }, function(input_id)
      if input_id and trim(input_id) ~= "" then M.create_transport_task(input_id .. " " .. user) end
    end)
    return
  end
  if trim(user) == "" then
    vim.ui.input({ prompt = "Usuario SAP para nueva tarea en " .. trim(id):upper() .. ": " }, function(input_user)
      if input_user and trim(input_user) ~= "" then run(id, input_user) end
    end)
    return
  end
  run(id, user)
end

function M.show_transport_actions(args)
  local id = parse_order_args(args)
  id = id or (selected_report() and selected_report().id) or ""
  id = trim(id):upper()
  if id == "" then
    notify("Indica una orden para ver acciones CTS.", vim.log.levels.WARN)
    return
  end
  local prod = productive()
  local lines = {
    "Acciones CTS para " .. id,
    "Panel informativo/gated; no ejecuta cambios desde aquí.",
    "",
    "Lecturas seguras",
    "  :SapTransportConsistency " .. id .. "  - consistencychecks/readiness remoto ADT",
    "  :SapTransportReleaseJobs " .. id .. "  - releasejobs/newreleasejobs por GET",
    "",
    "Acciones con barrera",
    "  :SapTransportRelease " .. id .. "  - checks + confirmación exacta; libera solo si confirmas",
    "  :SapTransportReassign  - desactivado salvo productive.allow_reassign_transports=true (actual: " .. tostring(prod.allow_reassign_transports == true) .. ")",
    "  :SapTransportNewTask " .. id .. " <USUARIO>  - POST /tasks solo con productive.allow_transport_task_post=true (actual: " .. tostring(prod.allow_transport_task_post == true) .. ")",
    "  :SapTransportAddUser " .. id .. " <USUARIO>  - usa NewTask si está habilitado; si no, guía por SE09",
    "",
    "No ejecutado por sap-nvim hasta verificar endpoint seguro",
    "  sort/compress - posible normalización CTS; usa SE09/SE10 por ahora",
    "  protect - posible cambio de bloqueo/protección; usa SE09/SE10 por ahora",
    "  reassign por ADT directo - se mantiene detrás del comando existente y opt-in productivo",
  }
  show("sap-transport-actions://" .. id, lines)
end

function M._transport_add_user_plan(id, user)
  id = trim(id):upper()
  user = trim(user):upper()
  if id == "" then
    return { executable = false, reason = "missing_id", message = "Falta el código técnico de la orden (TRKORR, ej. S4FK901640)." }
  end
  if not id:match("^[A-Z0-9]+K%d+$") then
    return { executable = false, reason = "invalid_id", message = "Orden inválida: escribe el código TRKORR, no la descripción/nombre." }
  end
  if user == "" then
    return { executable = false, reason = "missing_user", message = "Falta el usuario SAP que quieres añadir a la orden." }
  end
  return M._transport_new_task_plan(id, user)
end

function M.add_transport_user(args)
  local id, rest = parse_order_args(args)
  local user = trim(rest):match("^(%S+)") or ""
  id = id or (selected_report() and selected_report().id) or ""

  local function finish(tr, uname)
    local plan = M._transport_add_user_plan(tr, uname)
    local tr_id = trim(tr):upper()
    if plan.reason == "invalid_id" or plan.reason == "missing_id" then
      notify(plan.message, vim.log.levels.WARN)
      return
    end
    if plan.executable then
      M.create_transport_task(tr_id .. " " .. trim(uname):upper())
      return
    end
    pcall(vim.fn.setreg, "+", tr_id)
    notify(
      plan.message
        .. " Código de orden copiado: "
        .. tr_id
        .. ". En SE09/SE10 añade el usuario SAP "
        .. trim(uname):upper()
        .. " como tarea/colaborador.",
      vim.log.levels.WARN
    )
    if tr_id ~= "" then M.open_transport_gui(tr_id) end
  end

  if trim(id) == "" then
    vim.ui.input({ prompt = "Código de orden de transporte (TRKORR, ej. S4FK901640): " }, function(input_id)
      if not input_id or trim(input_id) == "" then return end
      M.add_transport_user(input_id .. " " .. user)
    end)
    return
  end
  if trim(user) == "" then
    vim.ui.input({ prompt = "Usuario SAP a añadir a " .. trim(id):upper() .. ": " }, function(input_user)
      if not input_user or trim(input_user) == "" then return end
      finish(id, input_user)
    end)
    return
  end
  finish(id, user)
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

  vim.api.nvim_create_user_command("SapTransportObjects", function(args)
    M.list_transport_objects(args.args)
  end, { nargs = "*", desc = "sap-nvim: Listar/filtrar objetos de una orden" })

  vim.api.nvim_create_user_command("SapTransportOpenObject", function(args)
    M.open_transport_object(args.args)
  end, { nargs = "*", desc = "sap-nvim: Abrir objeto desde una orden" })

  vim.api.nvim_create_user_command("SapTransportObjectDiff", function(args)
    M.diff_transport_object(args.args)
  end, { nargs = "*", desc = "sap-nvim: Diff de objeto de transporte contra activo/local" })

  vim.api.nvim_create_user_command("SapTransportGui", function(args)
    M.open_transport_gui(args.args)
  end, { nargs = "?", desc = "sap-nvim: Copiar/abrir orden en SAP GUI" })

  vim.api.nvim_create_user_command("SapTransportAddUser", function(args)
    M.add_transport_user(args.args)
  end, { nargs = "*", desc = "sap-nvim: Añadir usuario/tarea de forma segura o guiar por GUI" })

  vim.api.nvim_create_user_command("SapTransportNewTask", function(args)
    M.create_transport_task(args.args)
  end, { nargs = "*", desc = "sap-nvim: Crear tarea CTS por ADT con opt-in y confirmación exacta" })

  vim.api.nvim_create_user_command("SapTransportConsistency", function(args)
    M.show_transport_consistency(args.args)
  end, { nargs = "?", desc = "sap-nvim: Consistency/readiness remoto ADT de una orden" })

  vim.api.nvim_create_user_command("SapTransportReleaseJobs", function(args)
    M.show_release_jobs(args.args)
  end, { nargs = "?", desc = "sap-nvim: Consultar releasejobs/newreleasejobs sin liberar" })

  vim.api.nvim_create_user_command("SapTransportActions", function(args)
    M.show_transport_actions(args.args)
  end, { nargs = "?", desc = "sap-nvim: Acciones CTS seguras/gated para una orden" })

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
  vim.keymap.set("n", "<leader>atb", M.list_transport_objects, { desc = "ABAP: Objetos de transporte" })
  vim.keymap.set("n", "<leader>ate", M.open_transport_object, { desc = "ABAP: Abrir objeto de transporte" })
  vim.keymap.set("n", "<leader>atg", M.open_transport_gui, { desc = "ABAP: Transporte en SAP GUI" })
  vim.keymap.set("n", "<leader>atD", M.diff_transport_object, { desc = "ABAP: Diff objeto transporte" })
  vim.keymap.set("n", "<leader>atk", M.show_readiness,      { desc = "ABAP: Readiness de transporte" })
  vim.keymap.set("n", "<leader>atK", M.show_transport_consistency, { desc = "ABAP: Consistency ADT transporte" })
  vim.keymap.set("n", "<leader>atj", M.show_release_jobs,    { desc = "ABAP: Release jobs transporte" })
  vim.keymap.set("n", "<leader>ata", M.show_transport_actions, { desc = "ABAP: Acciones CTS transporte" })
  vim.keymap.set("n", "<leader>atx", M.compare_transports,  { desc = "ABAP: Comparar transportes" })
  vim.keymap.set("n", "<leader>ath", M.show_history,        { desc = "ABAP: Historial de transportes" })
end

M._parse_transport_line = parse_transport_line
M._object_group = object_group
M._object_source_uri = object_source_uri
M._object_label = object_label
M._filter_transport_objects = filter_transport_objects
M._object_list_lines = object_list_lines
M._history_path = history_path
M._read_history = read_history
M._record_history = record_history
M._compare_lines = compare_lines
M._report_lines = report_lines
M._parse_adt_links = parse_adt_links
M._parse_adt_messages = parse_adt_messages
M._parse_transport_consistency_result = parse_transport_consistency_result
M._consistency_lines = consistency_lines
M._parse_release_jobs = parse_release_jobs
M._release_job_lines = release_job_lines
M._consistency_paths = consistency_paths
M._release_job_paths = release_job_paths
M._task_xml = task_xml

return M
