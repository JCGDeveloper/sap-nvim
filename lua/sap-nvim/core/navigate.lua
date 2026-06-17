-- sap-nvim.core.navigate
-- F11/F16 del SDD: navegar DENTRO del objeto (outline de símbolos) y ENTRE objetos
-- (ir a definición). El outline se construye escaneando el buffer (ABAP es orientado a
-- líneas y case-insensitive), sin depender de un parser treesitter instalado. Ir a
-- definición salta localmente si el símbolo está en el buffer; si no, resuelve el objeto
-- global con `sapcli abap find` y lo abre con source.open.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Etiqueta visible por tipo de símbolo.
local KIND_LABEL = {
  class = "class", ["class-impl"] = "class", interface = "intf",
  method = "method", form = "form", module = "module", ["function"] = "func",
  type = "type", event = "event", include = "INCLUDE",
}

-- Escanea el buffer y devuelve { {kind, name, lnum, text}, ... } en orden de aparición.
local function scan(bufnr)
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local items = {}

  for i, raw in ipairs(lines) do
    local l = raw:gsub("^%s+", "")
    local w1, rest = l:match("^(%S+)%s+(.*)$")
    if w1 then
      local kw = w1:lower()
      local low = l:lower()
      local name = rest:match("^([%w_/~<>]+)")
      local kind

      if kw == "class" and name then
        kind = low:find("implementation") and "class-impl" or "class"
      elseif kw == "interface" and name then
        kind = "interface"          -- declaración global de interface (no INTERFACES)
      elseif kw == "method" and name then
        kind = "method"             -- implementación: METHOD x.
      elseif (kw == "methods" or kw == "class-methods") and name then
        kind = "method"             -- declaración (se deduplica luego contra la impl)
      elseif kw == "form" and name then
        kind = "form"
      elseif kw == "module" and name then
        kind = "module"
      elseif kw == "function" and name then
        kind = "function"
      elseif kw == "include" and name and not low:find("structure") then
        kind = "include"            -- INCLUDE zfoo.  -> abrible con source.open
      elseif kw == "events" and name then
        kind = "event"
      elseif kw == "types" and name and name:lower() ~= "begin" then
        kind = "type"
      elseif kw == "types" and low:find("begin%s+of") then
        kind, name = "type", rest:match("[Bb][Ee][Gg][Ii][Nn]%s+[Oo][Ff]%s+([%w_/]+)")
      end

      if kind and name and name ~= "" then
        items[#items + 1] = { kind = kind, name = name, lnum = i, text = l }
      end
    end
  end

  return items
end

-- Quita declaraciones de método (METHODS x) si existe su implementación (METHOD x).
local function dedupe_methods(items)
  local impl = {}
  for _, it in ipairs(items) do
    if it.kind == "method" and it.text:lower():match("^method%s") then
      impl[it.name:lower()] = true
    end
  end
  local out = {}
  for _, it in ipairs(items) do
    local is_decl = it.kind == "method" and not it.text:lower():match("^method%s")
    if not (is_decl and impl[it.name:lower()]) then
      out[#out + 1] = it
    end
  end
  return out
end

-- F11: outline navegable del objeto actual.
function M.outline()
  local bufnr = vim.api.nvim_get_current_buf()
  local items = dedupe_methods(scan(bufnr))
  if #items == 0 then
    notify("Sin símbolos navegables en este buffer.", vim.log.levels.WARN)
    return
  end

  vim.ui.select(items, {
    prompt = "Outline (" .. #items .. " símbolos):",
    format_item = function(it)
      return string.format("%-7s %s  (L%d)", (KIND_LABEL[it.kind] or it.kind), it.name, it.lnum)
    end,
  }, function(choice)
    if not choice then return end
    -- Un INCLUDE no se "salta": se abre el objeto include desde SAP.
    if choice.kind == "include" then
      require("sap-nvim.core.source").open(choice.name:upper(), "include")
      return
    end
    vim.api.nvim_win_set_cursor(0, { choice.lnum, 0 })
    vim.cmd("normal! zz")
  end)
end

-- ¿La línea DEFINE el símbolo `name`? (no lo usa). Cubre forms, métodos, types y
-- declaraciones de datos (DATA/CONSTANTS/STATICS/PARAMETERS/FIELD-SYMBOLS/…), incluyendo
-- líneas de continuación de declaraciones encadenadas ("DATA: a TYPE i, b TYPE j.").
local DECL_KW = {
  ["form"] = true, ["method"] = true, ["methods"] = true, ["class-methods"] = true,
  ["data"] = true, ["constants"] = true, ["statics"] = true, ["class-data"] = true,
  ["parameters"] = true, ["select-options"] = true, ["ranges"] = true,
  ["types"] = true, ["tables"] = true, ["field-symbols"] = true,
}
local function is_def_line(raw, name)
  local low = raw:lower():gsub("^%s+", "")
  local n = name:lower()
  local has_word = low:find("%f[%w_]" .. n .. "%f[^%w_]") ~= nil

  -- Field-symbol: declaración `FIELD-SYMBOLS <fs> ...` (el cword no trae los <>).
  if low:find("field%-symbols", 1, true) and low:find("<" .. n .. ">", 1, true) then
    return true
  end
  if not has_word then return false end

  local first = low:match("^([%w%-]+)")
  if first and DECL_KW[first] then return true end          -- línea que empieza por decl-kw
  if low:find("begin of " .. n, 1, true) then return true end -- TYPES: BEGIN OF n
  if low:match(n .. "%s+type") or low:match(n .. "%s+like") then return true end -- "n TYPE/LIKE"
  return false
end

-- Busca la definición de `name` en una lista de líneas -> lnum o nil.
local function find_def(lines, name)
  for i, l in ipairs(lines) do
    if is_def_line(l, name) then return i end
  end
  return nil
end

-- Grupo sapcli de un archivo de caché: doble extensión (.prog/.clas/...) es fiable;
-- un `.abap` "pelado" es un include.
local function group_of_cache_file(path)
  local base = vim.fn.fnamemodify(path, ":t")
  local _, dots = base:gsub("%.", "")
  if dots >= 2 then return require("sap-nvim.core.objtype").group(path) end
  return "include"
end

-- Abre un archivo de caché ya descargado y salta a la línea, fijando sap_obj para que
-- push/activate sigan funcionando desde ahí.
local function open_cache_at(path, lnum)
  local objtype = require("sap-nvim.core.objtype")
  vim.cmd("edit " .. vim.fn.fnameescape(path))
  local b = vim.api.nvim_get_current_buf()
  vim.b[b].sap_obj = { name = objtype.name(path):upper(), group = group_of_cache_file(path) }
  vim.bo[b].filetype = "abap"
  vim.api.nvim_win_set_cursor(0, { lnum, 0 })
  vim.cmd("normal! zz")
end

-- Grupo de sapcli a partir del token de tipo ADT de `abap find` (col 1).
local TYPE_PREFIX_TO_GROUP = {
  CLAS = "class", INTF = "interface", PROG = "program",
  FUGR = "functiongroup", FUGS = "functiongroup",
}
local function group_from_find_row(row)
  local prefix, sub = (row:match("(%u+)/(%u+)")) or row:match("(%u+)")
  if prefix == "PROG" and sub == "I" then return "include" end
  return TYPE_PREFIX_TO_GROUP[prefix or ""]
end

-- Resolución global (objeto del repositorio) vía `abap find` -> source.open. Si no hay
-- nada, intenta el go-to-definition de LSP (abaplint) como último recurso.
local function goto_global(word)
  notify("Buscando objeto '" .. word .. "' en SAP...")
  local rows = {}
  vim.fn.jobstart({ "sapcli", "abap", "find", word }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        local t = vim.trim(l)
        if t ~= "" and not t:find("Object type") and not t:match("^[-|%s]*$") then
          rows[#rows + 1] = t
        end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #rows == 0 then
          if not pcall(vim.lsp.buf.definition) then
            notify("No se encontró la definición de '" .. word .. "'.", vim.log.levels.WARN)
          end
          return
        end
        local source = require("sap-nvim.core.source")
        local function row_name(r)
          if r:find("|") then return vim.trim((r:gsub("^[^|]*|%s*([^|]*)|.*", "%1"))) end
          return r:match("%f[%w]([%w_/]+)")
        end
        local exact = {}
        for _, r in ipairs(rows) do
          if (row_name(r) or ""):upper() == word:upper() then exact[#exact + 1] = r end
        end
        local pool = #exact > 0 and exact or rows
        local function open_row(r)
          local g, n = group_from_find_row(r), row_name(r)
          if g and n then source.open(n, g)
          else notify("No se pudo resolver el tipo de '" .. (n or word) .. "'.", vim.log.levels.WARN) end
        end
        if #pool == 1 then open_row(pool[1])
        else
          vim.ui.select(pool, { prompt = "Ir a definición de '" .. word .. "':",
            format_item = function(it) return it end },
            function(choice) if choice then open_row(choice) end end)
        end
      end)
    end,
  })
end

-- F16: ir a definición de la palabra bajo el cursor. Orden:
--   1) Si el cursor está sobre una sentencia INCLUDE -> abrir ese include.
--   2) Definición en el buffer actual (form/method/type/variable) -> saltar.
--   3) Definición en la "familia" del programa (otros includes ya en caché) -> abrir+saltar.
--   4) Objeto global del repositorio (`abap find`) -> abrir.
--   5) LSP definition (abaplint) como último recurso.
function M.goto_definition()
  local bufnr = vim.api.nvim_get_current_buf()
  local word = vim.fn.expand("<cword>")
  if not word or word == "" then
    notify("No hay palabra bajo el cursor.", vim.log.levels.WARN)
    return
  end

  -- 1) INCLUDE bajo el cursor -> abrir el include.
  local curline = vim.api.nvim_get_current_line():lower()
  local inc = curline:match("^%s*include%s+([%w_/]+)")
  if inc and (inc == word:lower() or curline:match("^%s*include%s")) then
    require("sap-nvim.core.source").open(inc:upper(), "include")
    return
  end

  -- 2) Definición en el buffer actual.
  local lnum = find_def(vim.api.nvim_buf_get_lines(bufnr, 0, -1, false), word)
  if lnum then
    vim.api.nvim_win_set_cursor(0, { lnum, 0 })
    vim.cmd("normal! zz")
    notify("→ " .. word .. " (L" .. lnum .. ", local)")
    return
  end

  -- 3) Definición en otros archivos de la caché (includes del programa ya descargados).
  local source = require("sap-nvim.core.source")
  local curpath = vim.api.nvim_buf_get_name(bufnr)
  for _, path in ipairs(vim.fn.glob(source.cache_dir() .. "/*.abap", false, true)) do
    if path ~= curpath then
      local ok, lines = pcall(vim.fn.readfile, path)
      local l = ok and find_def(lines, word) or nil
      if l then
        open_cache_at(path, l)
        notify("→ " .. word .. " en " .. vim.fn.fnamemodify(path, ":t") .. " (L" .. l .. ")")
        return
      end
    end
  end

  -- 4)+5) Objeto global / LSP.
  goto_global(word)
end

function M.setup()
  vim.api.nvim_create_user_command("SapOutline", function() M.outline() end,
    { desc = "sap-nvim: Outline de símbolos del objeto actual" })
  vim.api.nvim_create_user_command("SapGotoDef", function() M.goto_definition() end,
    { desc = "sap-nvim: Ir a definición de la palabra bajo el cursor" })

  vim.keymap.set("n", "<leader>ao", function() M.outline() end,
    { desc = "ABAP: Outline del objeto (símbolos)" })
  vim.keymap.set("n", "<leader>ag", function() M.goto_definition() end,
    { desc = "ABAP: Ir a definición (local o global)" })

  -- `gd` en buffers ABAP -> go-to-definition inteligente (include/form/variable/objeto).
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_navigate", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "gd", function() M.goto_definition() end,
        { buffer = ev.buf, desc = "ABAP: Ir a definición (sap-nvim)" })
    end,
  })
end

return M
