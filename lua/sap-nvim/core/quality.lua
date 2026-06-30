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

local function xmlesc(s)
  return (tostring(s or ""))
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local function unxml(s)
  return (s or ""):gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&#x0A;", "\n")
    :gsub("&#x0D;", "\r")
    :gsub("&#10;", "\n")
    :gsub("&#13;", "\r")
    :gsub("&amp;", "&")
end

local function xml_attr(attrs, name)
  return attrs and (
    attrs:match('[%w_:-]*' .. name .. '="([^"]*)"')
    or attrs:match(name .. '="([^"]*)"')
  ) or nil
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

local current_object
local worklist_state = {
  source = "auto",
  filter = "all",
  items = {},
  filtered = {},
  title = "SAP ATC Worklist",
}

local function state_dir()
  return vim.fn.stdpath("state") .. "/sap-nvim"
end

local function history_path()
  return state_dir() .. "/quality-history.json"
end

local function settings_path()
  return state_dir() .. "/quality-settings.json"
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

local function read_settings()
  local path = settings_path()
  if vim.fn.filereadable(path) ~= 1 then return {} end
  local ok, data = pcall(json_decode, table.concat(vim.fn.readfile(path), "\n"))
  if not ok or type(data) ~= "table" then return {} end
  return data
end

local function write_settings(settings)
  pcall(vim.fn.mkdir, state_dir(), "p")
  pcall(vim.fn.writefile, vim.split(json_encode(settings or {}), "\n", { plain = true }), settings_path())
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

