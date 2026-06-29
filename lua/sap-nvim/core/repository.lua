-- sap-nvim.core.repository
-- Persistent repository explorer: packages, favorites, inactive objects and transports.

local M = {}
local index = require("sap-nvim.core.index")

local state = {
  buf = nil,
  win = nil,
  roots = {},
  sections = {},
  line_nodes = {},
  width = 42,
  last_target_win = nil,
  store_loaded = false,
}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function unxml(s)
  if not s then return s end
  return (s:gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&amp;", "&"))
end

local function xml_tag_text(block, tag)
  return block:match("<[^>]-" .. tag .. "[^>]*>(.-)</[^>]-" .. tag .. ">")
end

local function xml_attr(xml, name)
  if not xml then return nil end
  local escaped = vim.pesc(name)
  local v = xml:match(escaped .. '%s*=%s*"([^"]*)"')
  return v and unxml(v) or nil
end

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function first_nonempty(...)
  for i = 1, select("#", ...) do
    local v = trim(select(i, ...))
    if v ~= "" then return v end
  end
  return nil
end

local function boolish(v)
  v = tostring(v or ""):lower()
  return v == "true" or v == "x" or v == "yes" or v == "1"
end

local function normalize_state(v)
  v = trim(v)
  if v == "" then return nil end
  local l = v:lower()
  if l:find("inactive", 1, true) or l == "i" then return "inactive" end
  if l:find("active", 1, true) or l == "a" then return "active" end
  return v
end

local function parse_status_from_block(block)
  local status = {}
  local active = first_nonempty(
    xml_tag_text(block, "ACTIVE_STATE"),
    xml_tag_text(block, "ACTIVATION_STATE"),
    xml_tag_text(block, "OBJECT_STATE"),
    xml_tag_text(block, "STATE"),
    xml_tag_text(block, "VERSION")
  )
  if boolish(xml_tag_text(block, "IS_INACTIVE")) then active = "inactive" end
  if boolish(xml_tag_text(block, "IS_ACTIVE")) then active = active or "active" end
  status.active_state = normalize_state(unxml(active or ""))
  status.locked_by = first_nonempty(
    unxml(xml_tag_text(block, "LOCKED_BY") or ""),
    unxml(xml_tag_text(block, "LOCK_OWNER") or ""),
    unxml(xml_tag_text(block, "LOCK_USER") or "")
  )
  status.transport = first_nonempty(
    unxml(xml_tag_text(block, "TRANSPORT") or ""),
    unxml(xml_tag_text(block, "TRANSPORT_REQUEST") or ""),
    unxml(xml_tag_text(block, "CORRNR") or "")
  )
  status.owner = first_nonempty(unxml(xml_tag_text(block, "OWNER") or ""))
  status.package = first_nonempty(
    unxml(xml_tag_text(block, "DEVCLASS") or ""),
    unxml(xml_tag_text(block, "PACKAGE_NAME") or ""),
    unxml(xml_tag_text(block, "PACKAGE") or "")
  )
  return status
end

local function parse_status_from_attrs(attrs)
  local status = {}
  local active = first_nonempty(
    xml_attr(attrs, "adtcore:version"),
    xml_attr(attrs, "version"),
    xml_attr(attrs, "activationState"),
    xml_attr(attrs, "state"),
    xml_attr(attrs, "objectState")
  )
  if boolish(xml_attr(attrs, "inactive") or xml_attr(attrs, "isInactive")) then active = "inactive" end
  if boolish(xml_attr(attrs, "active") or xml_attr(attrs, "isActive")) then active = active or "active" end
  status.active_state = normalize_state(active)
  status.locked_by = first_nonempty(
    xml_attr(attrs, "adtcore:lockedBy"),
    xml_attr(attrs, "lockedBy"),
    xml_attr(attrs, "lockOwner"),
    xml_attr(attrs, "lockUser")
  )
  status.transport = first_nonempty(
    xml_attr(attrs, "adtcore:corrNr"),
    xml_attr(attrs, "corrNr"),
    xml_attr(attrs, "transport"),
    xml_attr(attrs, "transportRequest")
  )
  status.owner = first_nonempty(xml_attr(attrs, "adtcore:owner"), xml_attr(attrs, "owner"))
  status.package = first_nonempty(
    xml_attr(attrs, "adtcore:packageName"),
    xml_attr(attrs, "packageName"),
    xml_attr(attrs, "adtcore:devclass"),
    xml_attr(attrs, "devclass"),
    xml_attr(attrs, "package")
  )
  return status
end

local function merge_status(row, status)
  for k, v in pairs(status or {}) do
    if v and v ~= "" then row[k] = v end
  end
  return row
end

local function sort_nodes(nodes)
  table.sort(nodes, function(a, b)
    local ar = a.kind == "package" and 0 or 1
    local br = b.kind == "package" and 0 or 1
    if ar ~= br then return ar < br end
    return (a.name or a.label or "") < (b.name or b.label or "")
  end)
  return nodes
end

local function parse_nodestructure(body)
  local rows = {}
  if not body or body == "" then return rows end

  for block in body:gmatch("<[^>]-SEU_ADT_REPOSITORY_OBJ_NODE[^>]*>(.-)</[^>]-SEU_ADT_REPOSITORY_OBJ_NODE>") do
    local name = trim(unxml(xml_tag_text(block, "OBJECT_NAME") or ""))
    if name ~= "" then
      rows[#rows + 1] = {
        type = trim(unxml(xml_tag_text(block, "OBJECT_TYPE") or "")),
        name = name,
        uri = trim(unxml(xml_tag_text(block, "OBJECT_URI") or "")),
        description = trim(unxml(xml_tag_text(block, "DESCRIPTION") or "")),
      }
      merge_status(rows[#rows], parse_status_from_block(block))
    end
  end

  if #rows == 0 then
    for attrs in body:gmatch("<[%w_]*:?objectReference%s+([^>]*)/?>") do
      local name = first_nonempty(xml_attr(attrs, "adtcore:name"), xml_attr(attrs, "name"))
      if name and name ~= "" then
        local row = {
          type = first_nonempty(xml_attr(attrs, "adtcore:type"), xml_attr(attrs, "type")) or "",
          name = name,
          uri = first_nonempty(xml_attr(attrs, "adtcore:uri"), xml_attr(attrs, "uri"), xml_attr(attrs, "href")) or "",
          description = first_nonempty(xml_attr(attrs, "adtcore:description"), xml_attr(attrs, "description")) or "",
        }
        rows[#rows + 1] = merge_status(row, parse_status_from_attrs(attrs))
      end
    end
  end

  return rows
end

local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class",
  INTF = "interface",
  PROG = "program",
  FUGR = "functiongroup",
  FUGS = "functiongroup",
  TABL = "table",
  VIEW = "table",
  TTYP = "tabletype",
  DTEL = "dataelement",
  DOMA = "domain",
  DDLS = "ddls",
  DDLX = "ddlx",
  DCLS = "dcl",
  BDEF = "bdef",
  SRVD = "srvd",
  MSAG = "messageclass",
  TRAN = "transaction",
  DEVC = "package",
}

local function group_from_type(adt_type)
  local ok, adt = pcall(require, "sap-nvim.core.adt")
  if ok and adt.group_from_adt_type then
    local group = adt.group_from_adt_type(adt_type)
    if group then return group end
  end
  local prefix, sub = tostring(adt_type or ""):match("(%u+)/(%u+)")
  prefix = prefix or tostring(adt_type or ""):match("^(%u+)")
  if prefix == "PROG" and sub == "I" then return "include" end
  return TYPE_PREFIX_TO_GROUP[prefix or ""]
end

local EXPANDABLE_GROUPS = {
  class = true,
  interface = true,
  program = true,
  functiongroup = true,
  table = true,
  structure = true,
  ddls = true,
  ddl = true,
}

local function child_kind_from_type(typ, group)
  typ = tostring(typ or ""):upper()
  if group then return "object" end
  if typ:find("METH", 1, true) or typ:match("/OM$") then return "method" end
  if typ:find("FIELD", 1, true) or typ:find("COMP", 1, true) or typ:match("/DF$") then return "field" end
  if typ:find("INCL", 1, true) then return "include" end
  return "member"
end

local function member_kind_from_type(typ)
  local kind = child_kind_from_type(typ, nil)
  if kind == "method" or kind == "field" then return kind end
  return nil
end

local function package_node(name, extra)
  extra = extra or {}
  return vim.tbl_extend("force", {
    kind = "package",
    type = "DEVC/K",
    name = trim(name):upper(),
    label = trim(name):upper(),
    expanded = false,
    loaded = false,
    children = {},
  }, extra)
end

local function object_node(row, extra)
  extra = extra or {}
  local member_kind = member_kind_from_type(row.type)
  local group = extra.group or row.group or (not member_kind and group_from_type(row.type) or nil)
  local kind = group == "package" and "package" or "object"
  local expandable = kind == "package" or (EXPANDABLE_GROUPS[group] and extra.expandable ~= false)
  local node = {
    kind = kind,
    type = row.type or "",
    group = group,
    name = trim(row.name):upper(),
    label = trim(row.name):upper(),
    uri = row.uri or "",
    description = row.description or "",
    active_state = row.active_state,
    locked_by = row.locked_by,
    transport = row.transport,
    owner = row.owner,
    package = row.package,
    expanded = false,
    loaded = kind ~= "package" and not expandable,
    children = expandable and {} or nil,
  }
  node.member_kind = member_kind or child_kind_from_type(row.type, group)
  for k, v in pairs(extra) do node[k] = v end
  return node
end

local function row_to_node(row)
  if group_from_type(row.type) == "package" then
    return package_node(row.name, {
      uri = row.uri or "",
      description = row.description or "",
      active_state = row.active_state,
      locked_by = row.locked_by,
      transport = row.transport,
      owner = row.owner,
      package = row.package,
      loaded = false,
      expanded = false,
      children = {},
    })
  end
  return object_node(row)
end

local function nodes_from_rows(rows)
  local out = {}
  for _, row in ipairs(rows or {}) do
    if row.name and row.name ~= "" then out[#out + 1] = row_to_node(row) end
  end
  return sort_nodes(out)
end

local function split_cols(line)
  local cols = {}
  for c in (line .. "|"):gmatch("%s*(.-)%s*|") do cols[#cols + 1] = c end
  return cols
end

local function parse_sapcli_package_lines(lines)
  local rows = {}
  for _, raw in ipairs(lines or {}) do
    local line = trim(raw)
    if line ~= "" and not line:match("^[-|%s]+$") and not line:find("Object type", 1, true) then
      local typ, name, desc
      if line:find("|", 1, true) then
        local cols = split_cols(line)
        typ, name, desc = cols[1], cols[2], cols[3]
      else
        typ, name, desc = line:match("^(%S+)%s+(%S+)%s*(.*)$")
      end
      if name and name ~= "" and name ~= "Name" then
        rows[#rows + 1] = {
          type = trim(typ),
          name = trim(name),
          description = trim(desc),
        }
      end
    end
  end
  return rows
end

local function parse_transport_line(line)
  line = trim(line)
  local id = line:match("%u%u%uK%d+") or line:match("^([%w_%-]+)")
  local rest = id and trim(line:gsub("^" .. vim.pesc(id), "", 1)) or line
  local owner = rest:match("%(([^%)]+)%)%s*$")
  if owner then rest = trim(rest:gsub("%s*%([^%)]+%)%s*$", "")) end
  local status = rest:match("^%[([^%]]+)%]")
  if status then rest = trim(rest:gsub("^%[[^%]]+%]", "", 1)) end
  return { id = id or line, description = rest, owner = owner, status = status, raw = line }
end

local function data_dir()
  local dir = vim.fn.stdpath("data") .. "/sap-nvim"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function repository_store_path()
  return data_dir() .. "/repository.json"
end

local function favorite_store_path()
  return data_dir() .. "/favorites.json"
end

local function load_favorites()
  local f = io.open(favorite_store_path(), "r")
  if not f then return {} end
  local txt = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, txt)
  if not ok or type(data) ~= "table" then return {} end
  if type(data.favorites) == "table" then return data.favorites end
  return data
end

local function save_favorites(list)
  local f = io.open(favorite_store_path(), "w")
  if not f then return false end
  f:write(vim.json.encode(list or {}))
  f:close()
  return true
end

local function load_repository_store()
  local f = io.open(repository_store_path(), "r")
  if not f then return { roots = {} } end
  local txt = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, txt)
  if not ok or type(data) ~= "table" then return { roots = {} } end
  if type(data.roots) ~= "table" then data.roots = {} end
  return data
end

local function save_roots()
  local roots = {}
  for _, root in ipairs(state.roots) do
    if root.name and root.name ~= "" then roots[#roots + 1] = root.name end
  end
  local f = io.open(repository_store_path(), "w")
  if not f then return false end
  f:write(vim.json.encode({ roots = roots }))
  f:close()
  return true
end

local function ensure_store_loaded()
  if state.store_loaded then return end
  state.store_loaded = true
  for _, pkg in ipairs(load_repository_store().roots or {}) do
    pkg = trim(pkg):upper()
    if pkg ~= "" then
      local exists = false
      for _, root in ipairs(state.roots) do
        if root.name == pkg then exists = true; break end
      end
      if not exists then state.roots[#state.roots + 1] = package_node(pkg) end
    end
  end
end

local function add_root(pkg, opts)
  opts = opts or {}
  pkg = trim(pkg):upper()
  if pkg == "" then return false end
  for _, root in ipairs(state.roots) do
    if root.name == pkg then return false end
  end
  state.roots[#state.roots + 1] = package_node(pkg)
  if opts.persist then save_roots() end
  return true
end

local function current_package()
  local meta = vim.b[vim.api.nvim_get_current_buf()].sap_obj
  return meta and meta.package or nil
end

local function ensure_initial_roots(pkg)
  ensure_store_loaded()
  if pkg and pkg ~= "" then add_root(pkg, { persist = true }) end
  if #state.roots == 0 then
    local cur = current_package()
    if cur and cur ~= "" then add_root(cur) end
  end
  if #state.roots == 0 then
    local ok, cfg = pcall(function() return require("sap-nvim.core.config").new() end)
    if ok and cfg and cfg.package then add_root(cfg.package) end
  end
end

local function section_node(id, label, children)
  return {
    id = id,
    kind = "section",
    label = label,
    expanded = true,
    loaded = true,
    children = children or {},
  }
end

local function rebuild_sections()
  state.sections = {
    section_node("packages", "Packages", state.roots),
    section_node("favorites", "Favorites", {}),
    section_node("inactive", "Inactive Objects", {}),
    section_node("transports", "Transports", {}),
  }
end

local function section_by_id(id)
  for _, node in ipairs(state.sections) do
    if node.id == id then return node end
  end
  return nil
end

local function icon(node)
  if node.loading then return "..." end
  if node.error then return "!" end
  if node.kind == "section" or node.kind == "package" then
    return node.expanded and "v" or ">"
  end
  if node.children then return node.expanded and "v" or ">" end
  if node.kind == "favorite" then return "*" end
  if node.kind == "inactive" then return "!" end
  if node.kind == "transport" then return "#" end
  if node.kind == "method" then return "m" end
  if node.kind == "field" then return "." end
  return "-"
end

local function status_badges(node)
  local out = {}
  if node.active_state and node.active_state ~= "" and node.active_state ~= "active" then
    out[#out + 1] = node.active_state
  end
  if node.locked_by and node.locked_by ~= "" then out[#out + 1] = "lock:" .. node.locked_by end
  if node.transport and node.transport ~= "" then out[#out + 1] = node.transport end
  if node.index_source then
    out[#out + 1] = node.index_stale and "index:old" or "index"
  end
  if #out == 0 then return "" end
  return " {" .. table.concat(out, " ") .. "}"
end

local function node_text(node)
  if node.kind == "section" then
    local count = node.children and #node.children or 0
    return string.format("%s (%d)", node.label, count)
  end
  if node.kind == "package" then
    local text = node.description and node.description ~= "" and (node.name .. "  " .. node.description) or node.name
    return text .. status_badges(node)
  end
  if node.kind == "transport" then
    local parts = { node.id or node.label }
    if node.status and node.status ~= "" then parts[#parts + 1] = "[" .. node.status .. "]" end
    if node.owner and node.owner ~= "" then parts[#parts + 1] = "(" .. node.owner .. ")" end
    if node.description and node.description ~= "" then parts[#parts + 1] = node.description end
    return table.concat(parts, " ")
  end
  local group_label = node.group or node.member_kind
  local suffix = group_label and (" [" .. group_label .. "]") or (node.type and node.type ~= "" and (" [" .. node.type .. "]") or "")
  if node.description and node.description ~= "" then
    return node.name .. suffix .. status_badges(node) .. "  " .. node.description
  end
  return (node.name or node.label or "?") .. suffix .. status_badges(node)
end

local function collect_lines(nodes, depth, lines)
  lines = lines or {}
  for _, node in ipairs(nodes or {}) do
    lines[#lines + 1] = string.rep("  ", depth) .. icon(node) .. " " .. node_text(node)
    state.line_nodes[#lines] = node
    if node.error then
      lines[#lines + 1] = string.rep("  ", depth + 1) .. node.error
      state.line_nodes[#lines] = node
    end
    if node.expanded and node.children then
      if node.loading and #node.children == 0 then
        lines[#lines + 1] = string.rep("  ", depth + 1) .. "loading..."
        state.line_nodes[#lines] = node
      elseif node.loaded and #node.children == 0 then
        lines[#lines + 1] = string.rep("  ", depth + 1) .. "(empty)"
        state.line_nodes[#lines] = node
      else
        collect_lines(node.children, depth + 1, lines)
      end
    end
  end
  return lines
end

local function is_valid_buf(buf)
  return buf and vim.api.nvim_buf_is_valid(buf)
end

local function is_valid_win(win)
  return win and vim.api.nvim_win_is_valid(win)
end

local function render()
  if not is_valid_buf(state.buf) then return end
  state.line_nodes = {}
  local lines = { "SAP Repository", "" }
  state.line_nodes[1] = nil
  state.line_nodes[2] = nil
  collect_lines(state.sections, 0, lines)
  if #state.roots == 0 then
    lines[#lines + 1] = ""
    lines[#lines + 1] = "Press a to add a package root."
  end
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, lines)
  vim.bo[state.buf].modifiable = false
end

local function ensure_panel()
  if is_valid_buf(state.buf) and is_valid_win(state.win) then
    return
  end
  local curwin = vim.api.nvim_get_current_win()
  if curwin ~= state.win then
    state.last_target_win = curwin
  end
  if not is_valid_buf(state.buf) then
    state.buf = vim.api.nvim_create_buf(false, true)
    vim.bo[state.buf].buftype = "nofile"
    vim.bo[state.buf].bufhidden = "hide"
    vim.bo[state.buf].swapfile = false
    vim.bo[state.buf].filetype = "saprepository"
    pcall(vim.api.nvim_buf_set_name, state.buf, "sap://repository")
  end
  vim.cmd("topleft vertical " .. tostring(state.width) .. "new")
  state.win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(state.win, state.buf)
  pcall(vim.api.nvim_win_set_width, state.win, state.width)
end

local function remember_target_window()
  local win = vim.api.nvim_get_current_win()
  if win ~= state.win then state.last_target_win = win end
end

local function goto_target_window()
  if is_valid_win(state.last_target_win) then
    vim.api.nvim_set_current_win(state.last_target_win)
    return true
  end
  for _, win in ipairs(vim.api.nvim_list_wins()) do
    if win ~= state.win then
      state.last_target_win = win
      vim.api.nvim_set_current_win(win)
      return true
    end
  end
  return false
end

local function selected_node()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  return state.line_nodes[line]
end

local function fetch_package_sapcli(pkg, cb)
  local ok_sapcli, sapcli = pcall(require, "sap-nvim.core.sapcli")
  if not ok_sapcli then cb(nil, "sapcli no disponible"); return end
  local stdout, stderr = {}, {}
  sapcli.jobstart({ "sapcli", "package", "list", "-l", pkg }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data or {}) do
        if trim(line) ~= "" then stdout[#stdout + 1] = line end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data or {}) do
        if trim(line) ~= "" then stderr[#stderr + 1] = trim(line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          cb(nil, stderr[1] or ("No se pudo leer paquete " .. pkg))
          return
        end
        cb(parse_sapcli_package_lines(stdout), nil)
      end)
    end,
  })
end

local function fetch_package(pkg, cb)
  local cached = index.repository_rows(pkg, { limit = 1000 })
  if #cached > 0 then
    local stale = index.is_stale()
    cb(cached, nil, { source = "index", stale = stale })
    return
  end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if ok_http and adt_http.is_available() then
    adt_http.request_async({
      method = "POST",
      path = "/sap/bc/adt/repository/nodestructure",
      query = {
        parent_type = "DEVC/K",
        parent_name = pkg,
        withShortDescriptions = "true",
      },
      accept = "application/xml",
      content_type = "application/xml",
    }, function(body)
      vim.schedule(function()
        local rows = parse_nodestructure(body)
        if #rows > 0 then cb(rows, nil) else fetch_package_sapcli(pkg, cb) end
      end)
    end)
    return
  end
  fetch_package_sapcli(pkg, cb)
end

local function object_reference_body(node)
  if not node or not node.uri or node.uri == "" then return nil end
  local typ = node.type and node.type ~= "" and node.type or "DEVC/K"
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<tre:node xmlns:tre="http://www.sap.com/adt/core/tree" xmlns:adtcore="http://www.sap.com/adt/core">',
    '<tre:objectReference adtcore:uri="' .. node.uri:gsub("&", "&amp;"):gsub('"', "&quot;") .. '"',
    ' adtcore:name="' .. node.name:gsub("&", "&amp;"):gsub('"', "&quot;") .. '"',
    ' adtcore:type="' .. typ:gsub("&", "&amp;"):gsub('"', "&quot;") .. '"/>',
    '</tre:node>',
  }, "")
end

local function fetch_object_children(node, cb)
  if not node or not node.type or node.type == "" then cb({}, nil); return end
  local cached = index.repository_rows(node.name, { limit = 1000 })
  if #cached > 0 then
    local stale = index.is_stale()
    cb(cached, nil, { source = "index", stale = stale })
    return
  end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available() then cb({}, "ADT no disponible"); return end
  adt_http.request_async({
    method = "POST",
    path = "/sap/bc/adt/repository/nodestructure",
    query = {
      parent_type = node.type,
      parent_name = node.name,
      withShortDescriptions = "true",
    },
    accept = "application/xml",
    content_type = "application/xml",
    body = object_reference_body(node),
  }, function(body)
    vim.schedule(function()
      cb(parse_nodestructure(body), nil)
    end)
  end)
end

local function load_package(node, force)
  if not node or node.kind ~= "package" then return end
  if node.loaded and not force then return end
  node.loading, node.error, node.loaded = true, nil, false
  render()
  fetch_package(node.name, function(rows, err, meta)
    node.loading = false
    if err then
      node.error = err
      node.children = {}
      node.loaded = true
      render()
      return
    end
    for _, row in ipairs(rows or {}) do
      row.package = row.package or node.name
    end
    node.children = nodes_from_rows(rows)
    node.index_source = meta and meta.source == "index"
    node.index_stale = meta and meta.stale or nil
    node.loaded = true
    node.error = nil
    render()
  end)
end

local function load_object_children(node, force)
  if not node or not node.children then return end
  if node.loaded and not force then return end
  node.loading, node.error, node.loaded = true, nil, false
  render()
  fetch_object_children(node, function(rows, err, meta)
    node.loading = false
    if err then
      node.error = err
      node.children = {}
      node.loaded = true
      render()
      return
    end
    node.index_source = meta and meta.source == "index"
    node.index_stale = meta and meta.stale or nil
    node.children = {}
    for _, child in ipairs(nodes_from_rows(rows)) do
      child.parent = node
      child.package = child.package or node.package
      if not child.group then
        child.kind = child.member_kind or "member"
        child.loaded = true
        child.children = nil
      end
      node.children[#node.children + 1] = child
    end
    node.loaded = true
    node.error = nil
    render()
  end)
end

local function refresh_favorites()
  local sec = section_by_id("favorites")
  if not sec then return end
  sec.children = {}
  for _, fav in ipairs(load_favorites()) do
    local name = fav.name or fav.object or fav.label
    if name and name ~= "" then
      sec.children[#sec.children + 1] = object_node({
        name = name,
        type = fav.type or "",
        description = fav.description or "",
        uri = fav.uri or "",
      }, {
        kind = "favorite",
        group = fav.group,
        active_state = fav.active_state,
        locked_by = fav.locked_by,
        transport = fav.transport,
        expandable = false,
        loaded = true,
      })
    end
  end
  sec.loaded = true
end

local function refresh_inactive()
  local sec = section_by_id("inactive")
  if not sec then return end
  local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
  if not ok_adt or not adt.is_configured() then
    sec.children, sec.loaded, sec.error = {}, true, "No SAP connection. Run :SapLogin."
    render()
    return
  end
  sec.loading, sec.error = true, nil
  render()
  adt.fetch_inactive_objects(function(objects, err)
    vim.schedule(function()
      sec.loading = false
      sec.loaded = true
      sec.children = {}
      if err then
        sec.error = err
      else
        for _, obj in ipairs(objects or {}) do
          sec.children[#sec.children + 1] = object_node({
            name = obj.name or "",
            type = obj.type or "",
            uri = obj.uri or "",
            description = obj.description or "",
          }, {
            kind = "inactive",
            group = obj.group or group_from_type(obj.type),
            raw = obj,
            expandable = false,
            loaded = true,
          })
        end
        sort_nodes(sec.children)
      end
      render()
    end)
  end)
end

local function refresh_transports()
  local sec = section_by_id("transports")
  if not sec then return end
  local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
  if not ok_adt or not adt.is_configured() then
    sec.children, sec.loaded, sec.error = {}, true, "No SAP connection. Run :SapLogin."
    render()
    return
  end
  sec.loading, sec.error = true, nil
  render()
  adt.fetch_transport_orders(function(lines, err)
    vim.schedule(function()
      sec.loading = false
      sec.loaded = true
      sec.children = {}
      if err then
        sec.error = err
      else
        for _, line in ipairs(lines or {}) do
          local tr = parse_transport_line(line)
          sec.children[#sec.children + 1] = {
            kind = "transport",
            id = tr.id,
            label = tr.id,
            description = tr.description,
            owner = tr.owner,
            status = tr.status,
            raw = tr.raw,
            loaded = true,
          }
        end
      end
      render()
    end)
  end)
end

local function refresh_section(node)
  if node.id == "favorites" then
    refresh_favorites()
    render()
  elseif node.id == "inactive" then
    refresh_inactive()
  elseif node.id == "transports" then
    refresh_transports()
  elseif node.id == "packages" then
    for _, root in ipairs(state.roots) do load_package(root, true) end
    render()
  end
end

function M.refresh_all()
  if #state.sections == 0 then rebuild_sections() end
  refresh_favorites()
  render()
  refresh_inactive()
  refresh_transports()
end

local function toggle_node(node, force)
  if not node then return end
  if node.kind == "section" then
    node.expanded = force ~= nil and force or not node.expanded
    if node.expanded then refresh_section(node) end
    render()
    return
  end
  if node.kind == "package" then
    node.expanded = force ~= nil and force or not node.expanded
    if node.expanded then load_package(node, false) end
    render()
    return
  end
  if node.children then
    node.expanded = force ~= nil and force or not node.expanded
    if node.expanded then load_object_children(node, false) end
    render()
    return
  end
end

local function open_node(node)
  if not node then return end
  if node.kind == "section" or node.kind == "package" then
    toggle_node(node)
    return
  end
  if node.kind == "transport" then
    if node.id then
      pcall(vim.fn.setreg, "+", node.id)
      notify("Transport copied: " .. node.id)
    end
    return
  end
  if not node.group then
    if node.parent and node.parent.group then
      goto_target_window()
      require("sap-nvim.core.source").open(node.parent.name, node.parent.group, {
        uri = node.parent.uri,
        package = node.parent.package,
      })
      return
    end
    notify("Nodo no abrible: " .. (node.type or node.kind or "?"), vim.log.levels.WARN)
    return
  end
  goto_target_window()
  require("sap-nvim.core.source").open(node.name, node.group, { uri = node.uri, package = node.package })
end

local function refresh_node(node)
  if not node then return M.refresh_all() end
  if node.kind == "section" then refresh_section(node); return end
  if node.kind == "package" then
    node.expanded = true
    load_package(node, true)
    return
  end
  if node.children then
    node.expanded = true
    load_object_children(node, true)
    return
  end
  if node.kind == "favorite" then refresh_favorites(); render(); return end
  if node.kind == "inactive" then refresh_inactive(); return end
  if node.kind == "transport" then refresh_transports(); return end
end

local function add_package_prompt()
  vim.ui.input({ prompt = "Package root: ", default = "Z" }, function(pkg)
    if pkg and add_root(pkg, { persist = true }) then
      rebuild_sections()
      refresh_favorites()
      render()
    end
  end)
end

local function add_selected_to_favorites()
  local node = selected_node()
  if not node or not node.name or not node.group or node.kind == "package" then return end
  local list = load_favorites()
  local found = false
  for _, fav in ipairs(list) do
    if fav.name == node.name and fav.group == node.group then
      found = true
      fav.type = node.type or fav.type
      fav.uri = node.uri or fav.uri
      fav.description = node.description or fav.description
      fav.active_state = node.active_state or fav.active_state
      fav.locked_by = node.locked_by or fav.locked_by
      fav.transport = node.transport or fav.transport
      break
    end
  end
  if not found then
    list[#list + 1] = {
      name = node.name,
      group = node.group,
      type = node.type,
      uri = node.uri,
      description = node.description,
      active_state = node.active_state,
      locked_by = node.locked_by,
      transport = node.transport,
    }
  end
  save_favorites(list)
  notify("Favorite saved: " .. node.name)
  refresh_favorites()
  render()
end

local function setup_buffer_maps()
  if not is_valid_buf(state.buf) then return end
  local opts = { buffer = state.buf, silent = true, nowait = true }
  vim.keymap.set("n", "<cr>", function() open_node(selected_node()) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: open/toggle" }))
  vim.keymap.set("n", "o", function() open_node(selected_node()) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: open" }))
  vim.keymap.set("n", "l", function() toggle_node(selected_node(), true) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: expand" }))
  vim.keymap.set("n", "h", function() toggle_node(selected_node(), false) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: collapse" }))
  vim.keymap.set("n", "<tab>", function() toggle_node(selected_node()) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: toggle expand" }))
  vim.keymap.set("n", "r", function() refresh_node(selected_node()) end, vim.tbl_extend("force", opts, { desc = "SAP Repository: refresh node" }))
  vim.keymap.set("n", "R", M.refresh_all, vim.tbl_extend("force", opts, { desc = "SAP Repository: refresh all" }))
  vim.keymap.set("n", "a", add_package_prompt, vim.tbl_extend("force", opts, { desc = "SAP Repository: add package root" }))
  vim.keymap.set("n", "f", add_selected_to_favorites, vim.tbl_extend("force", opts, { desc = "SAP Repository: favorite object" }))
  vim.keymap.set("n", "q", function()
    if is_valid_win(state.win) then vim.api.nvim_win_close(state.win, true) end
  end, vim.tbl_extend("force", opts, { desc = "SAP Repository: close" }))
end

function M.open(pkg)
  remember_target_window()
  ensure_initial_roots(pkg)
  rebuild_sections()
  refresh_favorites()
  ensure_panel()
  setup_buffer_maps()
  render()
end

function M.toggle(pkg)
  if is_valid_win(state.win) then
    vim.api.nvim_win_close(state.win, true)
    return
  end
  M.open(pkg)
end

function M.add_package(pkg)
  if pkg and pkg ~= "" then
    if add_root(pkg, { persist = true }) then
      rebuild_sections()
      refresh_favorites()
      render()
    end
    return
  end
  add_package_prompt()
end

function M.setup(opts)
  opts = opts or {}
  local repo_opts = opts.repository or {}
  state.width = tonumber(repo_opts.width) or state.width
  ensure_store_loaded()
  for _, pkg in ipairs(repo_opts.roots or {}) do add_root(pkg) end

  vim.api.nvim_create_user_command("SapRepository", function(args)
    M.open(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "sap-nvim: Open persistent SAP Repository Explorer" })

  vim.api.nvim_create_user_command("SapRepositoryToggle", function(args)
    M.toggle(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "sap-nvim: Toggle SAP Repository Explorer" })

  vim.api.nvim_create_user_command("SapRepositoryRefresh", function()
    M.refresh_all()
  end, { desc = "sap-nvim: Refresh SAP Repository Explorer" })

  vim.api.nvim_create_user_command("SapRepositoryAdd", function(args)
    M.add_package(args.args ~= "" and args.args or nil)
  end, { nargs = "?", desc = "sap-nvim: Add package root to Repository Explorer" })

  vim.keymap.set("n", "<leader>afr", function() M.toggle() end, { desc = "ABAP: Repository Explorer" })
end

M._parse_nodestructure = parse_nodestructure
M._parse_sapcli_package_lines = parse_sapcli_package_lines
M._parse_transport_line = parse_transport_line
M._nodes_from_rows = nodes_from_rows
M._status_badges = status_badges
M._load_repository_store = load_repository_store

return M
