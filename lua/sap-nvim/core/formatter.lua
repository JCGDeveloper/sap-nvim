-- sap-nvim.core.formatter
-- Native ABAP and CDS formatter.
-- Dispatches automatically based on file extension.

local M = {}

-- ─── ABAP ──────────────────────────────────────────────────────────────────

local KEYWORDS = {
  "start-of-selection", "end-of-selection",
  "load-of-program", "line-selection", "user-command",
  "top-of-page", "end-of-page", "pf-status",
  "field-symbols", "select-options",
  "report", "program", "function", "endfunction", "form", "endform",
  "module", "endmodule", "method", "endmethod", "class", "endclass",
  "interface", "endinterface", "define", "enddefine",
  "if", "endif", "else", "elseif", "when", "case", "endcase",
  "do", "endo", "while", "endwhile", "loop", "endloop",
  "try", "endtry", "catch", "cleanup", "resumable",
  "select", "endselect", "at", "endat", "provide", "endprovide",
  "and", "or", "not", "eq", "ne", "lt", "le", "gt", "ge",
  "is", "in", "between", "like", "covers",
  "data", "types", "constants",
  "parameters", "tables", "ranges",
  "type", "value", "ref", "to", "for", "importing",
  "exporting", "changing", "returning", "raising",
  "write", "read", "move", "append", "insert", "delete", "modify",
  "call", "submit", "leave", "exit", "check", "stop", "reject",
  "create", "describe", "sort", "translate", "search",
  "concatenate", "split", "condense", "replace", "shift",
  "clear", "refresh", "free", "collect", "compute",
  "set", "get", "add", "subtract", "multiply", "divide",
  "raise", "resume", "retry", "continue",
  "into", "from", "where", "having", "group", "by", "order",
  "up", "down", "first", "last", "ascending", "descending",
  "primary", "key", "unique", "sorted", "hashed", "index",
  "single", "member", "line", "table", "structure", "work",
  "area", "fields", "joining", "inner", "outer", "left", "right",
  "as", "using", "client", "specified", "specifying",
  "corresponding", "exact", "pattern", "occurrence", "offset",
  "length", "initial", "space", "zero",
  "public", "protected", "private", "section",
  "abstract", "final", "read-only", "redefinition",
  "super", "friend", "local", "global",
  "new", "export", "import", "deferred",
  "init",
  -- Declaraciones de clase/interface (compuestas — antes faltaban: CLASS-METHODS, etc.)
  "methods", "class-methods", "class-data", "class-events", "events",
  "aliases", "definition", "implementation", "inheriting", "instantiation",
  "testing", "duration", "level", "risk",
  "begin", "end", "of", "with", "without",
  "exceptions", "message", "default", "optional", "preferred",
  "instance", "static", "constructor",
  -- Operadores de la nueva sintaxis (constructor expressions)
  "cond", "switch", "conv", "cast", "reduce", "filter", "base", "let",
  "corresponding", "mapping", "except", "discarding", "duplicates",
  "assigning", "transporting", "reference", "casting", "bound",
  "respecting", "blanks", "no-gaps", "lines", "next",
}

local BLOCK_START = {
  "if", "do", "while", "loop", "at",
  "method", "form", "module", "function", "class", "interface",
  "define", "try", "select", "case", "provide",
  "else", "elseif", "when", "catch", "cleanup",
  "start-of-selection", "load-of-program",
  "init", "top-of-page", "end-of-page", "line-selection",
}

local BLOCK_END = {
  "endif", "endo", "endwhile", "endloop", "endat",
  "endmethod", "endform", "endmodule", "endfunction",
  "endclass", "endinterface", "enddefine", "endtry",
  "endselect", "endcase", "endprovide",
  "end-of-selection",
  "else", "elseif", "when", "catch", "cleanup",
}

local keyword_set     = {}
local block_start_set = {}
local block_end_set   = {}

for _, kw in ipairs(KEYWORDS)    do keyword_set[kw:lower()]     = true end
for _, kw in ipairs(BLOCK_START) do block_start_set[kw:lower()] = true end
for _, kw in ipairs(BLOCK_END)   do block_end_set[kw:lower()]   = true end

local function levenshtein(a, b)
  local la, lb = #a, #b
  local m = {}
  for i = 0, la do m[i] = { [0] = i } end
  for j = 0, lb do m[0][j] = j end
  for i = 1, la do
    for j = 1, lb do
      local cost = a:sub(i, i) == b:sub(j, j) and 0 or 1
      m[i][j] = math.min(m[i-1][j]+1, m[i][j-1]+1, m[i-1][j-1]+cost)
    end
  end
  return m[la][lb]
