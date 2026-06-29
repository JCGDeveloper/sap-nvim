-- sap-nvim.core.dumps
-- Read-only system dump viewer. It probes ADT dump routes when available and
-- falls back to ST22 in SAP GUI/WebGUI.

local M = {}

local ROUTES = {
  { label = "ADT runtime dumps", path = "/sap/bc/adt/runtime/dumps", query = { maxResults = "100" } },
  { label = "ADT runtime dumps limit", path = "/sap/bc/adt/runtime/dumps", query = { limit = "100" } },
  { label = "ADT ABAP dumps", path = "/sap/bc/adt/abap/dumps", query = { maxResults = "100" } },
}

local state = { rows = {}, statuses = {}, buf = nil }

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
    :gsub("&amp;", "&")
    :gsub("&nbsp;", " ")
end

local function attr(tag, name)
  return unxml(tag:match(name .. '="([^"]*)"') or tag:match(name .. "='([^']*)'") or "")
end

local function compact(s)
  s = trim(unxml(s or ""))
  s = s:gsub("%s+", " ")
  return s
end

local function adt_path(uri)
  uri = compact(uri)
  if uri == "" then return "" end
  return uri:match("^adt://[^/]+(/.*)$") or uri
end

local function tag_text(xml, name)
  return unxml(
    xml:match("<[^>]*" .. name .. "[^>]*>(.-)</[^>]*" .. name .. ">")
      or xml:match("<[^>]*[%w_:-]*" .. name .. "[^>]*>(.-)</[^>]*[%w_:-]*" .. name .. ">")
      or ""
  )
end

local function summary_field(summary, label)
  local html = unxml(summary or "")
  local pat = "<b>%s*" .. label .. "%s*</b>.-<td[^>]*>%s*(.-)%s*</td>"
  local value = html:match(pat)
  if not value then
    value = html:match(label .. "%s*</b>.-<td[^>]*>%s*(.-)%s*</td>")
  end
  value = value and value:gsub("<[^>]+>", " ") or ""
  return compact(value)
end

