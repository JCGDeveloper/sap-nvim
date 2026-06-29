-- sap-nvim.core.refactor
-- Refactors locales y offline para ABAP. No llama a SAP ni modifica objetos remotos.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function trim(s)
  return (s or ""):gsub("^%s+", ""):gsub("%s+$", "")
end

local function lower(s)
  return (s or ""):lower()
end

local function indent(line)
  return (line or ""):match("^(%s*)") or ""
end

local function clone_lines(lines)
  return vim.deepcopy(lines or {})
end

local function is_identifier(s)
  return type(s) == "string" and s:match("^[%a_][%w_]*$") ~= nil
end

local function is_field_symbol(s)
  return type(s) == "string" and s:match("^<[%a_][%w_]*>$") ~= nil
end

local function is_symbol(s)
  return is_identifier(s) or is_field_symbol(s)
end

local function escape_pat(s)
  return (s or ""):gsub("([^%w])", "%%%1")
end

local function word_pattern(sym)
  if is_field_symbol(sym) then
    return escape_pat(sym)
  end
  return "%f[%w_]" .. escape_pat(sym) .. "%f[^%w_]"
end

local function code_comment_split(line)
  local i, quote = 1, false
  while i <= #line do
    local c = line:sub(i, i)
    if c == "'" then
      if quote and line:sub(i + 1, i + 1) == "'" then
        i = i + 2
      else
        quote = not quote
        i = i + 1
      end
    elseif c == '"' and not quote then
      return line:sub(1, i - 1), line:sub(i)
    else
      i = i + 1
    end
  end
  return line, ""
end