local function landing_lines(scope, reason)
  local lines = {
    "SAP Quality",
    "",
    "Panel de calidad local: ATC, AUnit, quickfix e historial.",
    "",
  }
  if scope then
    lines[#lines + 1] = string.format("Objeto  : %s [%s]", scope.name or "?", scope.group or "?")
    if scope.package and scope.package ~= "" then lines[#lines + 1] = "Paquete : " .. scope.package end
    lines[#lines + 1] = ""
  elseif reason and reason ~= "" then
    lines[#lines + 1] = "Estado  : " .. reason
    lines[#lines + 1] = ""
  end
  lines[#lines + 1] = "Acciones"
  lines[#lines + 1] = "  a  ATC del objeto actual"
  lines[#lines + 1] = "  p  ATC del paquete del objeto actual"
  lines[#lines + 1] = "  w  Worklist ATC desde quickfix/historial"
  lines[#lines + 1] = "  u  AUnit del objeto actual"
  lines[#lines + 1] = "  h  Historial local"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Comandos"
  lines[#lines + 1] = "  :SapQuality atc object <OBJ>"
  lines[#lines + 1] = "  :SapQuality atc package <PAQUETE>"
  lines[#lines + 1] = "  :SapQuality atc transport <ORDEN>"
  lines[#lines + 1] = "  :SapAtcWorklist [quickfix|history] [all|errors|warnings|info]"
  lines[#lines + 1] = "  :SapAtcRemoteWorklist [id=<ID>] [timestamp=<TS>] [all|errors|warnings|info]"
  lines[#lines + 1] = "  :SapAtcFilter <all|errors|warnings|info>"
  lines[#lines + 1] = "  :SapAtcHelp"
  lines[#lines + 1] = "  :SapAtcDoc"
  lines[#lines + 1] = "  :SapAtcRoutes"
  lines[#lines + 1] = "  :SapQuality aunit object <CLASE>"
  lines[#lines + 1] = ""
  lines[#lines + 1] = "q cierra"
  return lines
end

function M.open_panel(reason)
  local scope, err = current_object()
  local buf = show("sap-quality://panel", landing_lines(scope, reason or err))
  vim.keymap.set("n", "a", function() M.run_atc("") end, { buffer = buf, desc = "Quality: ATC objeto" })
  vim.keymap.set("n", "p", function()
    local obj = current_object()
    if obj and obj.package and obj.package ~= "" then
      M.run_atc("package " .. obj.package)
    else
      M.open_panel("El objeto actual no tiene paquete conocido.")
    end
  end, { buffer = buf, desc = "Quality: ATC paquete" })
  vim.keymap.set("n", "u", function() M.run_aunit("") end, { buffer = buf, desc = "Quality: AUnit objeto" })
  vim.keymap.set("n", "w", function() M.show_worklist("") end, { buffer = buf, desc = "Quality: worklist ATC" })
  return buf
end

local function severity_type(sev)
  sev = tostring(sev or ""):upper()
  if sev:match("^W") or sev == "WARNING" then return "W" end
  if sev:match("^I") or sev == "INFO" or sev == "INFORMATION" then return "I" end
  return "E"
end

local function severity_label(sev)
  sev = severity_type(sev)
  if sev == "W" then return "warning" end
  if sev == "I" then return "info" end
  return "error"
end

local filter_aliases = {
  a = "all",
  all = "all",
  e = "errors",
  err = "errors",
  error = "errors",
  errors = "errors",
  w = "warnings",
  warn = "warnings",
  warning = "warnings",
  warnings = "warnings",
  i = "info",
  inf = "info",
  info = "info",
  infos = "info",
}

local function normalize_filter(filter)
  filter = trim(filter):lower()
  if filter == "" then return "all" end
  return filter_aliases[filter]
end

local function default_filter()
  return normalize_filter(read_settings().severity_filter or "") or "all"
end

local function persist_filter(filter)
  filter = normalize_filter(filter)
  if not filter then return nil end
  local settings = read_settings()
  settings.severity_filter = filter
  write_settings(settings)
  return filter
end

local function severity_matches_filter(sev, filter)
  filter = normalize_filter(filter) or "all"
  sev = severity_type(sev)
  if filter == "all" then return true end
  if filter == "errors" then return sev == "E" end
  if filter == "warnings" then return sev == "W" end
  if filter == "info" then return sev == "I" end
  return true
end

local function extract_url(text)
  local url = tostring(text or ""):match("(https?://%S+)")
  if not url then return nil end
  return (url:gsub("[%)%]%.,;]+$", ""))
end

local function extract_adt_uri(text)
  local uri = tostring(text or ""):match("(/sap/bc/adt/%S+)")
  if not uri then return nil end
  return (uri:gsub("[%)%]%.,;]+$", ""))
end

local function extract_check_id(text)
  text = tostring(text or "")
  return text:match("[Cc]heck%s*[Ii][Dd]%s*[:=]%s*([%w_./:-]+)")
    or text:match("[Aa][Tt][Cc]%s*[Cc]heck%s*[:=]%s*([%w_./:-]+)")
    or text:match("[Cc]heck%s*[:=]%s*([%w_./:-]+)")
    or text:match("%[([%w_./:-]+)%]")
end

local function item_user_data(item)
  local data = type(item) == "table" and item.user_data or nil
  return type(data) == "table" and data or {}
end

local function check_meta(item)
  local data = item_user_data(item)
  local text = tostring((type(item) == "table" and item.text) or "")
  return {
    check_id = data.check_id or data.check or extract_check_id(text),
    help_url = data.help_url or data.url or extract_url(text),
    doc_uri = data.doc_uri or data.documentation_uri or data.uri or extract_adt_uri(text),
    finding_uri = data.finding_uri or data.finding,
    exemption_uri = data.exemption_uri or data.exemption,
    help_text = data.help_text or data.documentation or data.long_text,
  }
end

local function attach_check_meta(item, meta)
  if not item then return end
  meta = meta or {}
  local extracted = check_meta(item)
  local data = item_user_data(item)
  data.check_id = data.check_id or meta.check_id or extracted.check_id
  data.help_url = data.help_url or meta.help_url or extracted.help_url
  data.doc_uri = data.doc_uri or meta.doc_uri or extracted.doc_uri
  data.finding_uri = data.finding_uri or meta.finding_uri or extracted.finding_uri
  data.exemption_uri = data.exemption_uri or meta.exemption_uri or extracted.exemption_uri
  data.help_text = data.help_text or meta.help_text or extracted.help_text
  if data.check_id or data.help_url or data.doc_uri or data.finding_uri or data.exemption_uri or data.help_text then
    item.user_data = data
  end
end

local function serialized_finding(item)
  if type(item) ~= "table" then return nil end
  local meta = check_meta(item)
  return {
    filename = item.filename or item.module or "",
    bufnr = item.bufnr,
    lnum = tonumber(item.lnum) or 0,
    col = tonumber(item.col) or 1,
    type = severity_type(item.type),
    text = tostring(item.text or ""),
    check_id = meta.check_id,
    help_url = meta.help_url,
    doc_uri = meta.doc_uri,
    finding_uri = meta.finding_uri,
    exemption_uri = meta.exemption_uri,
    help_text = meta.help_text,
  }
end

local function normalize_finding(item, qf_index)
  local f = serialized_finding(item)
  if not f then return nil end
  f.qf_index = qf_index
  if f.check_id or f.help_url or f.doc_uri or f.finding_uri or f.exemption_uri or f.help_text then
    f.user_data = {
      check_id = f.check_id,
      help_url = f.help_url,
      doc_uri = f.doc_uri,
      finding_uri = f.finding_uri,
      exemption_uri = f.exemption_uri,
      help_text = f.help_text,
    }
  end
  return f
end

function M._serialize_findings(qf)
  local findings = {}
  for _, item in ipairs(qf or {}) do
    local f = serialized_finding(item)
    if f then findings[#findings + 1] = f end
  end
  return findings
end

function M._filter_findings(items, filter)
  local out = {}
  for _, item in ipairs(items or {}) do
    if severity_matches_filter(item.type, filter) then out[#out + 1] = item end
  end
  return out
end

current_object = function()
  local bufnr = vim.api.nvim_get_current_buf()
  local filename = vim.api.nvim_buf_get_name(bufnr)
  local meta = vim.b[bufnr].sap_obj or {}
  local group = meta.group or objtype.group(filename)
  local name = meta.name or objtype.name(filename)
  name = tostring(name or ""):upper()
  if name == "" then return nil, "Guarda o abre un objeto SAP primero." end
  if not group or group == "" then return nil, "No puedo deducir el tipo SAP del objeto actual." end
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
  local pending_meta, last_item = {}, nil
  for _, raw in ipairs(lines or {}) do
    local line = trim(raw)
    if line ~= "" then
      local ctx = line:match("^%-%-%s+(.+)$") or line:match("^Object:%s*(.+)$")
      if ctx then
        context = trim(ctx)
      else
        local meta_key, meta_value = line:match("^([%w%s]+):%s*(.+)$")
        meta_key = meta_key and trim(meta_key):lower() or nil
        if meta_key and (meta_key == "check" or meta_key == "check id" or meta_key == "atc check") then
          pending_meta.check_id = trim(meta_value)
        elseif meta_key and (meta_key == "help" or meta_key == "documentation" or meta_key == "doc"
            or meta_key == "long text" or meta_key == "longtext") then
          local target = last_item and item_user_data(last_item) or pending_meta
          local url = extract_url(meta_value)
          if url then target.help_url = target.help_url or url end
          target.help_text = target.help_text or trim(meta_value)
          if last_item then last_item.user_data = target end
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
          local item = {
            filename = filename,
            lnum = tonumber(lnum) or 0,
            col = tonumber(col) or 1,
            type = severity_type(sev),
            text = (context and (context .. ": ") or "") .. trim(msg),
          }
          attach_check_meta(item, pending_meta)
          qf[#qf + 1] = item
          last_item = item
        elseif line:match("[Ee]rror") or line:match("[Ww]arning") or line:match("[Ii]nfo") then
          local item = { filename = filename, lnum = 0, col = 1, type = "E", text = line }
          attach_check_meta(item, pending_meta)
          qf[#qf + 1] = item
          last_item = item
        end
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

local function qf_item(item)
  local f = serialized_finding(item)
  if not f then return nil end
  local out = {
    filename = f.filename,
    bufnr = f.bufnr,
    lnum = f.lnum,
    col = f.col,
    type = f.type,
    text = f.text,
  }
  if f.check_id or f.help_url or f.help_text then
    out.user_data = {
      check_id = f.check_id,
      help_url = f.help_url,
      doc_uri = f.doc_uri,
      finding_uri = f.finding_uri,
      exemption_uri = f.exemption_uri,
      help_text = f.help_text,
    }
  end
  return out
end

local function qf_items(items)
  local out = {}
  for _, item in ipairs(items or {}) do
    local q = qf_item(item)
    if q then out[#out + 1] = q end
  end
  return out
end

local function current_quickfix_items()
  local out = {}
  for i, item in ipairs(vim.fn.getqflist()) do
    local f = normalize_finding(item, i)
    if f then out[#out + 1] = f end
  end
  return out
end

local function latest_history_items()
  local entries = read_history()
  for i = #entries, 1, -1 do
    local e = entries[i]
    if type(e.findings) == "table" and #e.findings > 0 then
      local out = {}
      for j, item in ipairs(e.findings) do
        if type(item) == "table" then
          local enriched = vim.tbl_extend("force", item, {
            user_data = {
              check_id = item.check_id,
              help_url = item.help_url,
              doc_uri = item.doc_uri,
              finding_uri = item.finding_uri,
              exemption_uri = item.exemption_uri,
              help_text = item.help_text,
            },
          })
          local f = normalize_finding(enriched, j)
          if f then out[#out + 1] = f end
        end
      end
      return out, e
    end
  end
  return {}, nil
end

local function parse_worklist_args(args)
  local source, filter = nil, nil
  for token in tostring(args or ""):gmatch("%S+") do
    local t = token:lower()
    if t == "qf" or t == "quickfix" or t == "current" then
      source = "quickfix"
    elseif t == "hist" or t == "history" or t == "historical" then
      source = "history"
    elseif normalize_filter(t) then
      filter = normalize_filter(t)
    end
  end
  return source or "auto", filter
end

local function collect_worklist_items(source)
  if source == "history" then
    local items, entry = latest_history_items()
    return items, "history", entry
  end
  local qf = current_quickfix_items()
  if source == "quickfix" or #qf > 0 then return qf, "quickfix", nil end
  local items, entry = latest_history_items()
  return items, "history", entry
end

local function priority_severity(priority, typ)
  typ = tostring(typ or ""):upper()
  if typ:match("^W") then return "W" end
  if typ:match("^I") then return "I" end
  local p = tonumber(priority)
  if p == 2 then return "W" end
  if p and p >= 3 then return "I" end
  return "E"
end

function M._parse_reporters(body)
  local out, seen = {}, {}
  for attrs in tostring(body or ""):gmatch("<[%w_:]*reporter%s+([^>]*)/?>") do
    local id = unxml(xml_attr(attrs, "id") or xml_attr(attrs, "name") or xml_attr(attrs, "key") or "")
    local name = unxml(xml_attr(attrs, "name") or xml_attr(attrs, "description") or id)
    if id ~= "" and not seen[id] then
      seen[id] = true
      out[#out + 1] = { id = id, name = name }
    end
  end
  table.sort(out, function(a, b) return (a.id or "") < (b.id or "") end)
  return out
end

local function object_label_from_attrs(attrs)
  local name = unxml(xml_attr(attrs, "name") or xml_attr(attrs, "objectName") or "")
  local typ = unxml(xml_attr(attrs, "type") or xml_attr(attrs, "objectType") or "")
  if name ~= "" and typ ~= "" then return name .. " [" .. typ .. "]" end
  if name ~= "" then return name end
  return unxml(xml_attr(attrs, "uri") or "SAP")
end

local function finding_from_worklist_attrs(attrs, inner, obj)
  attrs = attrs or ""
  inner = inner or ""
  obj = obj or {}
  local finding_uri = unxml(xml_attr(attrs, "uri") or xml_attr(attrs, "href") or "")
  local location = unxml(xml_attr(attrs, "location") or xml_attr(attrs, "locationUri") or finding_uri)
  local line, col = (location or ""):match("start=(%d+),(%d+)")
  local doc_uri = inner:match("<[%w_:]*link%s+[^>]*rel=\"documentation\"[^>]*href=\"([^\"]+)\"")
    or inner:match("<[%w_:]*link%s+[^>]*href=\"([^\"]+)\"[^>]*rel=\"documentation\"")
    or unxml(xml_attr(attrs, "documentationUri") or xml_attr(attrs, "docUri") or "")
  doc_uri = doc_uri ~= "" and unxml(doc_uri) or nil
  local check_id = unxml(xml_attr(attrs, "checkId") or xml_attr(attrs, "check") or "")
  local check_title = unxml(xml_attr(attrs, "checkTitle") or xml_attr(attrs, "checkName") or "")
  local msg = unxml(xml_attr(attrs, "messageTitle") or xml_attr(attrs, "message") or xml_attr(attrs, "shortText") or "")
  if msg == "" then
    msg = unxml(inner:match("<[%w_:]*message[^>]*>(.-)</[%w_:]*message>") or inner:match("<[%w_:]*shortText[^>]*>(.-)</[%w_:]*shortText>") or "")
  end
  if msg == "" then msg = check_title ~= "" and check_title or "ATC finding" end
  local help_url = doc_uri and doc_uri:match("^https?://") and doc_uri or nil
  local exemption_uri = unxml(xml_attr(attrs, "exemptionUri") or "")
  return {
    filename = obj.filename or obj.label or "SAP",
    lnum = tonumber(line) or tonumber(xml_attr(attrs, "line")) or 0,
    col = tonumber(col) or tonumber(xml_attr(attrs, "column")) or 1,
    type = priority_severity(xml_attr(attrs, "priority"), xml_attr(attrs, "type") or xml_attr(attrs, "severity")),
    text = (obj.label and (obj.label .. ": ") or "") .. msg,
    module = obj.label or "SAP",
    user_data = {
      check_id = check_id ~= "" and check_id or nil,
      help_url = help_url,
      doc_uri = doc_uri and not help_url and doc_uri or nil,
      finding_uri = finding_uri ~= "" and finding_uri or nil,
      exemption_uri = exemption_uri ~= "" and exemption_uri or nil,
      help_text = check_title ~= "" and check_title or nil,
    },
  }
end

function M._parse_atc_worklist_response(body)
  local qf = {}
  body = tostring(body or "")
  for obj_attrs, obj_inner in body:gmatch("<[%w_:]*object%s+([^>]-)>(.-)</[%w_:]*object>") do
    local obj = {
      label = object_label_from_attrs(obj_attrs),
      filename = unxml(xml_attr(obj_attrs, "name") or xml_attr(obj_attrs, "uri") or "SAP"),
    }
    for attrs, inner in obj_inner:gmatch("<[%w_:]*finding%s+([^>]-)>(.-)</[%w_:]*finding>") do
      qf[#qf + 1] = finding_from_worklist_attrs(attrs, inner, obj)
    end
    for attrs in obj_inner:gmatch("<[%w_:]*finding%s+([^>]*)/>") do
      qf[#qf + 1] = finding_from_worklist_attrs(attrs, "", obj)
    end
  end
  if #qf == 0 then
    for attrs, inner in body:gmatch("<[%w_:]*finding%s+([^>]-)>(.-)</[%w_:]*finding>") do
      qf[#qf + 1] = finding_from_worklist_attrs(attrs, inner, nil)
    end
    for attrs in body:gmatch("<[%w_:]*finding%s+([^>]*)/>") do
      qf[#qf + 1] = finding_from_worklist_attrs(attrs, "", nil)
    end
  end
  return qf
end

function M._worklist_lines(items, opts)
  opts = opts or {}
  local filter = normalize_filter(opts.filter) or "all"
  local filtered = M._filter_findings(items, filter)
  local source = opts.source or "quickfix"
  local lines = {
    "SAP ATC Worklist",
    "",
    "Source   : " .. source,
    string.format("Filter   : %s (%d/%d)", filter, #filtered, #(items or {})),
    "Commands : <CR>/o jump · c quickfix · ?/K help · D doc · x exemption · a/e/w/i filter · H history · q close",
    "",
  }
  local rows = {}
  if #filtered == 0 then
    lines[#lines + 1] = "Sin hallazgos para este filtro."
  else
    lines[#lines + 1] = "Hallazgos"
    for i, item in ipairs(filtered) do
      local meta = check_meta(item)
      local loc = (item.filename and item.filename ~= "" and vim.fn.fnamemodify(item.filename, ":t") or "?")
        .. ":" .. tostring(item.lnum or 0) .. ":" .. tostring(item.col or 1)
      local check = meta.check_id and (" [" .. meta.check_id .. "]") or ""
      local help = (meta.help_url or meta.help_text) and " ?" or ""
      lines[#lines + 1] = string.format(
        "%3d. %s %-7s %-24s %s%s%s",
        i,
        severity_type(item.type),
        severity_label(item.type),
        loc,
        (item.text or ""):gsub("%s+", " "),
        check,
        help
      )
      rows[#lines] = i
    end
  end
  return lines, rows, filtered
end

local function worklist_index_from_cursor()
  local buf = vim.api.nvim_get_current_buf()
  local ok, rows = pcall(function() return vim.b[buf].sap_quality_worklist_rows end)
  if not ok or type(rows) ~= "table" then return nil end
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return rows[line]
end

local function selected_worklist_item(index)
  index = tonumber(index) or worklist_index_from_cursor()
  if index and worklist_state.filtered[index] then return worklist_state.filtered[index], index end
  local info = vim.fn.getqflist({ idx = 0, items = 0 })
  local qf_index = tonumber(info.idx) or 0
  local item = info.items and info.items[qf_index]
  if item then return normalize_finding(item, qf_index), qf_index end
  return nil, nil
end

local function put_worklist_in_quickfix(open)
  local items = qf_items(worklist_state.filtered)
  vim.fn.setqflist({}, "r", { items = items, title = worklist_state.title })
  if open and #items > 0 then pcall(vim.cmd, "copen") end
  return items
end

function M.open_worklist_quickfix()
  local items = put_worklist_in_quickfix(true)
  if #items == 0 then notify("No hay hallazgos en la worklist filtrada.", vim.log.levels.INFO) end
end

function M.open_worklist_item(index)
  local _, idx = selected_worklist_item(index)
  if not idx then return notify("Selecciona un hallazgo de la worklist.", vim.log.levels.WARN) end
  local items = put_worklist_in_quickfix(false)
  if #items == 0 then return notify("No hay hallazgos navegables.", vim.log.levels.INFO) end
  pcall(vim.cmd, "cc " .. tostring(idx))
end

function M._finding_help_lines(item)
  local meta = check_meta(item or {})
  local lines = {
    "ATC Check Help",
    "",
    "Severity : " .. severity_label((item or {}).type),
    "Location : " .. tostring((item or {}).filename or "?") .. ":" .. tostring((item or {}).lnum or 0),
    "Message  : " .. tostring((item or {}).text or ""),
  }
  if meta.check_id then lines[#lines + 1] = "Check   : " .. meta.check_id end
  lines[#lines + 1] = ""
  if meta.help_url then lines[#lines + 1] = "URL     : " .. meta.help_url end
  if meta.doc_uri then lines[#lines + 1] = "ADT URI : " .. meta.doc_uri end
  if meta.finding_uri then lines[#lines + 1] = "Finding : " .. meta.finding_uri end
  if meta.help_text then lines[#lines + 1] = "Text    : " .. meta.help_text end
  if not meta.help_url and not meta.doc_uri and not meta.help_text and not meta.check_id then
    lines[#lines + 1] = "Este hallazgo no trae documentación local parseable."
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "q cierra"
  return lines
end

function M.show_check_help(args)
  local item = selected_worklist_item(tonumber(trim(args or "")))
  if not item then return notify("No hay hallazgo ATC seleccionado.", vim.log.levels.WARN) end
  show("sap-atc-help://check", M._finding_help_lines(item))
end

local function strip_xml_text(body)
  local text = unxml(tostring(body or ""))
  text = text:gsub("<[%w_:]*br%s*/>", "\n")
    :gsub("</[%w_:]*p>", "\n")
    :gsub("<[^>]+>", " ")
    :gsub("[ \t]+", " ")
    :gsub("\n%s+", "\n")
  local lines = {}
  for line in (text .. "\n"):gmatch("([^\n]*)\n") do
    line = trim(line)
    if line ~= "" then lines[#lines + 1] = line end
  end
  return lines
end

function M._remote_doc_request(item)
  local meta = check_meta(item or {})
  local uri = meta.doc_uri or meta.help_url
  if not uri or uri == "" or uri:match("^https?://") then return nil, "no ADT documentation URI" end
  if not uri:match("^/sap/bc/adt/") then return nil, "documentation URI is not an ADT route" end
  return { method = "GET", path = uri, accept = "text/html,application/xml,text/plain" }
end

function M._finding_doc_lines(item, remote_body, detail)
  local lines = M._finding_help_lines(item)
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Remote documentation"
  if remote_body and remote_body ~= "" then
    local doc = strip_xml_text(remote_body)
    if #doc == 0 then
      lines[#lines + 1] = "ADT devolvió documentación, pero no hay texto parseable."
    else
      for _, line in ipairs(doc) do lines[#lines + 1] = line end
    end
  else
    lines[#lines + 1] = detail or "No hay documentación remota disponible para este hallazgo."
  end
  return lines
end

function M.show_check_documentation(args)
  local item = selected_worklist_item(tonumber(trim(args or "")))
  if not item then return notify("No hay hallazgo ATC seleccionado.", vim.log.levels.WARN) end
  local req, reason = M._remote_doc_request(item)
  if not req then return show("sap-atc-doc://check", M._finding_doc_lines(item, nil, reason)) end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available or not adt_http.is_available() then
    return show("sap-atc-doc://check", M._finding_doc_lines(item, nil, "ADT no disponible o no validado."))
  end
  local body, _, code = adt_http.raw(req)
  if tonumber(code) == nil or code < 200 or code >= 300 then
    return show("sap-atc-doc://check", M._finding_doc_lines(item, nil, "Documentación ADT no disponible (HTTP " .. tostring(code) .. ")."))
  end
  show("sap-atc-doc://check", M._finding_doc_lines(item, body, nil))
end

function M.request_exemption_info(args)
  local item = selected_worklist_item(tonumber(trim(args or "")))
  if not item then return notify("No hay hallazgo ATC seleccionado.", vim.log.levels.WARN) end
  local meta = check_meta(item)
  local lines = {
    "ATC Exemption Request",
    "",
    "Esta acción es informativa y no envía ninguna exención a SAP.",
    "sap-nvim no implementa POST de exenciones sin endpoint verificado y confirmaciones explícitas.",
    "",
    "Finding : " .. tostring(meta.finding_uri or "?"),
    "Check   : " .. tostring(meta.check_id or "?"),
    "Message : " .. tostring(item.text or ""),
    "",
    "q cierra",
  }
  show("sap-atc-exemption://request", lines)
end

local function render_worklist(items, source, filter, title)
  filter = normalize_filter(filter) or "all"
  local lines, rows, filtered = M._worklist_lines(items, { source = source, filter = filter })
  worklist_state = {
    source = source,
    filter = filter,
    items = items or {},
    filtered = filtered or {},
    title = title or ("SAP ATC Worklist: " .. source .. " " .. filter),
  }
  local buf = show("sap-atc-worklist://" .. source .. "/" .. filter, lines)
  vim.b[buf].sap_quality_worklist_rows = rows
  vim.keymap.set("n", "<CR>", function() M.open_worklist_item() end, { buffer = buf, desc = "ATC: ir al hallazgo" })
  vim.keymap.set("n", "o", function() M.open_worklist_item() end, { buffer = buf, desc = "ATC: ir al hallazgo" })
  vim.keymap.set("n", "c", M.open_worklist_quickfix, { buffer = buf, desc = "ATC: enviar a quickfix" })
  vim.keymap.set("n", "?", function() M.show_check_help("") end, { buffer = buf, desc = "ATC: ayuda del check" })
  vim.keymap.set("n", "K", function() M.show_check_help("") end, { buffer = buf, desc = "ATC: ayuda del check" })
  vim.keymap.set("n", "D", function() M.show_check_documentation("") end, { buffer = buf, desc = "ATC: documentación remota" })
  vim.keymap.set("n", "x", function() M.request_exemption_info("") end, { buffer = buf, desc = "ATC: solicitud de exención informativa" })
  vim.keymap.set("n", "a", function() M.filter_worklist("all") end, { buffer = buf, desc = "ATC: todos" })
  vim.keymap.set("n", "e", function() M.filter_worklist("errors") end, { buffer = buf, desc = "ATC: errores" })
  vim.keymap.set("n", "w", function() M.filter_worklist("warnings") end, { buffer = buf, desc = "ATC: warnings" })
  vim.keymap.set("n", "i", function() M.filter_worklist("info") end, { buffer = buf, desc = "ATC: info" })
  vim.keymap.set("n", "H", function() M.show_worklist("history " .. filter) end, { buffer = buf, desc = "ATC: historial" })
  return buf
end

function M.show_worklist(args)
  local source, filter = parse_worklist_args(args)
  filter = filter or worklist_state.filter or default_filter()
  local items, actual_source, history_entry = collect_worklist_items(source)
  local title
  if history_entry and history_entry.target then
    title = "SAP ATC Worklist: history " .. tostring(history_entry.target)
  end
  return render_worklist(items, actual_source, filter, title)
end

function M.show_remote_worklist(args)
  local info, filter = parse_remote_worklist_args(args)
  if not info.id and worklist_state.remote then info = vim.tbl_extend("force", {}, worklist_state.remote, info) end
  if not info.id or info.id == "" then
    return notify("Indica id=<WORKLIST_ID> o ejecuta un ATC que devuelva worklistId.", vim.log.levels.WARN)
  end
  local qf, detail = M._fetch_remote_worklist(info)
  if detail and detail ~= "" then notify(detail, #qf > 0 and vim.log.levels.INFO or vim.log.levels.WARN) end
  worklist_state.remote = info
  return render_worklist(qf, "remote", filter or default_filter(), "SAP ATC Worklist: remote " .. tostring(info.id))
end

function M.filter_worklist(args)
  local filter = persist_filter(args or "")
  if not filter then return notify("Filtro ATC no reconocido: " .. tostring(args), vim.log.levels.WARN) end
  if worklist_state.items and #worklist_state.items > 0 then
    return render_worklist(worklist_state.items, worklist_state.source or "quickfix", filter)
  end
  return M.show_worklist(filter)
end

local function object_base_uri(scope)
  scope = scope or current_object()
  if not scope then return nil end
  if scope.uri and scope.uri ~= "" then return scope.uri:gsub("/source/main$", "") end
  local ok_source, source = pcall(require, "sap-nvim.core.source")
  if ok_source and source._object_uri then
    return source._object_uri(scope.group, scope.name, scope)
  end
  return nil
end

function M._checkrun_xml(objects)
  local parts = {
    '<?xml version="1.0" encoding="UTF-8"?><chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" xmlns:adtcore="http://www.sap.com/adt/core">',
  }
  for _, obj in ipairs(objects or {}) do
    if obj.uri and obj.uri ~= "" then
      parts[#parts + 1] = '<chkrun:checkObject adtcore:uri="' .. xmlesc(obj.uri:gsub("/source/main$", "")) .. '" chkrun:version="active"></chkrun:checkObject>'
    end
  end
  parts[#parts + 1] = "</chkrun:checkObjectList>"
  return table.concat(parts, "")
end

function M._remote_validation_lines(result)
  result = result or {}
  local lines = {
    "SAP ATC Remote Routes",
    "",
    "Reporters route : GET /sap/bc/adt/checkruns/reporters",
    "Reporters HTTP  : " .. tostring(result.reporters_code or 0),
    "Reporters       : " .. tostring(#(result.reporters or {})),
  }
  for _, r in ipairs(result.reporters or {}) do
    lines[#lines + 1] = "  - " .. tostring(r.id) .. (r.name and r.name ~= r.id and (" - " .. r.name) or "")
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Checkrun route  : POST /sap/bc/adt/checkruns?reporters=abapCheckRun"
  lines[#lines + 1] = "Checkrun HTTP   : " .. tostring(result.checkrun_code or 0)
  lines[#lines + 1] = "Checkrun object : " .. tostring(result.object_uri or "skipped")
  lines[#lines + 1] = "Findings        : " .. tostring(#(result.qf or {}))
  if result.detail and result.detail ~= "" then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Detail          : " .. result.detail
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "q cierra"
  return lines
end

function M.validate_remote(args)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available or not adt_http.is_available() then
    return show("sap-atc-routes://remote", M._remote_validation_lines({ detail = "ADT no disponible o no validado." }))
  end
  local result = {}
  local body, _, code = adt_http.raw({
    method = "GET",
    path = "/sap/bc/adt/checkruns/reporters",
    accept = "application/xml",
  })
  result.reporters_code = code
  result.reporters = M._parse_reporters(body)

  local scope = parse_scope(args or "", "object")
  local uri = scope and object_base_uri(scope) or nil
  result.object_uri = uri
  if uri then
    local check_body, _, check_code = adt_http.raw({
      method = "POST",
      path = "/sap/bc/adt/checkruns",
      query = { reporters = "abapCheckRun" },
      content_type = "application/vnd.sap.adt.checkobjects+xml",
      body = M._checkrun_xml({ { uri = uri, name = scope.name, group = scope.group } }),
      accept = "application/xml",
    })
    result.checkrun_code = check_code
    local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
    result.qf = ok_adt and adt._parse_checkrun_response(check_body, { scope }, { filename = scope.filename }) or {}
  else
    result.checkrun_code = 0
    result.qf = {}
    result.detail = "No hay objeto SAP actual para validar checkruns; reporters sí se consultó."
  end
  return show("sap-atc-routes://remote", M._remote_validation_lines(result))
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
  lines[#lines + 1] = "w worklist · o abre quickfix · h historial · q cierra"
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
    findings = M._serialize_findings(run.qf),
  })
  local buf = show("sap-quality://" .. (run.kind or "run"), panel_lines(run))
  vim.keymap.set("n", "w", function() M.show_worklist("quickfix") end, { buffer = buf, desc = "Quality: worklist" })
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

function M._parse_atc_run_info(lines)
  local text = type(lines) == "table" and table.concat(lines, "\n") or tostring(lines or "")
  local id = text:match('worklistId="([^"]+)"')
    or text:match("<[%w_:]*worklistId[^>]*>(.-)</[%w_:]*worklistId>")
    or text:match("[Ww]orklist%s*[Ii][Dd]%s*[:=]%s*([%w_./:-]+)")
    or text:match("[Rr]un%s*[Ii][Dd]%s*[:=]%s*([%w_./:-]+)")
  local timestamp = text:match('timestamp="([^"]+)"')
    or text:match("<[%w_:]*timestamp[^>]*>(.-)</[%w_:]*timestamp>")
    or text:match("[Tt]imestamp%s*[:=]%s*([%w_./:-]+)")
  if not id or trim(id) == "" then return nil end
  return { id = trim(unxml(id)), timestamp = timestamp and trim(unxml(timestamp)) or nil }
end

local function parse_remote_worklist_args(args)
  local info = {}
  local filter
  for token in tostring(args or ""):gmatch("%S+") do
    local k, v = token:match("^([%w_%-]+)=(.+)$")
    if k then
      k = k:lower()
      if k == "id" or k == "worklist" or k == "worklistid" then info.id = trim(v)
      elseif k == "timestamp" or k == "ts" then info.timestamp = trim(v)
      elseif k == "exempted" or k == "includeexemptedfindings" then info.include_exempted = v == "true" or v == "1" or v == "yes" end
    elseif normalize_filter(token) then
      filter = normalize_filter(token)
    elseif token == "exempted" or token == "with-exempted" then
      info.include_exempted = true
    elseif not info.id then
      info.id = trim(token)
    elseif not info.timestamp then
      info.timestamp = trim(token)
    end
  end
  return info, filter
end

function M._remote_worklist_request(info)
  info = info or {}
  if not info.id or trim(info.id) == "" then return nil, "missing worklist id" end
  local query = { includeExemptedFindings = info.include_exempted and "true" or "false" }
  if info.timestamp and info.timestamp ~= "" then query.timestamp = info.timestamp end
  return {
    method = "GET",
    path = "/sap/bc/adt/atc/worklists/" .. trim(info.id),
    query = query,
    accept = "application/xml",
  }
end

function M._fetch_remote_worklist(info)
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available or not adt_http.is_available() then
    return {}, "ADT no disponible o no validado para refrescar la worklist remota.", 0
  end
  local req, err = M._remote_worklist_request(info)
  if not req then return {}, err, 0 end
  local body, _, code = adt_http.raw(req)
  if tonumber(code) == nil or code < 200 or code >= 300 then
    return {}, "Worklist remota no disponible (HTTP " .. tostring(code) .. ").", code
  end
  local qf = M._parse_atc_worklist_response(body)
  return qf, string.format("Worklist remota %s refrescada (%d hallazgo(s)).", info.id, #qf), code
end

function M.run_atc(args)
  local scope, err = parse_scope(args or "", "package")
  if not scope then return M.open_panel(err) end
  if scope.scope == "transport" then
    return M.run_transport_atc(scope.name)
  end
  local cmd = atc_command(scope)
  if not cmd then return notify("ATC no soportado para scope " .. tostring(scope.scope), vim.log.levels.WARN) end
  notify("Ejecutando ATC para " .. scope.scope .. " " .. scope.name .. "...")
  run_sapcli(cmd, function(code, stdout, stderr)
    local qf = M._parse_atc_output(stdout, { filename = scope.filename })
    local remote_info = M._parse_atc_run_info(stdout)
    local remote_detail
    if remote_info then
      local remote_qf, detail = M._fetch_remote_worklist(remote_info)
      worklist_state.remote = remote_info
      remote_detail = detail
      if #remote_qf > 0 then qf = remote_qf end
    end
    local detail = #stderr > 0 and table.concat(stderr, "\n") or (code ~= 0 and "sapcli exit " .. tostring(code) or "")
    if remote_detail and remote_detail ~= "" then
      detail = detail ~= "" and (detail .. "\n" .. remote_detail) or remote_detail
    end
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
  if not scope then return M.open_panel(err) end
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
    return M.open_panel()
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
        "%s  %-6s %-9s %-24s %-8s E:%s W:%s F:%s %s",
        e.at or "?",
        e.kind or "?",
        e.scope or "?",
        e.target or "-",
        e.status or "?",
        tostring(e.errors or 0),
        tostring(e.warnings or 0),
        tostring(type(e.findings) == "table" and #e.findings or 0),
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
  vim.api.nvim_create_user_command("SapAtcWorklist", function(args) M.show_worklist(args.args) end,
    { nargs = "*", desc = "sap-nvim: Worklist ATC desde quickfix o historial" })
  vim.api.nvim_create_user_command("SapAtcRemoteWorklist", function(args) M.show_remote_worklist(args.args) end,
    { nargs = "*", desc = "sap-nvim: Refrescar worklist ATC remota por ADT" })
  vim.api.nvim_create_user_command("SapAtcFilter", function(args) M.filter_worklist(args.args) end,
    { nargs = 1, desc = "sap-nvim: Filtrar worklist ATC por severidad y persistir filtro" })
  vim.api.nvim_create_user_command("SapAtcHelp", function(args) M.show_check_help(args.args) end,
    { nargs = "?", desc = "sap-nvim: Ayuda/documentación del hallazgo ATC seleccionado" })
  vim.api.nvim_create_user_command("SapAtcDoc", function(args) M.show_check_documentation(args.args) end,
    { nargs = "?", desc = "sap-nvim: Documentación ADT del hallazgo ATC seleccionado" })
  vim.api.nvim_create_user_command("SapAtcRoutes", function(args) M.validate_remote(args.args) end,
    { nargs = "*", desc = "sap-nvim: Validar rutas ADT de reporters/checkruns ATC" })
  vim.api.nvim_create_user_command("SapAtcRequestExemption", function(args) M.request_exemption_info(args.args) end,
    { nargs = "?", desc = "sap-nvim: Panel informativo para solicitud de exención ATC" })

  vim.keymap.set("n", "<leader>aK", function() M.run_atc("") end, { desc = "ABAP: ATC panel" })
  vim.keymap.set("n", "<leader>aqp", function() M.run("") end, { desc = "ABAP: Quality panel" })
  vim.keymap.set("n", "<leader>aqh", M.show_history, { desc = "ABAP: Historial quality" })
  vim.keymap.set("n", "<leader>aqw", function() M.show_worklist("") end, { desc = "ABAP: ATC worklist" })
end

M._history_path = history_path
M._settings_path = settings_path
M._read_history = read_history
M._read_settings = read_settings
M._record_history = record_history
M._parse_scope = parse_scope
M._parse_remote_worklist_args = parse_remote_worklist_args

return M
