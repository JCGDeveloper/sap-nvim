-- sap-nvim.core.quickfix
-- Quick fixes / code actions (los 💡 de VSCode). Replica abap-adt-api:
--   1) fixProposals: POST /sap/bc/adt/quickfixes/evaluation (uri#start, body=source) -> propuestas.
--   2) fixEdits: POST a la `adtcore:uri` de la propuesta elegida -> deltas (rango + contenido).
--   3) Aplica los deltas al buffer (en orden inverso para no desplazar posiciones).
-- Seguro: si algo no encaja (sin propuestas / sin deltas), NO toca el buffer.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function enc(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;"):gsub("'", "&apos;")
end
local function dec(s)
  return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(s)
  return (s or ""):lower()
end

local function indentation(line)
  return (line or ""):match("^(%s*)") or ""
end

local function split_comment(line)
  local before, comment = (line or ""):match("^(.-)(%s*\".*)$")
  if before then return before, comment end
  return line or "", ""
end

local function line_has_final_period(line)
  local code = split_comment(line)
  return trim(code):sub(-1) == "."
end

local function is_identifier(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function is_field_symbol(s)
  return type(s) == "string" and s:match("^<[%a_][%w_]*>$") ~= nil
end

local function statement_token_at(line, col)
  col = math.max(1, tonumber(col or 1))
  local best
  for s, token, e in (line or ""):gmatch("()([<]?[%a_][%w_]*[>]?)()") do
    if col >= s and col <= e then best = token end
  end
  return best
end

local function message_symbol(message)
  message = dec(message or "")
  local candidates = {}
  for quoted in message:gmatch('"([^"]+)"') do candidates[#candidates + 1] = quoted end
  for quoted in message:gmatch("'([^']+)'") do candidates[#candidates + 1] = quoted end
  for _, pat in ipairs({
    "[Ff]ield%s+([<]?[%w_]+[>]?)%s+is%s+unknown",
    "[Vv]ariable%s+([<]?[%w_]+[>]?)%s+is%s+unknown",
    "[Uu]nknown%s+field%s+([<]?[%w_]+[>]?)",
    "[Uu]nknown%s+variable%s+([<]?[%w_]+[>]?)",
    "([<]?[%w_]+[>]?)%s+is%s+unknown",
    "([<]?[%w_]+[>]?)%s+has%s+not%s+been%s+declared",
  }) do
    local found = message:match(pat)
    if found then candidates[#candidates + 1] = found end
  end
  for _, c in ipairs(candidates) do
    c = trim(c)
    if is_identifier(c) or is_field_symbol(c) then return c end
  end
  return nil
end

local function declaration_insert_line(lines, lnum)
  lnum = math.max(1, math.min(tonumber(lnum or 1), #lines))
  local opener
  for i = lnum, 1, -1 do
    local l = lines[i] or ""
    local ll = lower(l)
    if ll:match("^%s*method%s+[%w_]+%s*%.?%s*$")
      or ll:match("^%s*form%s+[%w_]+")
      or ll:match("^%s*module%s+[%w_]+")
      or ll:match("^%s*function%s+[%w_]+")
      or ll:match("^%s*start%-of%-selection%s*%.?%s*$")
      or ll:match("^%s*initialization%s*%.?%s*$") then
      opener = i
      break
    end
  end
  if not opener then
    for i = 1, lnum do
      local ll = lower(lines[i] or "")
      if ll:match("^%s*report%s+[%w_/]+%s*%.")
        or ll:match("^%s*program%s+[%w_/]+%s*%.") then
        opener = i
        break
      end
    end
  end
  if not opener then return math.max(0, lnum - 1), indentation(lines[lnum]) end

  local insert_after = opener
  while insert_after + 1 < lnum do
    local next_line = lower(lines[insert_after + 1] or "")
    if next_line:match("^%s*$")
      or next_line:match("^%s*data[%s:(]")
      or next_line:match("^%s*field%-symbols[%s:(]")
      or next_line:match("^%s*constants[%s:(]")
      or next_line:match("^%s*types[%s:(]")
      or next_line:match("^%s*statics[%s:(]")
      or next_line:match("^%s*class%-data[%s:(]") then
      insert_after = insert_after + 1
    else
      break
    end
  end

  local base_indent = indentation(lines[opener])
  local opener_l = lower(lines[opener] or "")
  if opener_l:match("^%s*report%s+") or opener_l:match("^%s*program%s+") then
    return insert_after, base_indent
  end
  return insert_after, base_indent .. "  "
end

local function data_decl_for(name, line)
  local code = lower(line or "")
  local name_l = lower(name)
  if name_l:match("^lo_") or name_l:match("^lr_") then
    return "DATA " .. name .. " TYPE REF TO object.", true
  end
  if name_l:match("^lt_") then
    return "DATA " .. name .. " TYPE STANDARD TABLE OF string WITH EMPTY KEY.", true
  end
  if code:match(name_l:gsub("([^%w_])", "%%%1") .. "%s*=%s*abap_") then
    return "DATA " .. name .. " TYPE abap_bool.", false
  end
  if code:match(name_l:gsub("([^%w_])", "%%%1") .. "%s*=%s*%-?%d+%f[%D]") then
    return "DATA " .. name .. " TYPE i.", false
  end
  if code:match(name_l:gsub("([^%w_])", "%%%1") .. "%s*=%s*'") then
    return "DATA " .. name .. " TYPE string.", false
  end
  return "DATA " .. name .. " TYPE string.", true
end

local function field_symbol_decl_for(name, line)
  local line_l = lower(line or "")
  local escaped_name = lower(name):gsub("([^%w_<>])", "%%%1")
  local table_name = line_l:match("loop%s+at%s+([%w_]+).-assigning%s+" .. escaped_name)
    or line_l:match("read%s+table%s+([%w_]+).-assigning%s+" .. escaped_name)
  if table_name then
    return "FIELD-SYMBOLS " .. name .. " LIKE LINE OF " .. table_name .. ".", false
  end
  return "FIELD-SYMBOLS " .. name .. " TYPE any.", true
end

local function add_action(actions, action)
  action.source = action.source or "local"
  actions[#actions + 1] = action
end

local function local_context_from_buffer(bufnr, opts)
  opts = opts or {}
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local cursor = vim.api.nvim_win_get_cursor(0)
  local lnum, col = cursor[1], cursor[2] + 1
  local message = opts.message
  if not message then
    local ok, qf = pcall(vim.fn.getqflist, { idx = 0, items = 0 })
    if ok and qf and qf.idx and qf.idx > 0 and qf.items and qf.items[qf.idx] then
      local item = qf.items[qf.idx]
      if (not item.bufnr or item.bufnr == 0 or item.bufnr == bufnr) then
        message = item.text
        if item.lnum and item.lnum > 0 then lnum = item.lnum end
        if item.col and item.col > 0 then col = item.col end
      end
    end
  end
  return {
    bufnr = bufnr,
    lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false),
    lnum = opts.lnum or lnum,
    col = opts.col or col,
    message = message or opts.text or "",
  }
end

function M._detect_local_actions(ctx)
  local lines = ctx.lines or {}
  local lnum = math.max(1, math.min(tonumber(ctx.lnum or 1), math.max(#lines, 1)))
  local col = tonumber(ctx.col or 1)
  local line = lines[lnum] or ""
  local message = dec(ctx.message or "")
  local msg_l = lower(message)
  local actions = {}

  local msg_sym = message_symbol(message)
  local cursor_sym = statement_token_at(line, col)
  local sym = msg_sym
  if msg_sym and cursor_sym and lower(msg_sym) == lower(cursor_sym) then
    sym = cursor_sym
  elseif not sym then
    sym = cursor_sym
  end
  if is_field_symbol(sym) and (msg_l:match("unknown") or msg_l:match("declared") or line:find(sym, 1, true)) then
    local insert_at, indent = declaration_insert_line(lines, lnum)
    local decl, ambiguous = field_symbol_decl_for(sym, line)
    add_action(actions, {
      id = "declare-field-symbol:" .. sym,
      title = "Declarar FIELD-SYMBOL " .. sym,
      ambiguous = ambiguous,
      edits = { { type = "insert", line = insert_at, lines = { indent .. decl } } },
    })
  elseif is_identifier(sym) and not lower(sym):match("^sy%-") then
    local sym_l = lower(sym)
    local has_variable_prefix = sym_l:match("^[lgmps][tvros]?_")
      or sym_l:match("^[ml]v_")
      or sym_l:match("^lt_")
      or sym_l:match("^ls_")
      or sym_l:match("^lo_")
      or sym_l:match("^lr_")
    local should_offer = msg_l:match("unknown")
      or msg_l:match("declared")
      or msg_l:match("does not exist")
      or has_variable_prefix
    if sym:match("^[A-Z][A-Z0-9_]+$") and not has_variable_prefix then
      should_offer = false
    end
    if should_offer then
      local insert_at, indent = declaration_insert_line(lines, lnum)
      local decl, ambiguous = data_decl_for(sym, line)
      add_action(actions, {
        id = "create-data:" .. sym,
        title = "Crear DATA " .. sym .. (ambiguous and " (revisar tipo)" or ""),
        ambiguous = ambiguous,
        edits = { { type = "insert", line = insert_at, lines = { indent .. decl } } },
      })
    end
  end

  local code, comment = split_comment(line)
  local stripped = trim(code)
  if stripped ~= "" and not line_has_final_period(line) then
    local safe_period = false
    if msg_l:match("period") or msg_l:match("punto") or msg_l:match("%.%s*expected") or msg_l:match("expected%s+\"%.\"") then
      safe_period = true
    end
    for _, pat in ipairs({
      "^DATA%s+[%w_]+%s+TYPE%s+[%w_/]+$",
      "^DATA%s*%(.+%)%s*=%s*.+$",
      "^FIELD%-SYMBOLS%s+<[%w_]+>%s+TYPE%s+[%w_/]+$",
      "^CLEAR%s+[%w_%-]+$",
      "^FREE%s+[%w_%-]+$",
      "^RETURN$",
      "^EXIT$",
      "^CONTINUE$",
      "^ENDIF$",
      "^ENDLOOP$",
      "^ENDTRY$",
      "^ENDMETHOD$",
      "^ENDFORM$",
      "^WRITE%s+.+$",
      "^MESSAGE%s+.+$",
      "^CHECK%s+.+$",
      "^ASSERT%s+.+$",
    }) do
      if stripped:upper():match(pat) then safe_period = true end
    end
    if safe_period and not stripped:match("[,:(=]$") and not stripped:upper():match("%s+(AND|OR)$") then
      add_action(actions, {
        id = "add-period",
        title = "Añadir punto final",
        ambiguous = false,
        edits = { { type = "replace_line", line = lnum - 1, text = code .. "." .. comment } },
      })
    end
  end

  if line:match("^%s*[Ii][Ff]%s+.+") and (msg_l:match("endif") or not line_has_final_period(line)) then
    add_action(actions, {
      id = "snippet-if",
      title = "Completar IF/ENDIF",
      ambiguous = true,
      edits = { { type = "insert", line = lnum, lines = { indentation(line) .. "  ", indentation(line) .. "ENDIF." } } },
    })
  elseif line:match("^%s*[Ll][Oo][Oo][Pp]%s+[Aa][Tt]%s+.+") then
    add_action(actions, {
      id = "snippet-loop",
      title = "Completar LOOP/ENDLOOP",
      ambiguous = true,
      edits = { { type = "insert", line = lnum, lines = { indentation(line) .. "  ", indentation(line) .. "ENDLOOP." } } },
    })
  elseif line:match("^%s*[Tt][Rr][Yy]%s*%.?%s*$") then
    add_action(actions, {
      id = "snippet-try",
      title = "Completar TRY/CATCH/ENDTRY",
      ambiguous = true,
      edits = { { type = "insert", line = lnum, lines = {
        indentation(line) .. "  ",
        indentation(line) .. "CATCH cx_root INTO DATA(lx_error).",
        indentation(line) .. "  MESSAGE lx_error->get_text( ) TYPE 'E'.",
        indentation(line) .. "ENDTRY.",
      } } },
    })
  end

  if line:match("^%s*[Cc][Rr][Ee][Aa][Tt][Ee]%s+[Oo][Bb][Jj][Ee][Cc][Tt]%s*$") then
    add_action(actions, {
      id = "snippet-create-object",
      title = "Completar CREATE OBJECT",
      ambiguous = true,
      edits = { { type = "replace_line", line = lnum - 1, text = indentation(line) .. "CREATE OBJECT lo_object." } },
    })
  elseif line:match("^%s*[Cc][Rr][Ee][Aa][Tt][Ee]%s+[Oo][Bb][Jj][Ee][Cc][Tt]%s+[%w_]+%s*$") and not line_has_final_period(line) then
    add_action(actions, {
      id = "complete-create-object-period",
      title = "Completar CREATE OBJECT con punto",
      ambiguous = false,
      edits = { { type = "replace_line", line = lnum - 1, text = code .. "." .. comment } },
    })
  end

  if msg_l:match("sy%-msg") or line:match("^%s*[Ii][Ff]%s+sy%-subrc%s*<>%s*0") or line:match("^%s*[Cc][Aa][Ll][Ll]%s+[Ff][Uu][Nn][Cc][Tt][Ii][Oo][Nn]") then
    local indent = indentation(line)
    if line:match("^%s*[Ii][Ff]%s+sy%-subrc%s*<>%s*0") then indent = indent .. "  " end
    add_action(actions, {
      id = "message-sy-msg",
      title = "Insertar MESSAGE ID sy-msgid",
      ambiguous = not msg_l:match("sy%-msg"),
      edits = { { type = "insert", line = lnum, lines = {
        indent .. "MESSAGE ID sy-msgid TYPE sy-msgty NUMBER sy-msgno",
        indent .. "  WITH sy-msgv1 sy-msgv2 sy-msgv3 sy-msgv4.",
      } } },
    })
  end

  return actions
end

function M._apply_action_to_lines(lines, action)
  local out = vim.deepcopy(lines or {})
  local edits = vim.deepcopy(action.edits or {})
  table.sort(edits, function(a, b) return (a.line or 0) > (b.line or 0) end)
  for _, e in ipairs(edits) do
    local idx = math.max(0, tonumber(e.line or 0))
    if e.type == "insert" then
      for i = #(e.lines or {}), 1, -1 do
        table.insert(out, idx + 1, e.lines[i])
      end
    elseif e.type == "replace_line" then
      out[idx + 1] = e.text or ""
    end
  end
  return out
end

local function apply_local_action(bufnr, action)
  local edits = vim.deepcopy(action.edits or {})
  table.sort(edits, function(a, b) return (a.line or 0) > (b.line or 0) end)
  for _, e in ipairs(edits) do
    local idx = math.max(0, tonumber(e.line or 0))
    if e.type == "insert" then
      vim.api.nvim_buf_set_lines(bufnr, idx, idx, false, e.lines or {})
    elseif e.type == "replace_line" then
      vim.api.nvim_buf_set_lines(bufnr, idx, idx + 1, false, { e.text or "" })
    end
  end
end

function M._preview_lines(ctx, action)
  local before = ctx.lines or {}
  local after = M._apply_action_to_lines(before, action)
  local min_line, max_line = #before, 1
  for _, e in ipairs(action.edits or {}) do
    min_line = math.min(min_line, (e.line or 0) + 1)
    max_line = math.max(max_line, (e.line or 0) + #(e.lines or { e.text }))
  end
  min_line = math.max(1, min_line - 3)
  max_line = math.min(math.max(#before, #after), max_line + 3)
  local out = {
    "Accion: " .. (action.title or action.id or "quickfix"),
    "Confianza: " .. (action.ambiguous and "requiere revision" or "segura"),
    "",
    "--- antes",
  }
  for i = min_line, math.min(max_line, #before) do
    out[#out + 1] = string.format("%4d  %s", i, before[i] or "")
  end
  out[#out + 1] = ""
  out[#out + 1] = "--- despues"
  for i = min_line, math.min(max_line, #after) do
    out[#out + 1] = string.format("%4d  %s", i, after[i] or "")
  end
  return out
end

local function show_preview(ctx, action)
  local lines = M._preview_lines(ctx, action)
  vim.cmd("botright new")
  local pbuf = vim.api.nvim_get_current_buf()
  vim.bo[pbuf].buftype = "nofile"
  vim.bo[pbuf].bufhidden = "wipe"
  vim.bo[pbuf].swapfile = false
  vim.bo[pbuf].filetype = "diff"
  vim.api.nvim_buf_set_name(pbuf, "sap-quickfix-preview")
  vim.api.nvim_buf_set_lines(pbuf, 0, -1, false, lines)
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = pbuf, silent = true, desc = "Cerrar preview" })
end

-- Parsea las propuestas: bloques <adtcore:objectReference .../> con adtcore:uri/name/description
-- y (si está) userContent. Devuelve { {adt_uri, name, desc, user} ... }.
local function parse_proposals(body)
  local out = {}
  if not body then return out end
  for tag in body:gmatch("<adtcore:objectReference[^>]->") do
    local adt_uri = tag:match('adtcore:uri="([^"]*)"')
    local name = tag:match('adtcore:name="([^"]*)"')
    local desc = tag:match('adtcore:description="([^"]*)"')
    if adt_uri and adt_uri ~= "" then
      out[#out + 1] = { adt_uri = dec(adt_uri), name = name or "", desc = dec(desc or (name or "fix")) }
    end
  end
  return out
end

-- Parsea los deltas de fixEdits: <unit> con <adtcore:objectReference adtcore:uri="..#start=l,c;end=l,c">
-- y <content>. Devuelve { {srow,scol,erow,ecol, content} ... }.
local function parse_deltas(body)
  local out = {}
  if not body then return out end
  for unit in body:gmatch("<unit>(.-)</unit>") do
    local ref = unit:match('adtcore:uri="([^"]*)"') or ""
    local sl, sc, el, ec = ref:match("start=(%d+),(%d+);end=(%d+),(%d+)")
    local content = unit:match("<content>(.-)</content>")
    if sl and content then
      out[#out + 1] = {
        srow = tonumber(sl), scol = tonumber(sc), erow = tonumber(el), ecol = tonumber(ec),
        content = dec(content),
      }
    end
  end
  return out
end

-- Aplica los deltas al buffer (orden inverso: de abajo a arriba, para no invalidar rangos).
local function apply_deltas(bufnr, deltas)
  table.sort(deltas, function(a, b)
    if a.srow ~= b.srow then return a.srow > b.srow end
    return a.scol > b.scol
  end)
  for _, d in ipairs(deltas) do
    -- ADT: línea 1-based, col 0-based -> nvim_buf_set_text usa 0-based en ambos.
    local ok = pcall(vim.api.nvim_buf_set_text, bufnr,
      math.max(0, d.srow - 1), d.scol, math.max(0, d.erow - 1), d.ecol,
      vim.split(d.content, "\n", { plain = true }))
    if not ok then notify("No se pudo aplicar un delta (rango fuera de sitio).", vim.log.levels.WARN) end
  end
end

local function local_quickfix(opts)
  opts = opts or {}
  local ctx = local_context_from_buffer(opts.bufnr, opts)
  local actions = M._detect_local_actions(ctx)
  if #actions == 0 then
    notify("Sin quick fixes locales para este contexto.", vim.log.levels.WARN)
    return false
  end

  local function choose(action)
    if not action then return end
    if opts.preview then
      show_preview(ctx, action)
      return
    end
    local function apply()
      apply_local_action(ctx.bufnr, action)
      notify("Quick fix aplicado: " .. (action.title or action.id) .. ". (u para deshacer)")
    end
    if action.ambiguous and opts.confirm ~= false then
      vim.ui.select({ "Aplicar", "Preview", "Cancelar" }, {
        prompt = "Quick fix ambiguo: " .. (action.title or action.id),
      }, function(choice)
        if choice == "Aplicar" then
          apply()
        elseif choice == "Preview" then
          show_preview(ctx, action)
        end
      end)
    else
      apply()
    end
  end

  if opts.action_id then
    for _, action in ipairs(actions) do
      if action.id == opts.action_id then choose(action); return true end
    end
    notify("No existe esa acción local: " .. tostring(opts.action_id), vim.log.levels.WARN)
    return false
  end

  if #actions == 1 then
    choose(actions[1])
  else
    vim.ui.select(actions, {
      prompt = "Quick fixes locales (" .. #actions .. "):",
      format_item = function(a) return a.title .. (a.ambiguous and " ?" or "") end,
    }, choose)
  end
  return true
end

local function remote_quickfix()
  if not adt_http.is_available() then return false end
  local intel = require("sap-nvim.core.intel")
  local bufnr = vim.api.nvim_get_current_buf()
  local uri = intel.object_uri(bufnr)
  if not uri then return false end
  local row, col = unpack(vim.api.nvim_win_get_cursor(0))
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")
  notify("Buscando quick fixes...")

  local ok, body = pcall(adt_http.request, {
    method = "POST",
    path = "/sap/bc/adt/quickfixes/evaluation",
    query = { uri = uri .. "#start=" .. row .. "," .. col },
    content_type = "application/*",
    accept = "application/*",
    body = src,
  })
  if not ok then
    notify("ADT quickfix falló; probando quickfix local.", vim.log.levels.WARN)
    return false
  end
  local proposals = parse_proposals(body)
  if #proposals == 0 then return false end

  vim.ui.select(proposals, {
    prompt = "Quick fixes (" .. #proposals .. "):",
    format_item = function(p) return p.desc ~= "" and p.desc or p.name end,
  }, function(choice)
    if not choice then return end
    -- fixEdits: POST a la uri de la propuesta, body proposalRequest (igual que abap-adt-api).
    local req = '<?xml version="1.0" encoding="UTF-8"?>'
      .. '<quickfixes:proposalRequest xmlns:quickfixes="http://www.sap.com/adt/quickfixes" '
      .. 'xmlns:adtcore="http://www.sap.com/adt/core"><input><content>' .. enc(src) .. '</content>'
      .. '<adtcore:objectReference adtcore:uri="' .. uri .. '#start=' .. row .. ',' .. col .. '"/>'
      .. '</input><userContent>' .. enc(choice.user or "") .. '</userContent></quickfixes:proposalRequest>'
    -- adt_http.request añade sap-client; la path es la adtcore:uri de la propuesta (puede traer ?query).
    local res = adt_http.request({
      method = "POST", path = choice.adt_uri,
      content_type = "application/*", accept = "application/*", body = req,
    })
    local deltas = parse_deltas(res)
    if #deltas == 0 then notify("El quick fix no devolvió cambios aplicables.", vim.log.levels.WARN); return end
    apply_deltas(bufnr, deltas)
    notify("Quick fix aplicado (" .. #deltas .. " cambio(s)). Revisa y guarda con :SapPush. (u para deshacer)")
  end)
  return true
end

function M.actions(opts)
  local ctx = local_context_from_buffer(opts and opts.bufnr or nil, opts)
  return M._detect_local_actions(ctx)
end

function M.preview(opts)
  opts = opts or {}
  opts.preview = true
  return local_quickfix(opts)
end

function M.apply(opts)
  opts = opts or {}
  return local_quickfix(opts)
end

function M.quickfix(opts)
  opts = opts or {}
  if opts.local_only then
    return local_quickfix(opts)
  end
  if remote_quickfix() then return true end
  return local_quickfix(opts)
end

function M.setup()
  vim.api.nvim_create_user_command("SapQuickfix", function() M.quickfix() end,
    { desc = "sap-nvim: Quick fixes / code actions bajo el cursor o quickfix actual" })
  vim.api.nvim_create_user_command("SapQuickfixPreview", function() M.preview() end,
    { desc = "sap-nvim: Preview de quick fixes locales sin tocar el buffer" })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_quickfix", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>aq", function() M.quickfix() end,
        { buffer = ev.buf, desc = "ABAP: Quick fixes / code actions" })
      vim.keymap.set("n", "<leader>aQ", function() M.preview() end,
        { buffer = ev.buf, desc = "ABAP: Preview quick fix" })
    end,
  })
end

return M