local function replace_in_code(code, old, new)
  local pat = word_pattern(old)
  local out, count, i = {}, 0, 1

  while i <= #code do
    local c = code:sub(i, i)
    if c == "'" then
      local j = i + 1
      while j <= #code do
        if code:sub(j, j) == "'" then
          if code:sub(j + 1, j + 1) == "'" then
            j = j + 2
          else
            break
          end
        else
          j = j + 1
        end
      end
      table.insert(out, code:sub(i, math.min(j, #code)))
      i = math.min(j + 1, #code + 1)
    elseif c == "`" or c == "|" then
      local stop = c
      local j = i + 1
      while j <= #code and code:sub(j, j) ~= stop do
        j = j + 1
      end
      table.insert(out, code:sub(i, math.min(j, #code)))
      i = math.min(j + 1, #code + 1)
    else
      local j = i
      while j <= #code do
        local ch = code:sub(j, j)
        if ch == "'" or ch == "`" or ch == "|" then break end
        j = j + 1
      end
      local seg = code:sub(i, j - 1)
      local changed, line_count = seg:gsub(pat, new)
      count = count + line_count
      table.insert(out, changed)
      i = j
    end
  end

  return table.concat(out), count
end

local function replace_symbol_line(line, old, new)
  local code, comment = code_comment_split(line or "")
  local changed, count = replace_in_code(code, old, new)
  return changed .. comment, count
end

local function symbol_at(line, col)
  col = math.max(1, tonumber(col or 1))
  for s, token, e in (line or ""):gmatch("()(<[%a_][%w_]*>)()") do
    if col >= s and col <= e then return token end
  end
  for s, token, e in (line or ""):gmatch("()([%a_][%w_]*)()") do
    if col >= s and col <= e then return token end
  end
  return nil
end

local function find_enclosing_block(lines, lnum)
  local depth = 0
  for i = lnum, 1, -1 do
    local ll = lower(lines[i] or "")
    if ll:match("^%s*endmethod%s*%.") or ll:match("^%s*endform%s*%.") then
      depth = depth + 1
    else
      local m = ll:match("^%s*method%s+([%w_~]+)%s*%.")
      local f = ll:match("^%s*form%s+([%w_]+)")
      if m or f then
        if depth == 0 then
          local end_pat = m and "^%s*endmethod%s*%." or "^%s*endform%s*%."
          for j = i + 1, #lines do
            if lower(lines[j] or ""):match(end_pat) then
              return { kind = m and "method" or "form", name = m or f, first = i, last = j }
            end
          end
          return { kind = m and "method" or "form", name = m or f, first = i, last = #lines }
        end
        depth = depth - 1
      end
    end
  end
  return { kind = "buffer", first = 1, last = #lines }
end

local function method_context(lines, lnum)
  local block = find_enclosing_block(lines, lnum)
  if block.kind ~= "method" then return nil end

  local impl_first, impl_last
  for i = block.first, 1, -1 do
    local class = lower(lines[i] or ""):match("^%s*class%s+([%w_]+)%s+implementation%s*%.")
    if class then
      impl_first = i
      break
    end
  end
  if impl_first then
    for i = block.last + 1, #lines do
      if lower(lines[i] or ""):match("^%s*endclass%s*%.") then
        impl_last = i
        break
      end
    end
  end
  return {
    block = block,
    impl_first = impl_first,
    impl_last = impl_last,
    class_name = impl_first and trim((lines[impl_first] or ""):match("^%s*[Cc][Ll][Aa][Ss][Ss]%s+([%w_]+)") or "") or nil,
  }
end

local function class_def_range(lines, class_name)
  if not class_name or class_name == "" then return nil end
  local wanted = lower(class_name)
  for i, line in ipairs(lines) do
    local name = lower(line):match("^%s*class%s+([%w_]+)%s+definition")
    if name == wanted then
      for j = i + 1, #lines do
        if lower(lines[j] or ""):match("^%s*endclass%s*%.") then
          return { first = i, last = j }
        end
      end
    end
  end
  return nil
end

local function method_decl_exists(lines, class_name, name)
  local r = class_def_range(lines, class_name)
  if not r then return false end
  local pat = "^%s*methods%s+" .. escape_pat(lower(name)) .. "%f[^%w_]"
  for i = r.first, r.last do
    if lower(lines[i] or ""):match(pat) then return true end
  end
  return false
end

local function method_impl_exists(lines, name)
  local pat = "^%s*method%s+" .. escape_pat(lower(name)) .. "%s*%."
  for _, line in ipairs(lines) do
    if lower(line):match(pat) then return true end
  end
  return false
end

local function add_method_declaration(lines, class_name, name)
  if method_decl_exists(lines, class_name, name) then return lines, false end
  local r = class_def_range(lines, class_name)
  if not r then return lines, false end

  local insert_at
  for i = r.first + 1, r.last - 1 do
    if lower(lines[i] or ""):match("^%s*private%s+section%s*%.") then
      insert_at = i
      break
    end
  end
  if not insert_at then
    for i = r.first + 1, r.last - 1 do
      if lower(lines[i] or ""):match("^%s*protected%s+section%s*%.")
        or lower(lines[i] or ""):match("^%s*public%s+section%s*%.") then
        insert_at = i
        break
      end
    end
  end
  if not insert_at then return lines, false end

  table.insert(lines, insert_at + 1, indent(lines[insert_at]) .. "  METHODS " .. name .. ".")
  return lines, true
end

local function insert_lines_at(lines, after, new_lines)
  for i = #new_lines, 1, -1 do
    table.insert(lines, after + 1, new_lines[i])
  end
end

local function diff_lines(before, after)
  local out = {}
  local max = math.max(#before, #after)
  for i = 1, max do
    if before[i] ~= after[i] then
      out[#out + 1] = string.format("%4d - %s", i, before[i] or "")
      out[#out + 1] = string.format("%4d + %s", i, after[i] or "")
    end
  end
  return out
end

local function preview_buffer(title, preview)
  vim.cmd("botright new")
  local buf = vim.api.nvim_get_current_buf()
  vim.bo[buf].buftype = "nofile"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].swapfile = false
  vim.bo[buf].filetype = "diff"
  vim.api.nvim_buf_set_name(buf, title)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, preview)
end

local function apply_with_preview(bufnr, before, after, title, opts)
  opts = opts or {}
  if table.concat(before, "\n") == table.concat(after, "\n") then
    notify("Refactor sin cambios aplicables.", vim.log.levels.WARN)
    return false
  end

  local preview = diff_lines(before, after)
  if opts.preview ~= false then
    preview_buffer(title or "SapRefactor preview", preview)
  end

  local function apply()
    vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, after)
    notify("Refactor aplicado en el buffer actual.")
  end

  if opts.confirm == false then
    apply()
    return true
  end

  vim.ui.select({ "Aplicar", "Cancelar" }, { prompt = "Aplicar refactor offline al buffer?" }, function(choice)
    if choice == "Aplicar" then
      apply()
    else
      notify("Refactor cancelado.", vim.log.levels.INFO)
    end
  end)
  return true
end

function M._rename_lines(lines, old, new, lnum)
  if not is_symbol(old) or not is_symbol(new) then
    return nil, "Nombre ABAP no valido"
  end
  local out = clone_lines(lines)
  local block = find_enclosing_block(out, lnum or 1)
  local occurrences = 0
  for i = block.first, block.last do
    local count
    out[i], count = replace_symbol_line(out[i], old, new)
    occurrences = occurrences + count
  end
  return out, nil, { scope = block, occurrences = occurrences }
end

local function clean_helper_name(name)
  name = trim(name or ""):gsub("-", "_")
  if name == "" then return nil end
  if not is_identifier(name) then return nil end
  return name
end

function M._extract_lines(lines, first, last, name)
  name = clean_helper_name(name)
  if not name then return nil, "Nombre de helper no valido" end
  if first > last then first, last = last, first end
  first = math.max(1, first)
  last = math.min(#lines, last)
  if first > last then return nil, "Seleccion vacia" end

  local out = clone_lines(lines)
  local selected = {}
  for i = first, last do
    selected[#selected + 1] = out[i]
  end

  local block = find_enclosing_block(out, first)
  if block.kind == "method" then
    local ctx = method_context(out, first)
    for _ = first, last do table.remove(out, first) end
    table.insert(out, first, indent(lines[first]) .. "me->" .. name .. "( ).")
    block = find_enclosing_block(out, first)
    local method_indent = indent(out[block.first])
    local body = { "", method_indent .. "METHOD " .. name .. "." }
    for _, line in ipairs(selected) do body[#body + 1] = line end
    body[#body + 1] = method_indent .. "ENDMETHOD."
    insert_lines_at(out, block.last, body)
    if ctx and ctx.class_name then
      out = add_method_declaration(out, ctx.class_name, name)
    end
    return out, nil, { kind = "method", name = name }
  end

  for _ = first, last do table.remove(out, first) end
  table.insert(out, first, indent(lines[first]) .. "PERFORM " .. name .. ".")
  local insert_after = #out
  if block.kind == "form" then
    insert_after = find_enclosing_block(out, first).last
  end
  local form = { "", "FORM " .. name .. "." }
  for _, line in ipairs(selected) do form[#form + 1] = line end
  form[#form + 1] = "ENDFORM."
  insert_lines_at(out, insert_after, form)
  return out, nil, { kind = "form", name = name }
end

local function call_under_cursor(line, col)
  local token = symbol_at(line, col)
  local ll = lower(line or "")
  local perform = ll:match("^%s*perform%s+([%w_]+)")
  if perform then return perform, "form" end

  local me_call = (line or ""):match("[Mm][Ee]%s*%-%>%s*([%a_][%w_]*)%s*%(")
  if me_call then return me_call, "method" end
  local simple = (line or ""):match("^%s*([%a_][%w_]*)%s*%(")
  if simple then return simple, "method" end
  if token and is_identifier(token) then return token, "method" end
  return nil, nil
end

function M._create_stub_lines(lines, lnum, col, explicit_name)
  local name, kind = explicit_name, nil
  if name and name:match("^form:") then
    kind = "form"
    name = name:gsub("^form:", "")
  elseif name and name:match("^method:") then
    kind = "method"
    name = name:gsub("^method:", "")
  else
    name, kind = call_under_cursor(lines[lnum] or "", col or 1)
  end
  name = clean_helper_name(name)
  if not name then return nil, "No pude detectar una llamada ABAP valida" end

  local out = clone_lines(lines)
  if kind == "form" then
    local pat = "^%s*form%s+" .. escape_pat(lower(name)) .. "%f[^%w_]"
    for _, line in ipairs(out) do
      if lower(line):match(pat) then return out, nil, { exists = true, kind = "form", name = name } end
    end
    insert_lines_at(out, #out, { "", "FORM " .. name .. ".", "ENDFORM." })
    return out, nil, { kind = "form", name = name }
  end

  if method_impl_exists(out, name) then return out, nil, { exists = true, kind = "method", name = name } end
  local ctx = method_context(out, lnum or 1)
  if ctx and ctx.class_name then
    out = add_method_declaration(out, ctx.class_name, name)
    ctx = method_context(out, (lnum or 1) + 1) or ctx
  end
  local insert_after = (ctx and ctx.impl_last and ctx.impl_last - 1) or #out
  local base_indent = ctx and ctx.block and indent(ctx.block.first and out[ctx.block.first] or "") or "  "
  insert_lines_at(out, insert_after, {
    "",
    base_indent .. "METHOD " .. name .. ".",
    base_indent .. "ENDMETHOD.",
  })
  return out, nil, { kind = "method", name = name }
end

local function current_class_name(lines)
  for _, line in ipairs(lines) do
    local name = line:match("^%s*[Cc][Ll][Aa][Ss][Ss]%s+([%w_]+)%s+[Dd][Ee][Ff][Ii][Nn][Ii][Tt][Ii][Oo][Nn]")
    if name and not lower(name):match("^ltcl_") then return name end
  end
  for _, line in ipairs(lines) do
    local name = line:match("^%s*[Cc][Ll][Aa][Ss][Ss]%s+([%w_]+)%s+[Ii][Mm][Pp][Ll][Ee][Mm][Ee][Nn][Tt][Aa][Tt][Ii][Oo][Nn]")
    if name and not lower(name):match("^ltcl_") then return name end
  end
  return nil
end

local function test_class_name(class_name)
  local base = lower(class_name or "cut"):gsub("^zcl_", ""):gsub("[^%w_]", "_")
  local name = "ltcl_" .. base
  if #name > 30 then name = name:sub(1, 30) end
  return name
end

function M._generate_test_class_lines(lines, class_name)
  local out = clone_lines(lines)
  if table.concat(out, "\n"):lower():match("for%s+testing") then
    return out, nil, { exists = true }
  end
  class_name = class_name or current_class_name(out)
  local test_name = test_class_name(class_name)
  local skeleton = {
    "",
    "CLASS " .. test_name .. " DEFINITION FINAL FOR TESTING",
    "  DURATION SHORT",
    "  RISK LEVEL HARMLESS.",
    "  PRIVATE SECTION.",
    "    METHODS smoke FOR TESTING.",
    "ENDCLASS.",
    "",
    "CLASS " .. test_name .. " IMPLEMENTATION.",
    "  METHOD smoke.",
    "    cl_abap_unit_assert=>assert_true( abap_true ).",
    "  ENDMETHOD.",
    "ENDCLASS.",
  }

  local insert_after = #out
  for i, line in ipairs(out) do
    if lower(line):match("^%s*class%s+[%w_]+%s+implementation%s*%.") then
      insert_after = i - 1
      break
    end
  end
  insert_lines_at(out, insert_after, skeleton)
  return out, nil, { name = test_name }
end

local function parse_interfaces(lines)
  local defs, current = {}, nil
  for _, line in ipairs(lines) do
    local ll = lower(line)
    local iface = ll:match("^%s*interface%s+([%w_]+)%s*%.")
    if iface then
      current = iface
      defs[current] = defs[current] or {}
    elseif current and ll:match("^%s*endinterface%s*%.") then
      current = nil
    elseif current then
      local m = ll:match("^%s*methods%s+([%w_]+)%f[^%w_]")
      if m then table.insert(defs[current], m) end
    end
  end
  defs.if_oo_adt_classrun = defs.if_oo_adt_classrun or { "main" }
  return defs
end

local function class_interfaces(lines)
  local out = {}
  local current
  for _, line in ipairs(lines) do
    local ll = lower(line)
    local class = ll:match("^%s*class%s+([%w_]+)%s+definition")
    if class then
      current = class
      out[current] = out[current] or {}
    elseif current and ll:match("^%s*endclass%s*%.") then
      current = nil
    elseif current then
      local iface = ll:match("^%s*interfaces%s+([%w_]+)%s*%.")
      if iface then table.insert(out[current], iface) end
    end
  end
  return out
end

local function interface_method_exists(lines, iface, method)
  local pat = "^%s*method%s+" .. escape_pat(lower(iface)) .. "~" .. escape_pat(lower(method)) .. "%s*%."
  for _, line in ipairs(lines) do
    if lower(line):match(pat) then return true end
  end
  return false
end

function M._implement_interface_lines(lines)
  local out = clone_lines(lines)
  local defs = parse_interfaces(out)
  local classes = class_interfaces(out)
  local added = 0

  for class_name, ifaces in pairs(classes) do
    local impl_last
    for i, line in ipairs(out) do
      if lower(line):match("^%s*class%s+" .. escape_pat(class_name) .. "%s+implementation%s*%.") then
        for j = i + 1, #out do
          if lower(out[j] or ""):match("^%s*endclass%s*%.") then
            impl_last = j
            break
          end
        end
      end
    end
    if not impl_last then
      insert_lines_at(out, #out, { "", "CLASS " .. class_name .. " IMPLEMENTATION.", "ENDCLASS." })
      impl_last = #out
    end

    local to_insert = {}
    for _, iface in ipairs(ifaces) do
      for _, method in ipairs(defs[iface] or {}) do
        if not interface_method_exists(out, iface, method) then
          to_insert[#to_insert + 1] = ""
          to_insert[#to_insert + 1] = "  METHOD " .. iface .. "~" .. method .. "."
          to_insert[#to_insert + 1] = "  ENDMETHOD."
          added = added + 1
        end
      end
    end
    if #to_insert > 0 then
      insert_lines_at(out, impl_last - 1, to_insert)
    end
  end

  if added == 0 then return out, "No se detectaron metodos de interface pendientes" end
  return out, nil, { added = added }
end

local function buffer_lines(bufnr)
  return vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
end

function M.rename_local(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local pos = opts.pos or vim.api.nvim_win_get_cursor(0)
  local lines = buffer_lines(bufnr)
  local old = opts.old or symbol_at(lines[pos[1]] or "", (pos[2] or 0) + 1)
  if not old then
    notify("No hay simbolo ABAP bajo el cursor.", vim.log.levels.WARN)
    return
  end
  local function run(new)
    local after, err, meta = M._rename_lines(lines, old, trim(new or ""), pos[1])
    if err then
      notify(err, vim.log.levels.WARN)
      return
    end
    apply_with_preview(bufnr, lines, after, "SapRenameLocal: " .. old .. " -> " .. new, opts)
    if meta and meta.occurrences == 0 then
      notify("No se encontraron ocurrencias en el scope local.", vim.log.levels.WARN)
    end
  end
  if opts.new_name then
    run(opts.new_name)
  else
    vim.ui.input({ prompt = "Nuevo nombre para " .. old .. ": ", default = old }, run)
  end
end

function M.extract_method(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local first = opts.first or vim.fn.line("'<")
  local last = opts.last or vim.fn.line("'>")
  local lines = buffer_lines(bufnr)
  local function run(name)
    local after, err = M._extract_lines(lines, first, last, name)
    if err then
      notify(err, vim.log.levels.WARN)
      return
    end
    apply_with_preview(bufnr, lines, after, "SapExtractMethod: " .. name, opts)
  end
  if opts.name then
    run(opts.name)
  else
    vim.ui.input({ prompt = "Nombre del helper extraido: ", default = "helper" }, run)
  end
end

function M.create_method_stub(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local pos = opts.pos or vim.api.nvim_win_get_cursor(0)
  local lines = buffer_lines(bufnr)
  local after, err = M._create_stub_lines(lines, pos[1], (pos[2] or 0) + 1, opts.name)
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end
  apply_with_preview(bufnr, lines, after, "SapCreateMethodStub", opts)
end

function M.generate_test_class(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lines = buffer_lines(bufnr)
  local after, err = M._generate_test_class_lines(lines, opts.class_name)
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end
  apply_with_preview(bufnr, lines, after, "SapGenerateTestClass", opts)
end

function M.implement_interface(opts)
  opts = opts or {}
  local bufnr = opts.bufnr or vim.api.nvim_get_current_buf()
  local lines = buffer_lines(bufnr)
  local after, err = M._implement_interface_lines(lines)
  if err then
    notify(err, vim.log.levels.WARN)
    return
  end
  apply_with_preview(bufnr, lines, after, "SapImplementInterface", opts)
end

function M.refactor_picker()
  local actions = {
    { label = "Rename local/simbolo", run = M.rename_local },
    { label = "Extraer METHOD/FORM desde seleccion", run = M.extract_method },
    { label = "Crear METHOD/FORM stub desde llamada", run = M.create_method_stub },
    { label = "Generar clase de test ABAP Unit", run = M.generate_test_class },
    { label = "Implementar skeleton de interface", run = M.implement_interface },
  }
  vim.ui.select(actions, {
    prompt = "SapRefactor offline",
    format_item = function(item) return item.label end,
  }, function(item)
    if item then item.run() end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapRefactor", function()
    M.refactor_picker()
  end, { desc = "sap-nvim: refactors ABAP offline con preview" })

  vim.api.nvim_create_user_command("SapRenameLocal", function(cmd)
    M.rename_local({ new_name = cmd.args ~= "" and cmd.args or nil })
  end, { nargs = "?", desc = "sap-nvim: renombrar simbolo local offline" })

  vim.api.nvim_create_user_command("SapExtractMethod", function(cmd)
    M.extract_method({ name = cmd.args ~= "" and cmd.args or nil, first = cmd.line1, last = cmd.line2 })
  end, { nargs = "?", range = true, desc = "sap-nvim: extraer METHOD/FORM offline" })

  vim.api.nvim_create_user_command("SapCreateMethodStub", function(cmd)
    M.create_method_stub({ name = cmd.args ~= "" and cmd.args or nil })
  end, { nargs = "?", desc = "sap-nvim: crear stub METHOD/FORM offline" })

  vim.api.nvim_create_user_command("SapGenerateTestClass", function(cmd)
    M.generate_test_class({ class_name = cmd.args ~= "" and cmd.args or nil })
  end, { nargs = "?", desc = "sap-nvim: generar clase local ABAP Unit offline" })

  vim.api.nvim_create_user_command("SapImplementInterface", function()
    M.implement_interface()
  end, { desc = "sap-nvim: implementar skeleton de INTERFACES offline" })
end

M._test = {
  replace_symbol_line = replace_symbol_line,
  symbol_at = symbol_at,
  find_enclosing_block = find_enclosing_block,
  rename_lines = M._rename_lines,
  extract_lines = M._extract_lines,
  create_stub_lines = M._create_stub_lines,
  generate_test_class_lines = M._generate_test_class_lines,
  implement_interface_lines = M._implement_interface_lines,
}

return M
