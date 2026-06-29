-- sap-nvim.core.whereused
-- Where-used list: encuentra todos los objetos ABAP que referencian al objeto actual.
-- Ruta PRINCIPAL: ADT (usageReferences, lo mismo que usa intel.references para el símbolo
-- bajo el cursor, pero aquí para el OBJETO completo). Fallback degradado a `sapcli whereused`
-- (parseo de texto humano) si ADT no está disponible. Los símbolos LOCALES siguen resolviéndose
-- contra los ficheros cacheados en el cwd (find_local), igual que antes.

local M = {}
local adt = require("sap-nvim.core.adt")
local sapcli = require("sap-nvim.core.sapcli")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Cuerpo del POST de usageReferences (idéntico al de intel.references).
local USAGE_REQ =
  '<?xml version="1.0" encoding="UTF-8"?><usagereferences:usageReferenceRequest xmlns:usagereferences="http://www.sap.com/adt/ris/usageReferences"><usagereferences:affectedObjects/></usagereferences:usageReferenceRequest>'

-- Comandos sapcli para el FALLBACK (solo tipos con subcomando whereused en sapcli).
local CMDS = {
  abap = function(name) return { "sapcli", "program",   "whereused", name } end,
  prog = function(name) return { "sapcli", "program",   "whereused", name } end,
  cls  = function(name) return { "sapcli", "class",     "whereused", name } end,
  intf = function(name) return { "sapcli", "interface", "whereused", name } end,
}

local GROUP_TO_EXT = {
  program = "abap",
  class = "cls",
  interface = "intf",
}

local EXTENSIONS = { "abap", "cls", "intf", "func", "fugr", "tabl", "ddls", "bdef", "stru", "dtel" }

-- Localiza el fichero cacheado de un símbolo en el cwd (símbolos locales del proyecto).
local function find_local(obj_name)
  local cwd = vim.fn.getcwd()
  for _, ext in ipairs(EXTENSIONS) do
    local path = cwd .. "/" .. obj_name:lower() .. "." .. ext
    local f = io.open(path, "r")
    if f then f:close() return path end
  end
  return nil
end

local function unxml(s)
  return (s or ""):gsub("&lt;", "<")
    :gsub("&gt;", ">")
    :gsub("&quot;", '"')
    :gsub("&apos;", "'")
    :gsub("&#x0A;", "\n")
    :gsub("&#10;", "\n")
    :gsub("&amp;", "&")
end

