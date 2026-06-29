-- sap-nvim.core.revisions
-- Read-only ADT revision/version discovery and diff helpers.

local M = {}

local state = { rows = {}, statuses = {}, context = nil, buf = nil }

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return vim.trim(tostring(s or ""))
end

local function unxml(s)
  return (s or "")
    :gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&#x0A;", "\n")
    :gsub("&#x0D;", "\r")
    :gsub("&#10;", "\n")
    :gsub("&#13;", "\r")
    :gsub("&amp;", "&")
end

local function attr(tag, name)
  return unxml(tag:match(name .. '="([^"]*)"') or tag:match(name .. "='([^']*)'") or "")
end

local function compact(s)
  s = trim(unxml(s or ""))
  return (s:gsub("%s+", " "))
end

local function strip_query(uri)
  return tostring(uri or ""):gsub("#.*$", ""):gsub("%?.*$", "")
end

local function source_from_object_uri(uri)
  uri = strip_query(uri):gsub("/source/main$", "")
  if uri == "" then return nil end
  return uri .. "/source/main"
end

local EXT_GROUPS = {
  abap = "program",
  prog = "program",
  cls = "class",
  intf = "interface",
  ddls = "ddls",
  cds = "ddls",
  acds = "ddls",
  dcls = "dcl",
  dcl = "dcl",
  ddlx = "ddlx",
  bdef = "bdef",
  srvd = "srvd",
}

