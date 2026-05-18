-- sap-nvim.core.formatter
-- Formateador ABAP nativo en Lua
-- No requiere herramientas externas
-- Convierte keywords a mayúsculas, indentación correcta, espaciado consistente

local M = {}

-- Keywords ABAP que deben ir en mayúsculas
local KEYWORDS = {
  -- Declaración
  "report", "program", "function", "endfunction", "form", "endform",
  "module", "endmodule", "method", "endmethod", "class", "endclass",
  "interface", "endinterface", "define", "enddefine",
  -- Control de flujo
  "if", "endif", "else", "elseif", "when", "case", "endcase",
  "do", "endo", "while", "endwhile", "loop", "endloop",
  "try", "endtry", "catch", "cleanup", "catch", "resumable",
  "select", "endselect", "at", "endat", "provide", "endprovide",
  -- Operadores
  "and", "or", "not", "eq", "ne", "lt", "le", "gt", "ge",
  "is", "in", "between", "like", "covers",
  -- Comandos comunes
  "data", "types", "constants", "field-symbols", "parameters",
  "tables", "select-options", "ranges",
  "type", "like", "value", "ref", "to", "for", "importing",
  "exporting", "changing", "returning", "raising",
  "write", "read", "move", "append", "insert", "delete", "modify",
  "call", "submit", "leave", "exit", "check", "stop", "reject",
  "create", "describe", "sort", "translate", "search",
  "concatenate", "split", "condense", "replace", "shift",
  "clear", "refresh", "free", "collect", "compute",
  "set", "get", "add", "subtract", "multiply", "divide",
  "raise", "resume", "retry", "continue",
  -- Asignación
  "into", "from", "where", "having", "group", "by", "order",
  "up", "down", "first", "last", "ascending", "descending",
  "primary", "key", "unique", "sorted", "hashed", "index",
  "single", "member", "line", "table", "structure", "work",
  "area", "fields", "joining", "inner", "outer", "left", "right",
  "as", "using", "client", "specified", "specifying",
  "corresponding", "exact", "pattern", "occurrence", "offset",
  "length", "initial", "space", "zero",
  -- OO
  "public", "protected", "private", "section",
  "abstract", "final", "read-only", "redefinition",
  "super", "me", "friend", "local", "global",
  "new", "export", "import", "deferred", "load-of-program",
  "init", "start-of-selection", "end-of-selection",
  "at", "user-command", "line-selection", "pf-status",
  "top-of-page", "end-of-page",
}

-- Bloques que incrementan indentación
local BLOCK_START = {
  "if", "do", "while", "loop", "at",
  "method", "form", "module", "function", "class", "interface",
  "define", "try", "catch", "cleanup", "select", "when",
  "case", "provide",
  -- Also start variants
  "start-of-selection",  "load-of-program",
  "init", "top-of-page", "end-of-page", "line-selection",
}

-- Bloques que decrementan indentación
local BLOCK_END = {
  "endif", "endo", "endwhile", "endloop", "endat",
  "endmethod", "endform", "endmodule", "endfunction",
  "endclass", "endinterface", "enddefine", "endtry",
  "endselect", "endcase", "endprovide",
  -- Selection screen
  "end-of-selection",
}

-- Crear set de keywords para búsqueda rápida
local keyword_set = {}
for _, kw in ipairs(KEYWORDS) do
  keyword_set[kw:lower()] = true
end

local block_start_set = {}
for _, kw in ipairs(BLOCK_START) do
  block_start_set[kw:lower()] = true
end

local block_end_set = {}
for _, kw in ipairs(BLOCK_END) do
  block_end_set[kw:lower()] = true
end

-- Uppercase keywords en una línea
local function uppercase_keywords(line)
  -- Reemplazar palabras clave por su versión uppercase,
  -- pero solo las que coinciden exactamente con keywords ABAP
  return line:gsub("([%a_][%w_]*)", function(word)
    if keyword_set[word:lower()] then
      return word:upper()
    end
    return word
  end)
end

-- Limpiar espacios extras
local function clean_spacing(line)
  -- Eliminar espacios al final
  line = line:gsub("%s+$", "")
  -- Eliminar múltiples espacios (pero mantener indentación inicial)
  local indent = line:match("^(%s*)")
  local rest = line:match("^%s*(.*)$")
  if rest then
    rest = rest:gsub("%s+", " ")
    line = indent .. rest
  end
  return line
end

-- Detectar el keyword principal de una línea ABAP
local function get_main_keyword(line)
  local content = line:match("^%s*(.*)$") or ""
  -- Ignorar comentarios
  if content:match("^%*") or content:match("^\"") then
    return nil
  end
  -- Obtener la primera palabra
  local first_word = content:match("^([%a_][%w_]*)")
  if first_word then
    return first_word:lower()
  end
  -- Si empieza con espacio, obtener la segunda palabra (para ELSEIF, etc)
  local second_word = content:match("^%s+[%a_][%w_]*%s+([%a_][%w_]*)")
  if second_word then
    return second_word:lower()
  end
  return nil
end

-- Formatear una línea ABAP
local function format_line(line, current_indent)
  -- Preservar líneas en blanco
  if line:match("^%s*$") then
    return "", current_indent
  end

  local content = line:match("^%s*(.*)$") or ""

  -- Preservar comentarios (solo ajustar indentación)
  if content:match("^%*") or content:match("^\"") then
    return string.rep("  ", current_indent) .. content, current_indent
  end

  -- Detectar keyword principal
  local keyword = get_main_keyword(line)

  -- Ajustar indentación por bloques
  if keyword and block_end_set[keyword] then
    current_indent = math.max(0, current_indent - 1)
  end

  -- Aplicar uppercase
  content = uppercase_keywords(content)
  -- Limpiar spacing
  content = clean_spacing(content)

  -- Construir línea indentada
  local formatted = string.rep("  ", current_indent) .. content

  -- Ajustar indentación para el próximo bloque
  if keyword and block_start_set[keyword] then
    current_indent = current_indent + 1
  end

  return formatted, current_indent
end

-- Formatear archivo ABAP completo
function M.format_file()
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  local result = {}
  local indent = 0
  local fixes = {}  -- Lista de correcciones sugeridas

  for i, line in ipairs(lines) do
    local formatted, new_indent = format_line(line, indent)
    table.insert(result, formatted)
    indent = new_indent

    -- Detectar REPORT sin nombre
    local content = line:match("^%s*(.-)%s*$") or ""
    if content:upper():match("^REPORT%s*$") or content:upper():match("^REPORT%s+$") then
      table.insert(fixes, "L" .. i .. ": REPORT sin nombre de programa")
    end
    -- Detectar falta de punto al final
    if #content > 0 and not content:match("^%*|^\"") then
      if not content:match("%.$") and not content:match("^%s*$") then
        -- Solo ciertas sentencias ABAP requieren punto
        local kw = get_main_keyword(line)
        if kw and (keyword_set[kw:lower()]) then
          table.insert(fixes, "L" .. i .. ": falta punto final en '" .. content:match("^%S+") .. "...'")
        end
      end
    end
  end

  vim.api.nvim_buf_set_lines(bufnr, 0, -1, false, result)

  if #fixes > 0 then
    local msg = "ABAP: " .. #fixes .. " sugerencias:\n" .. table.concat(fixes, "\n")
    vim.notify(msg, vim.log.levels.WARN)
  else
    vim.notify("sap-nvim: ABAP formateado correctamente", vim.log.levels.INFO)
  end
end

function M.setup(opts) end

return M