local function atom_categories(entry)
  local out = {}
  for tag in entry:gmatch("<[^>]*category%s+([^>]*)/?>") do
    out[#out + 1] = { term = attr(tag, "term"), label = attr(tag, "label") }
  end
  return out
end

local function atom_link(entry)
  local fallback = ""
  for tag in entry:gmatch("<[^>]*link%s+([^>]*)/?>") do
    local href = attr(tag, "href")
    local rel = attr(tag, "rel")
    local typ = attr(tag, "type")
    if href ~= "" then
      fallback = fallback ~= "" and fallback or href
      if rel == "self" or typ:find("text/plain", 1, true) then
        return adt_path(href)
      end
    end
  end
  return adt_path(fallback)
end

local function route_key(route)
  local q = {}
  for k, v in pairs(route.query or {}) do q[#q + 1] = k .. "=" .. v end
  table.sort(q)
  return route.path .. (#q > 0 and ("?" .. table.concat(q, "&")) or "")
end

local function parse_json(body)
  local ok, data = pcall(function()
    if vim.json and vim.json.decode then return vim.json.decode(body) end
    return vim.fn.json_decode(body)
  end)
  if not ok or type(data) ~= "table" then return {} end
  local list = data.dumps or data.items or data.results or data
  if type(list) ~= "table" then return {} end
  local rows = {}
  for _, item in pairs(list) do
    if type(item) == "table" then
      local name = item.name or item.id or item.key or item.runtimeError or item.shortText
      if name then
        rows[#rows + 1] = {
          id = tostring(item.id or item.key or name),
          title = tostring(item.shortText or item.title or item.runtimeError or name),
          program = tostring(item.program or item.abapProgram or item.mainProgram or item.terminatedProgram or ""),
          user = tostring(item.user or item.username or item.createdBy or item.author or ""),
          timestamp = tostring(item.timestamp or item.createdAt or item.date or item.published or item.updated or ""),
          exception = tostring(item.exception or item.errorId or item.runtimeError or item.category or ""),
          uri = adt_path(tostring(item.uri or item.href or item.link or "")),
        }
      end
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
  local function add(row)
    row.title = compact(row.title ~= "" and row.title or row.id)
    row.program = compact(row.program)
    row.user = compact(row.user)
    row.timestamp = compact(row.timestamp)
    row.exception = compact(row.exception)
    row.uri = compact(row.uri)
    row.id = compact(row.id ~= "" and row.id or row.title)
    local key = (row.uri ~= "" and row.uri or (row.id .. row.timestamp .. row.program))
    if row.id ~= "" and not seen[key] then
      seen[key] = true
      rows[#rows + 1] = row
    end
  end

  for tag in body:gmatch("<[^>]*objectReference%s+([^>]*)/?>") do
    add({
      id = attr(tag, "adtcore:name") ~= "" and attr(tag, "adtcore:name") or attr(tag, "name"),
      title = attr(tag, "adtcore:description") ~= "" and attr(tag, "adtcore:description") or attr(tag, "description"),
      program = attr(tag, "program") ~= "" and attr(tag, "program") or attr(tag, "adtcore:program"),
      user = attr(tag, "user") ~= "" and attr(tag, "user") or attr(tag, "adtcore:user"),
      timestamp = attr(tag, "timestamp") ~= "" and attr(tag, "timestamp") or attr(tag, "adtcore:timestamp"),
      exception = attr(tag, "exception") ~= "" and attr(tag, "exception") or attr(tag, "runtimeError"),
      uri = adt_path(attr(tag, "adtcore:uri") ~= "" and attr(tag, "adtcore:uri") or attr(tag, "href")),
    })
  end

  for entry in body:gmatch("<[^>]*entry[^>]*>(.-)</[^>]*entry>") do
    local summary = tag_text(entry, "summary")
    local categories = atom_categories(entry)
    local exception, program = "", ""
    for _, cat in ipairs(categories) do
      local label = cat.label:lower()
      if exception == "" and (label:find("runtime error", 1, true) or label:find("exception", 1, true)) then
        exception = cat.term
      elseif program == "" and (label:find("program", 1, true) or label:find("abap", 1, true)) then
        program = cat.term
      end
    end
    exception = exception ~= "" and exception or summary_field(summary, "Runtime Error")
    program = program ~= "" and program or summary_field(summary, "Program")
    local user = tag_text(tag_text(entry, "author"), "name")
    user = user ~= "" and user or summary_field(summary, "User")
    user = user:gsub("%s*%([^)]*%)%s*$", "")
    add({
      id = tag_text(entry, "id"),
      title = tag_text(entry, "title") ~= "" and tag_text(entry, "title") or summary_field(summary, "Short Text"),
      program = program,
      user = user,
      timestamp = tag_text(entry, "published") ~= "" and tag_text(entry, "published")
        or tag_text(entry, "updated") ~= "" and tag_text(entry, "updated")
        or summary_field(summary, "Date/Time"),
      exception = exception,
      uri = atom_link(entry),
    })
  end

  return rows
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

function M._fetch()
  local statuses, rows = {}, {}
  for _, route in ipairs(ROUTES) do
    local body, code, err = request_route(route)
    local parsed = (code >= 200 and code < 300) and M._parse_body(body) or {}
    statuses[#statuses + 1] = {
      route = route,
      code = code,
      count = #parsed,
      error = err,
    }
    if #parsed > 0 then
      return parsed, statuses
    end
  end
  return rows, statuses
end

local function st22()
  local ok, sapgui = pcall(require, "sap-nvim.core.sapgui")
  if ok and sapgui.transaction then
    sapgui.transaction("ST22")
    return
  end
  local ok_web, gui = pcall(require, "sap-nvim.core.gui")
  if ok_web and gui.run_transaction then
    gui.run_transaction("ST22")
  else
    notify("No encuentro lanzador SAP GUI/WebGUI para ST22.", vim.log.levels.WARN)
  end
end

local function render_lines(rows, statuses)
  local lines = {
    "SAP System Dumps",
    "",
    "Solo lectura. r refresca · o abre detalle · s ST22 · R rutas ADT · q cierra",
    "",
  }
  if #rows == 0 then
    lines[#lines + 1] = "No se han recibido dumps por ADT en las rutas conocidas."
    lines[#lines + 1] = "Usa s para abrir ST22; R muestra las rutas probadas."
  else
    lines[#lines + 1] = string.format("%-4s %-22s %-12s %-14s %s", "N", "Fecha", "Usuario", "Programa", "Dump")
    for i, row in ipairs(rows) do
      lines[#lines + 1] = string.format(
        "%-4d %-22s %-12s %-14s %s",
        i,
        (row.timestamp or ""):sub(1, 22),
        (row.user or ""):sub(1, 12),
        (row.program or ""):sub(1, 14),
        row.title or row.id or ""
      )
    end
  end
  lines[#lines + 1] = ""
  lines[#lines + 1] = "Rutas ADT"
  for _, st in ipairs(statuses or {}) do
    local icon = (st.code >= 200 and st.code < 300) and "OK" or "NO"
    lines[#lines + 1] = string.format("  %s HTTP %s  %s  (%d)", icon, st.code or 0, route_key(st.route), st.count or 0)
  end
  return lines
end

local function selected_row()
  local line = vim.api.nvim_win_get_cursor(0)[1]
  local idx = line - 5
  if state.rows[idx] then return state.rows[idx] end
  return nil
end

local function show_detail(row)
  if not row then
    notify("Situa el cursor sobre un dump o abre ST22 con s.", vim.log.levels.WARN)
    return
  end
  if not row.uri or row.uri == "" then
    notify("Ese dump no trae URI ADT; abro ST22.", vim.log.levels.WARN)
    st22()
    return
  end
  local ok, adt = pcall(require, "sap-nvim.core.adt_http")
  if not ok then return notify("ADT no disponible.", vim.log.levels.WARN) end
  local body, _, code = adt.raw({ method = "GET", path = row.uri, accept = "text/plain, application/xml, */*" })
  if not code or code < 200 or code >= 300 then
    notify("No se pudo abrir detalle ADT (HTTP " .. tostring(code or 0) .. ").", vim.log.levels.WARN)
    return
  end
  local lines = vim.split(tostring(body or ""), "\n", { plain = true })
  if #lines == 0 then lines = { "(respuesta vacia)" } end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sapdump"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://dump/" .. (row.id or "detail"))
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", { buffer = buf, silent = true, nowait = true })
end

function M.open()
  state.rows, state.statuses = M._fetch()
  local buf = vim.api.nvim_create_buf(false, true)
  state.buf = buf
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sapdumps"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://dumps")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(state.rows, state.statuses))
  vim.bo[buf].modifiable = false
  vim.cmd("tabnew")
  vim.api.nvim_win_set_buf(0, buf)

  local opts = { buffer = buf, silent = true, nowait = true }
  vim.keymap.set("n", "q", "<cmd>tabclose<cr>", opts)
  vim.keymap.set("n", "s", st22, opts)
  vim.keymap.set("n", "o", function() show_detail(selected_row()) end, opts)
  vim.keymap.set("n", "<CR>", function() show_detail(selected_row()) end, opts)
  vim.keymap.set("n", "R", function() M.routes() end, opts)
  vim.keymap.set("n", "r", function()
    state.rows, state.statuses = M._fetch()
    vim.bo[buf].modifiable = true
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, render_lines(state.rows, state.statuses))
    vim.bo[buf].modifiable = false
  end, opts)
end

function M.open_detail(arg)
  arg = trim(arg)
  if arg == "" then return show_detail(selected_row()) end
  show_detail({ id = arg, uri = arg })
end

function M.routes()
  local _, statuses = M._fetch()
  local lines = { "SAP Dumps ADT Routes", "", "Solo lectura. q cierra", "" }
  for _, st in ipairs(statuses) do
    lines[#lines + 1] = string.format("HTTP %-3s  %-24s  %s", st.code or 0, st.label or st.route.label, route_key(st.route))
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "sapdumpsroutes"
  pcall(vim.api.nvim_buf_set_name, buf, "sap://dumps/routes")
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_win_set_height, 0, math.min(14, #lines + 1))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = buf, silent = true, nowait = true })
end

function M.setup()
  vim.api.nvim_create_user_command("SapDumps", M.open, { desc = "sap-nvim: Ver dumps del sistema (solo lectura)" })
  vim.api.nvim_create_user_command("SapDumpList", M.open, { desc = "sap-nvim: Ver dumps del sistema (solo lectura)" })
  vim.api.nvim_create_user_command("SapDumpOpen", function(args) M.open_detail(args.args) end,
    { nargs = "?", desc = "sap-nvim: Abrir detalle de dump por URI ADT" })
  vim.api.nvim_create_user_command("SapDumpsRoutes", M.routes,
    { desc = "sap-nvim: Validar rutas ADT de dumps (solo lectura)" })
  vim.api.nvim_create_user_command("SapST22", st22, { desc = "sap-nvim: Abrir ST22" })
  vim.keymap.set("n", "<leader>asD", M.open, { desc = "SAP: Dumps del sistema" })
end

M._routes = ROUTES
M._render_lines = render_lines
M._route_key = route_key

return M