local function object_context(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local meta = vim.b[bufnr].sap_obj
  local source_uri
  local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
  if ok_intel and intel.object_uri then
    source_uri = intel.object_uri(bufnr)
  end
  if (not source_uri or source_uri == "") and meta and meta.uri and meta.uri ~= "" then
    source_uri = source_from_object_uri(meta.uri)
  end
  if (not source_uri or source_uri == "") and meta and meta.group and meta.name then
    local ok_source, source = pcall(require, "sap-nvim.core.source")
    if ok_source and source._source_uri then
      source_uri = source._source_uri(meta.group, meta.name, meta)
    end
  end

  local name = meta and meta.name
  local group = meta and meta.group
  if not name or name == "" then
    local bufname = vim.api.nvim_buf_get_name(bufnr)
    name = vim.fn.fnamemodify(bufname, ":t:r")
    local ext = vim.fn.fnamemodify(bufname, ":e"):lower()
    group = group or EXT_GROUPS[ext]
    if group then
      local ok_source, source = pcall(require, "sap-nvim.core.source")
      if ok_source and source._source_uri then
        source_uri = source_uri or source._source_uri(group, name, {})
      end
    end
  end

  if not source_uri or source_uri == "" then
    return nil, "No encuentro URI ADT del objeto actual. Abre el objeto desde SAP Repository/Search o usa un buffer con vim.b.sap_obj."
  end

  return {
    name = (name and name ~= "" and name:upper()) or source_uri:match("([^/]+)/source/main$") or "SAP",
    group = group or (meta and meta.type) or "",
    source_uri = source_uri,
    object_uri = source_uri:gsub("/source/main$", ""),
  }
end

local function route_key(route)
  local q = {}
  for k, v in pairs(route.query or {}) do q[#q + 1] = k .. "=" .. v end
  table.sort(q)
  return route.path .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
end

local function revision_key(row)
  return row.version ~= "" and row.version
    or row.id ~= "" and row.id
    or row.uri ~= "" and row.uri
    or row.timestamp ~= "" and row.timestamp
    or ""
end

local function add_row(rows, seen, row)
  row.id = compact(row.id)
  row.version = compact(row.version)
  row.author = compact(row.author)
  row.timestamp = compact(row.timestamp)
  row.transport = compact(row.transport)
  row.description = compact(row.description)
  row.uri = compact(row.uri)
  row.content_uri = compact(row.content_uri)
  local key = revision_key(row)
  if key ~= "" and not seen[key] then
    seen[key] = true
    rows[#rows + 1] = row
  end
end

local function parse_json(body)
  local ok, data = pcall(function()
    if vim.json and vim.json.decode then return vim.json.decode(body) end
    return vim.fn.json_decode(body)
  end)
  if not ok or type(data) ~= "table" then return {} end
  local list = data.revisions or data.versions or data.items or data.results or data
  if type(list) ~= "table" then return {} end
  local rows, seen = {}, {}
  for _, item in pairs(list) do
    if type(item) == "table" then
      add_row(rows, seen, {
        id = tostring(item.id or item.key or item.name or item.version or ""),
        version = tostring(item.version or item.rev or item.revision or item.id or ""),
        author = tostring(item.author or item.user or item.changedBy or item.createdBy or ""),
        timestamp = tostring(item.timestamp or item.date or item.updated or item.createdAt or item.changedAt or ""),
        transport = tostring(item.transport or item.request or item.trkorr or item.corrnr or ""),
        description = tostring(item.description or item.text or item.comment or item.title or ""),
        uri = tostring(item.uri or item.href or item.link or ""),
        content_uri = tostring(item.contentUri or item.sourceUri or item.content_uri or ""),
      })
    end
  end
  return rows
end

function M._parse_body(body)
  body = tostring(body or "")
  if trim(body) == "" then return {} end
  if body:match("^%s*[%[{]") then
    local rows = parse_json(body)
    if #rows > 0 then return rows end
  end

  local rows, seen = {}, {}

  for entry in body:gmatch("<[^>]*entry[^>]*>(.-)</[^>]*entry>") do
    local author = entry:match("<[^>]*author[^>]*>.-<[^>]*name[^>]*>(.-)</[^>]*name>.-</[^>]*author>")
      or entry:match("<[^>]*author[^>]*>(.-)</[^>]*author>")
      or ""
    local link, any_link = "", ""
    for ltag in entry:gmatch("<[^>]*link%s+[^>]*>") do
      local href = attr(ltag, "href")
      local rel = attr(ltag, "rel"):lower()
      local typ = attr(ltag, "type"):lower()
      if href ~= "" then
        any_link = any_link ~= "" and any_link or href
        if link == "" and (rel:find("content", 1, true) or typ:find("text/plain", 1, true)) then
          link = href
        end
      end
    end
    add_row(rows, seen, {
      id = entry:match("<[^>]*id[^>]*>(.-)</[^>]*id>") or "",
      version = entry:match("<[^>]*version[^>]*>(.-)</[^>]*version>") or "",
      author = author,
      timestamp = entry:match("<[^>]*updated[^>]*>(.-)</[^>]*updated>")
        or entry:match("<[^>]*timestamp[^>]*>(.-)</[^>]*timestamp>")
        or "",
      transport = entry:match("<[^>]*transport[^>]*>(.-)</[^>]*transport>")
        or entry:match("<[^>]*request[^>]*>(.-)</[^>]*request>")
        or "",
      description = entry:match("<[^>]*title[^>]*>(.-)</[^>]*title>")
        or entry:match("<[^>]*summary[^>]*>(.-)</[^>]*summary>")
        or "",
      uri = any_link,
      content_uri = link,
    })
  end

  for tag in body:gmatch("<[^>]*[%w_:-]*objectReference%s+([^>]*)/?>") do
    add_row(rows, seen, {
      id = attr(tag, "adtcore:name") ~= "" and attr(tag, "adtcore:name") or attr(tag, "name"),
      version = attr(tag, "adtcore:version") ~= "" and attr(tag, "adtcore:version") or attr(tag, "version"),
      author = attr(tag, "adtcore:changedBy") ~= "" and attr(tag, "adtcore:changedBy")
        or attr(tag, "changedBy") ~= "" and attr(tag, "changedBy")
        or attr(tag, "author") ~= "" and attr(tag, "author")
        or attr(tag, "user"),
      timestamp = attr(tag, "adtcore:changedAt") ~= "" and attr(tag, "adtcore:changedAt")
        or attr(tag, "changedAt") ~= "" and attr(tag, "changedAt")
        or attr(tag, "timestamp") ~= "" and attr(tag, "timestamp")
        or attr(tag, "date"),
      transport = attr(tag, "transport") ~= "" and attr(tag, "transport")
        or attr(tag, "request") ~= "" and attr(tag, "request")
        or attr(tag, "trkorr") ~= "" and attr(tag, "trkorr")
        or attr(tag, "corrnr"),
      description = attr(tag, "adtcore:description") ~= "" and attr(tag, "adtcore:description") or attr(tag, "description"),
      uri = attr(tag, "adtcore:uri") ~= "" and attr(tag, "adtcore:uri") or attr(tag, "href"),
      content_uri = attr(tag, "contentUri") ~= "" and attr(tag, "contentUri") or attr(tag, "sourceUri"),
    })
  end

  for tag in body:gmatch("<[^>]*[%w_:-]*version%s+([^>]*)/?>") do
    add_row(rows, seen, {
      id = attr(tag, "id") ~= "" and attr(tag, "id") or attr(tag, "name"),
      version = attr(tag, "version") ~= "" and attr(tag, "version") or attr(tag, "adtcore:version"),
      author = attr(tag, "author") ~= "" and attr(tag, "author") or attr(tag, "user") ~= "" and attr(tag, "user") or attr(tag, "changedBy"),
      timestamp = attr(tag, "timestamp") ~= "" and attr(tag, "timestamp") or attr(tag, "date") ~= "" and attr(tag, "date") or attr(tag, "changedAt"),
      transport = attr(tag, "transport") ~= "" and attr(tag, "transport") or attr(tag, "request") ~= "" and attr(tag, "request") or attr(tag, "trkorr"),
      description = attr(tag, "description") ~= "" and attr(tag, "description") or attr(tag, "title"),
      uri = attr(tag, "uri") ~= "" and attr(tag, "uri") or attr(tag, "href"),
      content_uri = attr(tag, "contentUri") ~= "" and attr(tag, "contentUri") or attr(tag, "sourceUri"),
    })
  end

  return rows
end

local function versions_link(body)
  body = tostring(body or "")
  for tag in body:gmatch("<[^>]*link%s+[^>]*>") do
    local rel = attr(tag, "rel")
    local href = attr(tag, "href")
    if href ~= "" and rel:lower():find("versions", 1, true) then
      return href
    end
  end
  return nil
end

function M._discover_routes(ctx)
  local routes, seen = {}, {}
  local function add(label, path, query)
    if not path or path == "" then return end
    path = path:match("^https?://[^/]+(/.*)$") or path
    if not path:match("^/") then
      path = ctx.object_uri:gsub("/$", "") .. "/" .. path:gsub("^/", "")
    end
    local route = { label = label, path = path, query = query }
    local key = route_key(route)
    if not seen[key] then
      seen[key] = true
      routes[#routes + 1] = route
    end
  end

  local ok, adt = pcall(require, "sap-nvim.core.adt_http")
  if ok then
    local body, _, code = adt.raw({ method = "GET", path = ctx.object_uri, accept = "application/*, application/xml, */*" })
    local href = (code >= 200 and code < 300) and versions_link(body) or nil
    if href then add("ADT link rel=versions", href) end
  end

  add("Object versions", ctx.object_uri .. "/versions")
  add("Object source versions", ctx.source_uri .. "/versions")
  add("Active source ?version=active", ctx.source_uri, { version = "active" })
  return routes
end

local function request_route(route)
  local ok, adt = pcall(require, "sap-nvim.core.adt_http")
  if not ok then return nil, 0, "ADT no disponible" end
  local body, _, code = adt.raw({
    method = "GET",
    path = route.path,
    query = route.query,
    accept = "application/xml, application/atom+xml, application/json, */*",
  })
  return body, tonumber(code) or 0
end

function M._fetch(ctx)
  ctx = ctx or assert(object_context())
  local rows, statuses = {}, {}
  for _, route in ipairs(M._discover_routes(ctx)) do
    local body, code, err = request_route(route)
    local parsed = (code >= 200 and code < 300) and M._parse_body(body) or {}
    statuses[#statuses + 1] = { route = route, code = code, count = #parsed, error = err }
    if #parsed > 0 and #rows == 0 then
      rows = parsed
    end
  end
  return rows, statuses, ctx
end

local function render_lines(rows, statuses, ctx)
  local lines = {
    "SAP Revisions",
    "",
    "Solo lectura. r refresca · d diff local vs revision · a diff activo vs revision · R rutas ADT · q cierra",
    "",
    "Objeto: " .. ((ctx and ctx.name) or "?") .. "  " .. ((ctx and ctx.source_uri) or ""),
    "",
  }
  if #rows == 0 then
    lines[#lines + 1] = "No se recibieron revisiones por ADT en las rutas conocidas."
    lines[#lines + 1] = "Pulsa R para ver HTTP/status de cada ruta probada."
  else
    lines[#lines + 1] = string.format("%-4s %-24s %-14s %-12s %s", "N", "Fecha", "Autor", "Transporte", "Revision")
    for i, row in ipairs(rows) do
      local label = row.description ~= "" and row.description or revision_key(row)
      lines[#lines + 1] = string.format(
        "%-4d %-24s %-14s %-12s %s",
        i,
        (row.timestamp or ""):sub(1, 24),
        (row.author or ""):sub(1, 14),
        (row.transport or ""):sub(1, 12),
        label
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Rutas ADT"
  for _, st in ipairs(statuses or {}) do
    local ok = (st.code >= 200 and st.code < 300) and "OK" or "NO"
    lines[#lines + 1] = string.format("  %s HTTP %-3s %s (%d)", ok, st.code or 0, route_key(st.route), st.count or 0)
  end
  return lines
end

local function selected_row()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local idx = line - 7
  return state.rows[idx]
end

local function read_revision(ctx, row)
  local ok, adt = pcall(require, "sap-nvim.core.adt_http")
  if not ok then return nil, "ADT no disponible", 0 end
  local tried = {}
  local function get(label, path, query)
    if not path or path == "" then return nil end
    path = path:match("^https?://[^/]+(/.*)$") or path
    tried[#tried + 1] = label .. " " .. path
    local body, _, code = adt.raw({ method = "GET", path = path, query = query, accept = "text/plain, text/*, */*" })
    if code >= 200 and code < 300 and body and body ~= "" and not body:match("^%s*<%?xml") and not body:match("^%s*<") then
      return body, code
    end
    return nil, code
  end

  local body, code = get("content", row.content_uri)
  if body then return body, nil, code end
  body, code = get("row", row.uri)
  if body then return body, nil, code end
  local version = revision_key(row)
  if version ~= "" then
    body, code = get("source", ctx.source_uri, { version = version })
    if body then return body, nil, code end
  end
  return nil, "La revision no trae contenido de fuente en ADT. Probado: " .. table.concat(tried, " | "), tonumber(code) or 0
end

local function read_active(ctx)
  local ok, adt = pcall(require, "sap-nvim.core.adt_http")
  if not ok then return nil, "ADT no disponible" end
  local body, _, code = adt.raw({ method = "GET", path = ctx.source_uri, query = { version = "active" }, accept = "text/plain" })
  if code >= 200 and code < 300 and body and body ~= "" then
    return body, nil
  end
  return nil, "No pude leer version activa (HTTP " .. tostring(code or 0) .. ")"
end

local function open_diff(left_label, left_lines, right_label, right_lines, filetype)
  local left_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_lines)
  vim.bo[left_buf].buftype = "nofile"
  vim.bo[left_buf].bufhidden = "wipe"
  vim.bo[left_buf].swapfile = false
  vim.bo[left_buf].filetype = filetype
  vim.bo[left_buf].readonly = true
  vim.bo[left_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, left_buf, left_label)

  local right_buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, right_lines)
  vim.bo[right_buf].buftype = "nofile"
  vim.bo[right_buf].bufhidden = "wipe"
  vim.bo[right_buf].swapfile = false
  vim.bo[right_buf].filetype = filetype
  vim.bo[right_buf].readonly = true
  vim.bo[right_buf].modifiable = false
  pcall(vim.api.nvim_buf_set_name, right_buf, right_label)

  vim.cmd("tabnew")
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)
  vim.cmd("vsplit")
  local right_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(right_win, right_buf)
  vim.api.nvim_win_call(left_win, function() vim.cmd("diffthis") end)
  vim.api.nvim_win_call(right_win, function() vim.cmd("diffthis") end)
  local function close()
    pcall(vim.api.nvim_win_call, left_win, function() vim.cmd("diffoff") end)
    pcall(vim.api.nvim_win_call, right_win, function() vim.cmd("diffoff") end)
    pcall(vim.cmd, "tabclose")
  end
  vim.keymap.set("n", "q", close, { buffer = left_buf, nowait = true, silent = true, desc = "Cerrar diff revision" })
  vim.keymap.set("n", "q", close, { buffer = right_buf, nowait = true, silent = true, desc = "Cerrar diff revision" })
  notify("Diff de revision abierto. ]c/[c navegan cambios; q cierra.")
end

function M.diff_row(row, opts)
  opts = opts or {}
  local ctx, err = opts.context, nil
  if not ctx then ctx, err = object_context() end
  if not ctx and state.context then ctx, err = state.context, nil end
  if not ctx then return notify(err, vim.log.levels.WARN) end
  row = row or selected_row()
  if not row then return notify("Selecciona una revision en :SapRevisions o pasa un id.", vim.log.levels.WARN) end
  local rev_body, rev_err = read_revision(ctx, row)
  if not rev_body then return notify(rev_err, vim.log.levels.WARN) end
  local rev_lines = vim.split(rev_body:gsub("\r", ""), "\n", { plain = true })
  local filetype = vim.bo.filetype

  if opts.active then
    local active_body, active_err = read_active(ctx)
    if not active_body then return notify(active_err, vim.log.levels.WARN) end
    open_diff(
      ctx.name .. " [SAP active]",
      vim.split(active_body:gsub("\r", ""), "\n", { plain = true }),
      ctx.name .. " [revision " .. revision_key(row) .. "]",
      rev_lines,
      filetype
    )
    return
  end

  local local_lines = vim.api.nvim_buf_get_lines(0, 0, -1, false)
  open_diff(ctx.name .. " [local]", local_lines, ctx.name .. " [revision " .. revision_key(row) .. "]", rev_lines, filetype)
end

function M.diff(arg)
  arg = trim(arg)
  if arg == "" then return M.diff_row(nil, { active = false }) end
  local ctx, err = object_context()
  if not ctx then return notify(err, vim.log.levels.WARN) end
  local rows = state.rows
  if #rows == 0 or not state.context or state.context.source_uri ~= ctx.source_uri then
    rows = M._fetch(ctx)
  end
  for _, row in ipairs(rows or {}) do
    if revision_key(row) == arg or row.id == arg or row.version == arg then
      return M.diff_row(row, { active = false })
    end
  end
  return notify("No encuentro revision '" .. arg .. "'. Abre :SapRevisions para listar las disponibles.", vim.log.levels.WARN)
end

function M.open()
  local ctx, err = object_context()
  if not ctx then return notify(err, vim.log.levels.WARN) end
  state.rows, state.statuses, state.context = M._fetch(ctx)
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "saprevisions"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://revisions/" .. ctx.name)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(state.rows, state.statuses, ctx))
  vim.bo[buf].modifiable = false
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", opts)
  vim.keymap.set("n", "d", function() M.diff_row(selected_row(), { active = false, context = ctx }) end, opts)
  vim.keymap.set("n", "<CR>", function() M.diff_row(selected_row(), { active = false, context = ctx }) end, opts)
  vim.keymap.set("n", "a", function() M.diff_row(selected_row(), { active = true, context = ctx }) end, opts)
  vim.keymap.set("n", "R", M.routes, opts)
  vim.keymap.set("n", "r", function()
    state.rows, state.statuses, state.context = M._fetch(ctx)
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(state.rows, state.statuses, ctx))
    vim.bo[buf].modifiable = false
  end, opts)
end

function M.routes()
  local ctx, err = object_context()
  if not ctx and state.context then ctx, err = state.context, nil end
  if not ctx then return notify(err, vim.log.levels.WARN) end
  local _, statuses = M._fetch(ctx)
  local lines = { "SAP Revision ADT Routes", "", "Solo lectura. q cierra", "", "Objeto: " .. ctx.source_uri, "" }
  for _, st in ipairs(statuses) do
    lines[#lines + 1] = string.format("HTTP %-3s  %-24s  %s", st.code or 0, st.route.label, route_key(st.route))
  end
  if #statuses == 0 then
    lines[#lines + 1] = "No hay rutas para probar."
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "saprevisionroutes"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://revisions/routes")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_win_set_height, 0, math.min(16, #lines + 1))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true })
end

function M.setup()
  vim.api.nvim_create_user_command("SapRevisions", M.open,
    { desc = "sap-nvim: Revisiones ADT del objeto actual (solo lectura)" })
  vim.api.nvim_create_user_command("SapRevisionRoutes", M.routes,
    { desc = "sap-nvim: Probar rutas ADT de revisiones del objeto actual" })
  vim.api.nvim_create_user_command("SapRevisionDiff", function(args) M.diff(args.args) end,
    { nargs = "?", desc = "sap-nvim: Diff local vs revision ADT" })
  vim.keymap.set("n", "<leader>aV", M.open, { desc = "ABAP: Revisiones/versiones ADT" })
end

M._object_context = object_context
M._render_lines = render_lines
M._route_key = route_key
M._revision_key = revision_key

return M
