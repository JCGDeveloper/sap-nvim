-- sap-nvim.core.index
-- Persistent, read-only local index for SAP ADT objects and repository members.

local M = {}

local SCHEMA_VERSION = 1
local DEFAULT_PATTERNS = { "Z*", "Y*" }
local DEFAULT_MAX_RESULTS = 500
local DEFAULT_STALE_AFTER_SECONDS = 7 * 24 * 60 * 60

local state = {
  opts = {},
  loaded = false,
  cache = nil,
}

local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class",
  INTF = "interface",
  PROG = "program",
  FUGR = "functiongroup",
  FUGS = "functiongroup",
  FUNC = "functionmodule",
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
  SRVB = "srvb",
  MSAG = "messageclass",
  TRAN = "transaction",
  DEVC = "package",
}

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

local function notify(msg, level)
  vim.notify("[sap-nvim index] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function upper(s)
  return trim(s):upper()
end

local function unxml(s)
  if not s then return s end
  return (s:gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&#x0A;", "\n")
    :gsub("&#x0D;", "\r")
    :gsub("&#10;", "\n")
    :gsub("&#13;", "\r")
    :gsub("&amp;", "&"))
end

local function xmlesc(s)
  return (tostring(s or ""))
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
end

local function xml_tag_text(block, tag)
  return block and block:match("<[^>]-" .. tag .. "[^>]*>(.-)</[^>]-" .. tag .. ">") or nil
end

local function xml_attr(attrs, name)
  if not attrs then return nil end
  local escaped = vim.pesc(name)
  local v = attrs:match(escaped .. '%s*=%s*"([^"]*)"')
  if not v then
    local bare = name:match("([^:]+)$") or name
    v = attrs:match("[%w_:-]*" .. vim.pesc(bare) .. '%s*=%s*"([^"]*)"')
  end
  return v and unxml(v) or nil
end

local function first_nonempty(...)
  for i = 1, select("#", ...) do
    local v = trim(select(i, ...))
    if v ~= "" then return v end
  end
  return nil
end

local function url_encode(str)
  return (tostring(str or ""):gsub("[^%w_%-%.%*]", function(c)
    return string.format("%%%02X", string.byte(c))
  end))
end

local function index_dir()
  local ok, base = pcall(vim.fn.stdpath, "state")
  if not ok then base = nil end
  if not base or base == "" then base = vim.fn.stdpath("data") end
  local dir = base .. "/sap-nvim"
  vim.fn.mkdir(dir, "p")
  return dir
end

local function index_path()
  return index_dir() .. "/index.json"
end

local function empty_cache()
  return {
    schema = SCHEMA_VERSION,
    generated_at = nil,
    sources = {},
    entries = {},
  }
end

local function group_from_type(adt_type)
  local ok, adt = pcall(require, "sap-nvim.core.adt")
  if ok and adt.group_from_adt_type then
    local group = adt.group_from_adt_type(adt_type)
    if group then return group end
  end
  local prefix, sub = tostring(adt_type or ""):match("(%u+)/([%w_]+)")
  prefix = prefix or tostring(adt_type or ""):match("^(%u+)")
  if prefix == "PROG" and sub == "I" then return "include" end
  if prefix == "TABL" and sub == "DS" then return "structure" end
  return TYPE_PREFIX_TO_GROUP[prefix or ""]
end

local function member_kind_from_type(adt_type)
  local typ = tostring(adt_type or ""):upper()
  if typ:find("METH", 1, true) or typ:match("/OM$") or typ:match("/IM$") then return "method" end
  if typ:find("FIELD", 1, true) or typ:find("COMP", 1, true) or typ:match("/DF$") then return "field" end
  return nil
end

local function kind_for(row)
  local member_kind = member_kind_from_type(row.type or row.adt_type)
  if member_kind then return member_kind end
  local group = row.group or group_from_type(row.type or row.adt_type)
  if group == "package" then return "package" end
  return "object"
end

local function stable_key(entry)
  if entry.uri and entry.uri ~= "" then
    return entry.uri:lower():gsub("%?.*$", ""):gsub("#.*$", ""):gsub("/source/main$", "")
  end
  return table.concat({
    entry.kind or "?",
    entry.parent_type or "",
    entry.parent or "",
    entry.type or "",
    entry.name or "",
  }, "|"):lower()
end

local function normalize_entry(row, extra)
  extra = extra or {}
  local name = upper(row.name)
  if name == "" then return nil end
  local typ = trim(row.type or row.adt_type)
  local group = row.group or group_from_type(typ)
  local entry = {
    name = name,
    type = typ,
    group = group,
    kind = row.kind or kind_for({ type = typ, group = group }),
    uri = trim(row.uri),
    description = trim(row.description or row.desc),
    package = upper(row.package),
    parent = upper(row.parent or extra.parent),
    parent_type = trim(row.parent_type or extra.parent_type),
    source = row.source or extra.source,
    updated_at = row.updated_at or os.time(),
  }
  if entry.package == "" then entry.package = nil end
  if entry.parent == "" then entry.parent = nil end
  if entry.parent_type == "" then entry.parent_type = nil end
  if entry.source == "" then entry.source = nil end
  entry.key = stable_key(entry)
  return entry
end

local function normalize_entries(rows, extra)
  local out = {}
  for _, row in ipairs(rows or {}) do
    local entry = normalize_entry(row, extra)
    if entry then out[#out + 1] = entry end
  end
  return out
end

local function read_json(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local txt = f:read("*a")
  f:close()
  local ok, data = pcall(vim.json.decode, txt)
  if ok and type(data) == "table" then return data end
  return nil
end

local function write_json(path, data)
  local f = io.open(path, "w")
  if not f then return false end
  f:write(vim.json.encode(data or empty_cache()))
  f:close()
  return true
end

local function ensure_loaded()
  if state.loaded then return state.cache end
  local data = read_json(index_path()) or empty_cache()
  if type(data.entries) ~= "table" then data.entries = {} end
  if type(data.sources) ~= "table" then data.sources = {} end
  state.cache = data
  state.loaded = true
  return state.cache
end

function M.load()
  state.loaded = false
  return ensure_loaded()
end

function M.save(cache)
  cache = cache or ensure_loaded()
  cache.schema = SCHEMA_VERSION
  state.cache = cache
  state.loaded = true
  return write_json(index_path(), cache)
end

function M.path()
  return index_path()
end

local function merge_entries(cache, entries, source)
  local by_key = {}
  for i, entry in ipairs(cache.entries or {}) do
    entry.key = entry.key or stable_key(entry)
    by_key[entry.key] = i
  end
  local added, updated = 0, 0
  for _, entry in ipairs(entries or {}) do
    entry.key = entry.key or stable_key(entry)
    if by_key[entry.key] then
      cache.entries[by_key[entry.key]] = vim.tbl_extend("force", cache.entries[by_key[entry.key]], entry)
      updated = updated + 1
    else
      cache.entries[#cache.entries + 1] = entry
      by_key[entry.key] = #cache.entries
      added = added + 1
    end
  end
  if source and source ~= "" then
    cache.sources[source] = { refreshed_at = os.time(), count = #entries }
  end
  cache.generated_at = os.time()
  return added, updated
end

function M.add_entries(rows, opts)
  opts = opts or {}
  local cache = ensure_loaded()
  local entries = normalize_entries(rows, opts)
  local added, updated = merge_entries(cache, entries, opts.source)
  if opts.save ~= false then M.save(cache) end
  return { added = added, updated = updated, total = #cache.entries, entries = entries }
end

function M.clear()
  state.cache = empty_cache()
  state.loaded = true
  pcall(os.remove, index_path())
  return true
end

local function cache_age(cache)
  if not cache.generated_at then return nil end
  return math.max(0, os.time() - tonumber(cache.generated_at))
end

local function stale_after_seconds()
  return tonumber(state.opts.stale_after_seconds or state.opts.max_age_seconds) or DEFAULT_STALE_AFTER_SECONDS
end

local function stale_info(cache)
  local age = cache_age(cache)
  if not age then return true, "never", nil end
  local max_age = stale_after_seconds()
  if max_age > 0 and age > max_age then return true, "old", age end
  return false, nil, age
end

function M.status()
  local cache = ensure_loaded()
  local counts = { total = 0, object = 0, field = 0, method = 0, package = 0 }
  for _, entry in ipairs(cache.entries or {}) do
    counts.total = counts.total + 1
    local kind = entry.kind or "object"
    counts[kind] = (counts[kind] or 0) + 1
  end
  return {
    path = index_path(),
    generated_at = cache.generated_at,
    age_seconds = cache_age(cache),
    counts = counts,
      sources = cache.sources or {},
    stale = select(1, stale_info(cache)),
    stale_reason = select(2, stale_info(cache)),
    stale_after_seconds = stale_after_seconds(),
  }
end

function M.is_stale()
  local cache = ensure_loaded()
  return stale_info(cache)
end

function M.has_entries(opts)
  opts = opts or {}
  local cache = ensure_loaded()
  if not opts.kind and not opts.parent then
    return #(cache.entries or {}) > 0
  end
  for _, entry in ipairs(cache.entries or {}) do
    if (not opts.kind or entry.kind == opts.kind) and (not opts.parent or upper(entry.parent) == upper(opts.parent)) then
      return true
    end
  end
  return false
end

local function parse_search_body(body)
  local results, seen = {}, {}
  if not body or body == "" then return results end

  for tag in body:gmatch("<[^>]+>") do
    local name = xml_attr(tag, "adtcore:name") or xml_attr(tag, "name")
    local typ = xml_attr(tag, "adtcore:type") or xml_attr(tag, "type")
    if name and typ then
      local uri = xml_attr(tag, "adtcore:uri") or xml_attr(tag, "uri") or xml_attr(tag, "href") or ""
      local key = (uri ~= "" and uri or (typ .. "|" .. name)):lower()
      if not seen[key] then
        seen[key] = true
        results[#results + 1] = {
          name = name,
          type = typ,
          uri = uri,
          description = xml_attr(tag, "adtcore:description") or xml_attr(tag, "description") or "",
          package = xml_attr(tag, "adtcore:packageName") or xml_attr(tag, "packageName") or "",
          source = "search",
        }
      end
    end
  end

  if #results == 0 then
    for entry in body:gmatch("<[a-zA-Z0-9:]*entry>(.-)</[a-zA-Z0-9:]*entry>") do
      local name = unxml(entry:match("<[a-zA-Z0-9:]*title[^>]*>([^<]*)</") or "")
      local typ = unxml(entry:match('term="([^"]*)"') or "")
      if name ~= "" and typ ~= "" then
        results[#results + 1] = {
          name = name,
          type = typ,
          uri = unxml(entry:match('href="([^"]*)"') or ""),
          description = unxml(entry:match("<[a-zA-Z0-9:]*summary[^>]*>([^<]*)</") or ""),
          source = "search",
        }
      end
    end
  end

  return normalize_entries(results, { source = "search" })
end

local function parse_nodestructure(body, parent)
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
        parent = parent and parent.name or nil,
        parent_type = parent and parent.type or nil,
        source = "repository",
      }
    end
  end

  if #rows == 0 then
    for attrs in body:gmatch("<[%w_]*:?objectReference%s+([^>]*)/?>") do
      local name = first_nonempty(xml_attr(attrs, "adtcore:name"), xml_attr(attrs, "name"))
      if name then
        rows[#rows + 1] = {
          type = first_nonempty(xml_attr(attrs, "adtcore:type"), xml_attr(attrs, "type")) or "",
          name = name,
          uri = first_nonempty(xml_attr(attrs, "adtcore:uri"), xml_attr(attrs, "uri"), xml_attr(attrs, "href")) or "",
          description = first_nonempty(xml_attr(attrs, "adtcore:description"), xml_attr(attrs, "description")) or "",
          parent = parent and parent.name or nil,
          parent_type = parent and parent.type or nil,
          source = "repository",
        }
      end
    end
  end

  return normalize_entries(rows, { source = "repository" })
end

local function score_entry(entry, query, opts)
  query = upper(query)
  local name = upper(entry.name)
  local desc = upper(entry.description)
  local score = 0
  if query == "" or query == "*" then
    score = 1
  elseif name == query then
    score = score + 1000
  elseif name:sub(1, #query) == query then
    score = score + 750
  elseif name:find(query, 1, true) then
    score = score + 420
  elseif desc:find(query, 1, true) then
    score = score + 120
  else
    local pattern = vim.pesc(query):gsub("%%%*", ".*")
    if name:match("^" .. pattern .. "$") then score = score + 650 end
  end
  if entry.kind == "object" then score = score + 20 end
  if entry.kind == "package" then score = score + 15 end
  if opts.kind and entry.kind == opts.kind then score = score + 35 end
  if opts.type then
    local want = upper(opts.type)
    if upper(entry.type) == want or upper(entry.group) == want or upper(entry.type):match("^" .. vim.pesc(want)) then
      score = score + 40
    end
  end
  return score
end

local function entry_matches(entry, query, opts)
  opts = opts or {}
  if opts.kind and entry.kind ~= opts.kind then return false end
  if opts.kinds then
    local ok = false
    for _, kind in ipairs(opts.kinds) do
      if entry.kind == kind then ok = true; break end
    end
    if not ok then return false end
  end
  if opts.type then
    local want = upper(opts.type)
    local typ = upper(entry.type)
    local group = upper(entry.group)
    if typ ~= want and group ~= want and not typ:match("^" .. vim.pesc(want)) then return false end
  end
  if opts.parent and upper(entry.parent) ~= upper(opts.parent) then return false end
  local q = upper(query)
  if q == "" or q == "*" then return true end
  if q:find("*", 1, true) then
    local pat = "^" .. vim.pesc(q):gsub("%%%*", ".*") .. "$"
    return upper(entry.name):match(pat) ~= nil
      or upper(entry.description):match(pat) ~= nil
  end
  return upper(entry.name):find(q, 1, true) ~= nil
    or upper(entry.description):find(q, 1, true) ~= nil
end

function M.search(query, opts)
  opts = opts or {}
  local cache = ensure_loaded()
  local rows = {}
  for _, entry in ipairs(cache.entries or {}) do
    if entry_matches(entry, query or "", opts) then
      local copy = vim.deepcopy(entry)
      copy.score = score_entry(copy, query or "", opts)
      rows[#rows + 1] = copy
    end
  end
  table.sort(rows, function(a, b)
    if a.score ~= b.score then return a.score > b.score end
    if (a.kind or "") ~= (b.kind or "") then return (a.kind or "") < (b.kind or "") end
    return (a.name or "") < (b.name or "")
  end)
  local limit = tonumber(opts.limit) or #rows
  while #rows > limit do rows[#rows] = nil end
  return rows
end

function M.search_objects(query, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "object" })
  return M.search(query, opts)
end

function M.search_fields(query, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "field" })
  return M.search(query, opts)
end

function M.search_methods(query, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "method" })
  return M.search(query, opts)
end

function M.search_packages(query, opts)
  opts = vim.tbl_extend("force", opts or {}, { kind = "package" })
  return M.search(query, opts)
end

local function entry_to_adt_row(entry)
  return {
    name = entry.name,
    adt_type = entry.type,
    type = entry.type,
    uri = entry.uri or "",
    desc = entry.description or "",
    description = entry.description or "",
    group = entry.group,
    kind = entry.kind,
    package = entry.package,
    parent = entry.parent,
    source = "index",
  }
end

local function entry_to_repository_row(entry)
  return {
    type = entry.type or "",
    name = entry.name,
    uri = entry.uri or "",
    description = entry.description or "",
    group = entry.group,
    kind = entry.kind,
    package = entry.package,
    parent = entry.parent,
    source = "index",
  }
end

function M.search_adt_rows(query, opts)
  opts = opts or {}
  local rows = {}
  for _, entry in ipairs(M.search(query, opts)) do
    rows[#rows + 1] = entry_to_adt_row(entry)
  end
  return rows
end

function M.repository_rows(parent, opts)
  opts = vim.tbl_extend("force", opts or {}, { parent = parent, limit = opts and opts.limit or 1000 })
  local rows = {}
  for _, entry in ipairs(M.search("", opts)) do
    rows[#rows + 1] = entry_to_repository_row(entry)
  end
  return rows
end

function M.completion_items(prefix, opts)
  opts = opts or {}
  local query = prefix or ""
  local limit = tonumber(opts.limit) or 50
  local rows = M.search(query, vim.tbl_extend("force", opts, { limit = limit }))
  local items, seen = {}, {}
  for _, entry in ipairs(rows) do
    local word = entry.name
    if word and word ~= "" and not seen[word] then
      seen[word] = true
      local kind = "2"
      if entry.kind == "method" then kind = "3" end
      if entry.kind == "field" then kind = "1" end
      if entry.group == "functionmodule" then kind = "4" end
      items[#items + 1] = {
        word = word,
        kind = kind,
        detail = (entry.description and entry.description ~= "" and entry.description or "SAP index"),
        type = entry.type,
        group = entry.group,
        source = "index",
      }
    end
  end
  return items
end

local function adt_available()
  local ok, adt_http = pcall(require, "sap-nvim.core.adt_http")
  return ok and adt_http.is_available(), adt_http
end

local function fetch_search(pattern, object_type, max_results)
  local ok, adt_http = adt_available()
  if not ok then return nil, "ADT no disponible" end
  local path = "/sap/bc/adt/repository/informationsystem/search?query="
    .. url_encode(pattern)
    .. "&maxResults=" .. tostring(max_results or DEFAULT_MAX_RESULTS)
    .. "&operation=quickSearch"
  if object_type and object_type ~= "" then
    path = path .. "&objectType=" .. url_encode(object_type)
  end
  local body, _, code = adt_http.raw({
    method = "GET",
    path = path,
    accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
  })
  if not body or code < 200 or code >= 400 then
    return nil, "search " .. pattern .. " HTTP " .. tostring(code)
  end
  return parse_search_body(body), nil
end

local function object_reference_body(entry)
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<tre:node xmlns:tre="http://www.sap.com/adt/core/tree" xmlns:adtcore="http://www.sap.com/adt/core">',
    '<tre:objectReference adtcore:uri="' .. xmlesc(entry.uri or "") .. '"',
    ' adtcore:name="' .. xmlesc(entry.name or "") .. '"',
    ' adtcore:type="' .. xmlesc(entry.type or "") .. '"/>',
    '</tre:node>',
  }, "")
end

local function fetch_nodes(parent_type, parent_name, body, parent_entry)
  local ok, adt_http = adt_available()
  if not ok then return nil, "ADT no disponible" end
  local resp, _, code = adt_http.raw({
    method = "POST",
    path = "/sap/bc/adt/repository/nodestructure",
    query = {
      parent_type = parent_type,
      parent_name = parent_name,
      withShortDescriptions = "true",
    },
    accept = "application/xml",
    content_type = "application/xml",
    body = body or "",
  })
  if not resp or code < 200 or code >= 400 then
    return nil, "repository " .. parent_name .. " HTTP " .. tostring(code)
  end
  return parse_nodestructure(resp, parent_entry), nil
end

local function configured_roots()
  local roots = vim.deepcopy(state.opts.roots or {})
  if #roots == 0 then
    local ok, repo = pcall(require, "sap-nvim.core.repository")
    if ok and repo._load_repository_store then
      local store = repo._load_repository_store()
      for _, root in ipairs(store.roots or {}) do roots[#roots + 1] = root end
    end
  end
  return roots
end

local function parse_build_args(args)
  local patterns, roots = {}, {}
  for _, arg in ipairs(args or {}) do
    if arg:lower():match("^package:") then
      roots[#roots + 1] = upper(arg:gsub("^[Pp][Aa][Cc][Kk][Aa][Gg][Ee]:", ""))
    elseif arg ~= "" then
      patterns[#patterns + 1] = upper(arg)
    end
  end
  return patterns, roots
end

function M.build(opts, cb)
  opts = opts or {}
  local ok = adt_available()
  local cache = ensure_loaded()
  if not ok then
    local result = {
      ok = false,
      offline = true,
      error = "ADT no disponible; usando cache offline",
      total = #cache.entries,
    }
    if cb then cb(result) end
    return result
  end

  local patterns = vim.deepcopy(opts.patterns or state.opts.patterns or {})
  local roots = vim.deepcopy(opts.roots or configured_roots())
  if #patterns == 0 and #roots == 0 then patterns = vim.deepcopy(DEFAULT_PATTERNS) end
  local object_types = opts.object_types or state.opts.object_types or {}
  local max_results = tonumber(opts.max_results or state.opts.max_results) or DEFAULT_MAX_RESULTS
  if opts.force then cache = empty_cache() end

  local added, updated, errors = 0, 0, {}
  local function merge(rows, source)
    local a, u = merge_entries(cache, rows or {}, source)
    added = added + a
    updated = updated + u
  end

  for _, pattern in ipairs(patterns) do
    if #object_types > 0 then
      for _, typ in ipairs(object_types) do
        local rows, err = fetch_search(pattern, typ, max_results)
        if rows then merge(rows, "search:" .. pattern .. ":" .. typ) else errors[#errors + 1] = err end
      end
    else
      local rows, err = fetch_search(pattern, nil, max_results)
      if rows then merge(rows, "search:" .. pattern) else errors[#errors + 1] = err end
    end
  end

  local expand_members = opts.expand_members
  if expand_members == nil then expand_members = state.opts.expand_members ~= false end
  for _, root in ipairs(roots) do
    root = upper(root)
    if root ~= "" then
      local pkg_entry = normalize_entry({ name = root, type = "DEVC/K", kind = "package", source = "repository" })
      merge({ pkg_entry }, "package:" .. root)
      local rows, err = fetch_nodes("DEVC/K", root, nil, pkg_entry)
      if rows then
        merge(rows, "repository:" .. root)
        if expand_members then
          for _, entry in ipairs(rows) do
            if entry.kind == "object" and EXPANDABLE_GROUPS[entry.group] then
              local children, child_err = fetch_nodes(entry.type, entry.name, object_reference_body(entry), entry)
              if children then
                merge(children, "repository:" .. root .. ":" .. entry.name)
              elseif child_err then
                errors[#errors + 1] = child_err
              end
            end
          end
        end
      else
        errors[#errors + 1] = err
      end
    end
  end

  M.save(cache)
  local result = {
    ok = #errors == 0,
    added = added,
    updated = updated,
    total = #cache.entries,
    errors = errors,
    path = index_path(),
  }
  if cb then cb(result) end
  return result
end

function M.refresh(opts, cb)
  opts = opts or {}
  opts.force = false
  return M.build(opts, cb)
end

local function entry_label(entry)
  local suffix = entry.group or entry.kind or entry.type or ""
  local text = entry.name
  if suffix ~= "" then text = text .. " [" .. suffix .. "]" end
  if entry.parent and entry.parent ~= "" then text = text .. " < " .. entry.parent end
  if entry.description and entry.description ~= "" then text = text .. "  " .. entry.description end
  return text
end

local function open_entry(entry)
  if not entry then return end
  if entry.kind == "package" then
    local ok, repo = pcall(require, "sap-nvim.core.repository")
    if ok and repo.open then repo.open(entry.name) end
    return
  end
  local target = entry
  if entry.kind == "field" or entry.kind == "method" then
    local parents = M.search(entry.parent or "", { kind = "object", limit = 1 })
    if parents[1] then target = parents[1] end
  end
  if not target.group then
    notify("No se puede abrir " .. target.name .. ": tipo ADT no reconocido", vim.log.levels.WARN)
    return
  end
  local ok, source = pcall(require, "sap-nvim.core.source")
  if ok and source.open then
    source.open(target.name, target.group, { uri = target.uri, package = target.package })
  end
end

local function show_results(query)
  local rows = M.search(query, { limit = 80 })
  if #rows == 0 then
    notify("Sin resultados offline para " .. query, vim.log.levels.WARN)
    return
  end
  vim.ui.select(rows, {
    prompt = "SapIndexSearch: " .. query,
    format_item = entry_label,
  }, open_entry)
end

local function status_message()
  local st = M.status()
  local age = st.age_seconds and (tostring(st.age_seconds) .. "s") or "nunca"
  local state_label = st.stale and "obsoleto" or "ok"
  if st.stale_reason == "never" then state_label = "sin construir" end
  return string.format(
    "estado=%s entradas=%d objetos=%d campos=%d metodos=%d paquetes=%d age=%s stale_after=%ss\n%s",
    state_label,
    st.counts.total,
    st.counts.object or 0,
    st.counts.field or 0,
    st.counts.method or 0,
    st.counts.package or 0,
    age,
    st.stale_after_seconds or 0,
    st.path
  )
end

function M.setup(opts)
  opts = opts or {}
  state.opts = opts.index or {}
  ensure_loaded()

  vim.api.nvim_create_user_command("SapIndexBuild", function(args)
    local split = args.args ~= "" and vim.split(args.args, "%s+", { trimempty = true }) or {}
    local patterns, roots = parse_build_args(split)
    local result = M.build({
      patterns = #patterns > 0 and patterns or nil,
      roots = #roots > 0 and roots or nil,
      force = args.bang,
    })
    if result.offline then
      notify(result.error .. " (" .. tostring(result.total) .. " entradas)", vim.log.levels.WARN)
      return
    end
    local msg = string.format("indexado: +%d ~%d total=%d", result.added or 0, result.updated or 0, result.total or 0)
    if result.errors and #result.errors > 0 then
      msg = msg .. " errores=" .. #result.errors
      notify(msg, vim.log.levels.WARN)
    else
      notify(msg)
    end
  end, {
    nargs = "*",
    bang = true,
    desc = "sap-nvim: construir/refrescar indice local ADT (usa ! para reconstruir)",
  })

  vim.api.nvim_create_user_command("SapIndexSearch", function(args)
    if args.args ~= "" then
      show_results(args.args)
      return
    end
    vim.ui.input({ prompt = "Buscar en indice SAP: " }, function(input)
      if input and trim(input) ~= "" then show_results(input) end
    end)
  end, { nargs = "?", desc = "sap-nvim: buscar en indice local offline" })

  vim.api.nvim_create_user_command("SapIndexStatus", function()
    notify(status_message())
  end, { desc = "sap-nvim: estado del indice local ADT" })

  vim.api.nvim_create_user_command("SapIndexClear", function()
    M.clear()
    notify("indice local borrado")
  end, { desc = "sap-nvim: borrar cache local del indice ADT" })
end

M._parse_search_body = parse_search_body
M._parse_nodestructure = parse_nodestructure
M._normalize_entries = normalize_entries
M._score_entry = score_entry
M._parse_build_args = parse_build_args

return M