end

local function autocomplete_word(word)
  local lower = word:lower()
  if keyword_set[lower] then return word end

  local matches = {}
  for _, kw in ipairs(KEYWORDS) do
    if kw:sub(1, #lower) == lower then table.insert(matches, kw) end
  end
  if #matches == 1 then return matches[1]:upper() end

  local best_dist, best_kw = 3, nil
  for _, kw in ipairs(KEYWORDS) do
    local d = levenshtein(lower, kw)
    if d < best_dist then best_dist = d; best_kw = kw end
  end
  if best_kw and #lower >= 4 and best_dist <= math.floor(#lower / 3) then
    return best_kw:upper()
  end

  return word
end

-- Parse a line into segments so we can skip string literal content.
-- Each segment: { text = "...", literal = true|false }
-- literal=true  → string literal or comment, must NOT be uppercased
-- literal=false → code, apply keyword uppercasing
local function tokenize(line)
  local segs = {}
  local i, len = 1, #line

  while i <= len do
    local c = line:sub(i, i)

    if c == "'" then
      -- ABAP string literal; handle '' as escaped quote inside
      local j = i + 1
      while j <= len do
        if line:sub(j, j) == "'" then
          if line:sub(j+1, j+1) == "'" then j = j + 2
          else break end
        else j = j + 1 end
      end
      table.insert(segs, { text = line:sub(i, j), literal = true })
      i = j + 1

    elseif c == "`" then
      -- Template literal (ABAP string templates |...|), treat same
      local j = i + 1
      while j <= len and line:sub(j, j) ~= "`" do j = j + 1 end
      table.insert(segs, { text = line:sub(i, j), literal = true })
      i = j + 1

    elseif c == '"' then
      -- Inline comment: rest of line is literal
      table.insert(segs, { text = line:sub(i), literal = true })
      break

    else
      -- Code: collect until quote or comment starts
      local j = i
      while j <= len do
        local ch = line:sub(j, j)
        if ch == "'" or ch == "`" or ch == '"' then break end
        j = j + 1
      end
      if j > i then
        table.insert(segs, { text = line:sub(i, j-1), literal = false })
      end
      i = j
    end
  end

  return segs
end

local function uppercase_keywords(line)
  local segs = tokenize(line)
  local out = {}
  for _, seg in ipairs(segs) do
    if seg.literal then
      table.insert(out, seg.text)
    else
      -- SOLO mayúsculas en keywords EXACTOS. Nada de autocompletar/corregir por
      -- similitud: eso corrompería identificadores (p.ej. una variable `da` → `DATA`).
      local processed = seg.text:gsub("([%a_][%w_%-]*)", function(word)
        if keyword_set[word:lower()] then return word:upper() end
        return word
      end)
      -- Nueva sintaxis: forzar espacio antes de `#(` (constructor: VALUE #( ), COND #( ),
      -- NEW #( )...). `#(` solo aparece en constructores, así que es seguro.
      processed = processed:gsub("([%w_])#%(", "%1 #(")
      table.insert(out, processed)
    end
  end
  return table.concat(out)
end

-- Colapsa espacios múltiples a uno, pero SOLO en segmentos de código — nunca dentro de
-- literales de cadena ('...', `...`, |...|) ni comentarios, para no corromper el texto.
local function clean_spacing(line)
  line = line:gsub("%s+$", "")
  local indent = line:match("^(%s*)")
  local rest   = line:match("^%s*(.*)$")
  if not rest or rest == "" then return indent end
  local out = {}
  for _, seg in ipairs(tokenize(rest)) do
    if seg.literal then
      table.insert(out, seg.text)
    else
      table.insert(out, (seg.text:gsub("%s+", " ")))
    end
  end
  return indent .. table.concat(out)
end

local function get_main_keyword(line)
  local content = line:match("^%s*(.*)$") or ""
  if content:match("^%*") or content:match("^\"") then return nil end
  local first = content:match("^([%a_][%w_%-]*)")
  if first then return first:lower() end
  return nil
end

local function format_abap_line(line, indent)
  if line:match("^%s*$") then return "", indent end

  local content = line:match("^%s*(.*)$") or ""

  if content:match("^%*") or content:match("^\"") then
    return string.rep("  ", indent) .. content, indent
  end

  local kw = get_main_keyword(line)

  if kw and block_end_set[kw] then
    indent = math.max(0, indent - 1)
  end

  content = uppercase_keywords(content)
  content = clean_spacing(content)

  local formatted = string.rep("  ", indent) .. content

  if kw and block_start_set[kw] then
    indent = indent + 1
  end

  return formatted, indent
end

function M.format_abap()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = {}
  local indent = 0
  local warnings = {}

  for i, line in ipairs(lines) do
    local formatted, new_indent = format_abap_line(line, indent)
    table.insert(result, formatted)
    indent = new_indent

    local content = line:match("^%s*(.-)%s*$") or ""
    if content:upper():match("^REPORT%s*%.?$") then
      table.insert(warnings, "L" .. i .. ": REPORT missing program name")
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)

  if #warnings > 0 then
    vim.notify("[sap-nvim] " .. table.concat(warnings, "\n"), vim.log.levels.WARN)
  else
    vim.notify("[sap-nvim] ABAP formatted.", vim.log.levels.INFO)
  end
end

-- ─── CDS ───────────────────────────────────────────────────────────────────
-- CDS/DDL uses brace-based indentation; annotations (@) and comments (//)
-- are preserved. Keywords are NOT uppercased — CDS is mixed-case by convention.

local function format_cds_line(line, indent)
  if line:match("^%s*$") then return "", indent end

  local content = line:match("^%s*(.-)%s*$") or ""

  -- Annotations and comments: keep at current indent, no block change
  if content:match("^@") or content:match("^//") or content:match("^/%*") then
    return string.rep("  ", indent) .. content, indent
  end

  -- Closing brace decrements BEFORE formatting
  local closes = content:match("^}") ~= nil
  -- Opening brace increments AFTER formatting
  -- A line can have both (e.g. "} {" is unusual but handle safely)
  local opens = content:find("{") ~= nil and not closes

  if closes then indent = math.max(0, indent - 1) end

  -- Clean spacing but preserve content (no keyword uppercasing)
  content = content:gsub("%s+$", ""):gsub("%s+", " ")
  local formatted = string.rep("  ", indent) .. content

  if opens then indent = indent + 1 end

  return formatted, indent
end

function M.format_cds()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local result = {}
  local indent = 0

  for _, line in ipairs(lines) do
    local formatted, new_indent = format_cds_line(line, indent)
    table.insert(result, formatted)
    indent = new_indent
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)
  vim.notify("[sap-nvim] CDS formatted.", vim.log.levels.INFO)
end

-- ─── Pretty Printer REAL de SAP (ADT) ───────────────────────────────────────
-- Es el mismo formateador que SE80/ADT y la extensión de VSCode: capitaliza keywords
-- (incl. compuestos como CLASS-METHODS), mantiene identificadores, respeta la nueva
-- sintaxis. Muy superior al formateador por regex. Se usa para objetos remotos
-- (con conexión); si falla o no hay conexión, cae al formateador nativo.
function M.format_via_adt()
  local adt_http = require("sap-nvim.core.adt_http")
  if not adt_http.is_available() then return false end
  local bufnr = vim.api.nvim_get_current_buf()
  local src = table.concat(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), "\n")

  local body = adt_http.request({
    method = "POST",
    path = "/sap/bc/adt/abapsource/prettyprinter",
    body = src,
    content_type = "text/plain",
  })
  -- Respuesta válida = código formateado (texto plano). Una excepción ADT trae '<exc:' o
  -- '<?xml' de error: en ese caso no tocamos el buffer.
  if not body or body == "" or body:match("^%s*<") then return false end

  local view = vim.fn.winsaveview()
  -- ADT puede devolver \r\n o \r: normalizamos a \n antes de partir en líneas.
  local norm = body:gsub("\r\n", "\n"):gsub("\r", "\n")
  local lines = vim.split(norm:gsub("\n$", ""), "\n")
  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, lines)
  vim.fn.winrestview(view)
  vim.notify("[sap-nvim] Formateado con el Pretty Printer de SAP.", vim.log.levels.INFO)
  return true
end

-- ─── Dispatcher ────────────────────────────────────────────────────────────

local CDS_EXTS = { ddls = true, dcl = true, bdef = true, ddlx = true, asddls = true, cds = true }

function M.format_file()
  local ext = vim.fn.expand("%:e"):lower()
  if CDS_EXTS[ext] then
    M.format_cds()
    return
  end
  -- ABAP: intentar el Pretty Printer de SAP (objeto remoto + conexión); si no, regex nativo.
  if vim.b.sap_obj and M.format_via_adt() then return end
  M.format_abap()
end

function M.setup() end

return M