-- Parsea el XML de usageReferences a una lista de referencias {name, typ, uri, snippet}.
-- Soporta las DOS formas que devuelven los distintos releases (igual que intel.references):
--   1) <usageReferences:referencedObject uri=... adtcore:name=... adtcore:type=... />
--   2) <usageReferences:adtObject adtcore:name/type> ... <usageReferences:usageReference adtcore:uri=...>
local function parse_usage_refs(body)
  local refs = {}
  if not body or body == "" then return refs end

  for block in body:gmatch("<usageReferences:referencedObject(.-)</usageReferences:referencedObject>") do
    local ref_uri = block:match('uri="([^"]*)"')
    local name = block:match('adtcore:name="([^"]*)"')
    local typ = block:match('adtcore:type="([^"]*)"')
    local descr = block:match('adtcore:description="([^"]*)"')
    if ref_uri and name then
      refs[#refs + 1] = { name = unxml(name), typ = unxml(typ or ""), uri = unxml(ref_uri), snippet = unxml(descr or "") }
    end
  end

  if #refs == 0 then
    for obj_block in body:gmatch("<usageReferences:adtObject(.-)</usageReferences:adtObject>") do
      local obj_name = obj_block:match('adtcore:name="([^"]*)"')
      local obj_typ = obj_block:match('adtcore:type="([^"]*)"')
      for ref_block in obj_block:gmatch("<usageReferences:usageReference(.-)</usageReferences:usageReference>") do
        local ref_uri = ref_block:match('adtcore:uri="([^"]*)"')
        local snippet = ref_block:match("<usageReferences:snippet>([^<]*)</usageReferences:snippet>")
        if ref_uri then
          refs[#refs + 1] = {
            name = unxml(obj_name or "?"),
            typ = unxml(obj_typ or ""),
            uri = unxml(ref_uri),
            snippet = unxml(snippet or ""),
          }
        end
      end
    end
  end

  -- Dedupe por uri|name y orden estable por nombre.
  local seen, unique = {}, {}
  for _, r in ipairs(refs) do
    local key = (r.uri or "") .. "|" .. (r.name or "")
    if not seen[key] then
      seen[key] = true
      unique[#unique + 1] = r
    end
  end
  table.sort(unique, function(a, b) return (a.name or "") < (b.name or "") end)
  return unique
end

-- Abre una referencia con source.open (resuelve grupo a partir del adtcore:type).
local function open_ref(ref)
  local group = adt.group_from_adt_type(ref.typ)
  local line, col = (ref.uri or ""):match("start=(%d+),(%d+)")
  if not group then
    notify("No sé abrir el tipo '" .. (ref.typ or "?") .. "' de " .. (ref.name or "?") .. ".", vim.log.levels.WARN)
    return
  end
  require("sap-nvim.core.source").open(ref.name:upper(), group, {
    line = tonumber(line),
    col = tonumber(col),
  })
end

-- Vuelca las referencias a quickfix (overview) y ofrece un selector para abrir vía source.open.
local function show_refs(obj_name, refs)
  if #refs == 0 then
    notify("Sin referencias para " .. obj_name, vim.log.levels.WARN)
    return
  end

  local qf = {}
  for _, r in ipairs(refs) do
    local path = find_local(r.name)
    local line = tonumber((r.uri or ""):match("start=(%d+),"))
    qf[#qf + 1] = {
      filename = path or "",
      lnum = line or 1,
      col = 1,
      text = string.format("%s  [%s]%s", r.name or "?", r.typ or "?",
        (r.snippet and r.snippet ~= "") and ("  " .. r.snippet) or ""),
      type = "I",
    }
  end
  vim.fn.setqflist({}, "r")
  vim.fn.setqflist(qf, "r")
  vim.fn.setqflist({}, "a", { title = "Where-used: " .. obj_name })
  vim.cmd("copen")
  notify(#refs .. " referencia(s) encontrada(s) para " .. obj_name)

  -- Selector navegable: abre la referencia elegida por ADT (source.open).
  vim.ui.select(refs, {
    prompt = "Where-used de " .. obj_name .. " (" .. #refs .. "):",
    format_item = function(r)
      return string.format("%-45s %-12s %s", r.name or "", r.typ or "", r.snippet or "")
    end,
  }, function(choice)
    if not choice then return end
    open_ref(choice)
  end)
end

-- ── Fallback degradado: sapcli whereused (parseo de texto humano) ─────────────
local function do_whereused_sapcli(obj_name, cmd)
  notify("Buscando referencias a " .. obj_name .. " (sapcli)...")
  local lines, stderr = {}, {}

  sapcli.jobstart(cmd, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(lines, l) end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(stderr, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 or #lines == 0 then
          local msg = #stderr > 0 and stderr[1] or "Sin referencias para " .. obj_name
          notify(msg, vim.log.levels.WARN)
          return
        end

        local qf = {}
        for _, line in ipairs(lines) do
          local ref = vim.trim(line)
          if ref ~= "" then
            local path = find_local(ref)
            table.insert(qf, {
              filename = path or "",
              lnum     = 1,
              col      = 1,
              text     = ref .. (path and "  [local]" or "  [sistema]"),
              type     = "I",
            })
          end
        end

        if #qf == 0 then
          notify("Sin referencias para " .. obj_name, vim.log.levels.WARN)
          return
        end

        vim.fn.setqflist({}, "r")
        vim.fn.setqflist(qf, "r")
        vim.fn.setqflist({}, "a", { title = "Where-used: " .. obj_name })
        vim.cmd("copen")
        notify(#qf .. " referencia(s) encontrada(s) para " .. obj_name)
      end)
    end,
  })
end

-- ── Ruta ADT: usageReferences sobre el OBJETO completo ───────────────────────
-- Prueba varias formas de URI (bare → /source/main) porque distintos releases aceptan una u
-- otra para el where-used de objeto. cb_empty() se llama si ninguna devolvió referencias.
local function adt_whereused(obj_name, obj_uri, ext)
  local adt_http = require("sap-nvim.core.adt_http")
  local bare = obj_uri:gsub("/source/main.*$", "")
  local candidates = { bare, bare .. "/source/main" }

  local function fallback_or_empty()
    local cmd_fn = CMDS[ext]
    if cmd_fn then
      do_whereused_sapcli(obj_name, cmd_fn(obj_name))
    else
      vim.schedule(function() notify("Sin referencias para " .. obj_name, vim.log.levels.WARN) end)
    end
  end

  local function try(i)
    if i > #candidates then
      return fallback_or_empty()
    end
    adt_http.request_async({
      method = "POST",
      path = "/sap/bc/adt/repository/informationsystem/usageReferences",
      query = { uri = candidates[i] },
      content_type = "application/vnd.sap.adt.repository.usagereferences.request.v1+xml",
      body = USAGE_REQ,
    }, function(body)
      vim.schedule(function()
        if body and body:find("usageReference") then
          local refs = parse_usage_refs(body)
          if #refs > 0 then
            return show_refs(obj_name, refs)
          end
        end
        try(i + 1)
      end)
    end)
  end

  notify("Buscando referencias a " .. obj_name .. " por ADT...")
  try(1)
end

local function resolve_and_whereused_adt(obj_name)
  notify("Resolviendo " .. obj_name .. " por ADT...")
  adt.find_objects_async(obj_name, function(results, err)
    vim.schedule(function()
      if not results or #results == 0 then
        notify("No se pudo resolver por ADT: " .. tostring(err or "sin resultados") .. ". Usando fallback sapcli...", vim.log.levels.WARN)
        do_whereused_sapcli(obj_name, CMDS["abap"](obj_name))
        return
      end
      local exact
      for _, r in ipairs(results) do
        if (r.name or ""):upper() == obj_name then
          exact = r
          break
        end
      end
      local picked = exact or results[1]
      local group = adt.group_from_adt_type(picked.type)
      local ext = GROUP_TO_EXT[group] or "abap"
      adt_whereused((picked.name or obj_name):upper(), picked.uri, ext)
    end)
  end)
end

function M.whereused()
  if not adt.is_configured() then
    notify("No hay conexion SAP. Usá :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  local bufnr    = vim.api.nvim_get_current_buf()
  local bufname  = vim.api.nvim_buf_get_name(bufnr)
  local obj_name = vim.fn.fnamemodify(bufname, ":t:r"):upper()
  local ext      = vim.fn.fnamemodify(bufname, ":e"):lower()

  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  local adt_ok = ok_http and adt_http.is_available()

  -- Resolver la URI del objeto: la del buffer si está, o vía intel (objtype + sap_obj).
  local obj_uri
  if adt_ok then
    local meta = vim.b[bufnr].sap_obj
    if meta and meta.uri and meta.uri ~= "" then
      obj_uri = meta.uri
    else
      local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
      if ok_intel and intel.object_uri then
        obj_uri = intel.object_uri(bufnr)
      end
    end
  end

  -- Sin objeto resoluble en el buffer: pedimos el nombre e intentamos ADT por búsqueda global.
  if obj_name == "" or (adt_ok and not obj_uri) then
    vim.ui.input({
      prompt = "Objeto ABAP para where-used: ",
      default = obj_name ~= "" and obj_name or "Z",
    }, function(name)
      if not name or name == "" then return end
      name = name:upper()
      if adt_ok then
        resolve_and_whereused_adt(name)
      else
        do_whereused_sapcli(name, CMDS["abap"](name))
      end
    end)
    return
  end

  if adt_ok and obj_uri then
    return adt_whereused(obj_name, obj_uri, ext)
  end

  -- ADT no disponible: fallback sapcli (solo tipos soportados).
  local cmd_fn = CMDS[ext]
  if not cmd_fn then
    notify("Where-used por sapcli no soportado para ." .. ext .. " y ADT no disponible.", vim.log.levels.WARN)
    return
  end
  do_whereused_sapcli(obj_name, cmd_fn(obj_name))
end

function M.setup()
  vim.api.nvim_create_user_command("SapWhereUsed", function()
    M.whereused()
  end, { desc = "sap-nvim: Where-used list del objeto actual" })

  vim.keymap.set("n", "<leader>aw", M.whereused, { desc = "ABAP: Where-used list" })
end

return M
