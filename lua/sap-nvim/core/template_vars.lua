-- sap-nvim.core.template_vars  (R-D2)
-- Variables dinámicas estilo Eclipse/ADT para plantillas/snippets: se sustituyen en el
-- cuerpo del snippet en el MOMENTO de proponerlo (no en caché), con valores del contexto.
--
-- Sintaxis: $VAR en MAYÚSCULAS — NO choca con los tabstops LSP `${1:...}` / `${0}` (tras
-- `$` viene `{` o un dígito, nunca una mayúscula), así que es seguro mezclarlas.
--
--   Variable        Eclipse/ADT             Valor
--   $OBJECT         ${enclosing_object}     nombre del objeto ABAP del buffer
--   $PACKAGE        ${enclosing_package}    paquete real del objeto (o el configurado)
--   $SHORTTEXT      ${shortText}            descripción del objeto
--   $METHOD         ${enclosing_method}     método que contiene el cursor
--   $AUTHOR $USER   ${author}/${user}       usuario SAP activo (o del SO)
--   $SYSTEM         —                       sistema/contexto SAP activo
--   $DATE $YEAR     ${date}/${year}         fecha local
--   $MONTH $DAY     ${month}/${day}         mes/día (2 dígitos)
--   $TIME           ${time}                 hora local
--   $DOLLAR         ${dollar}               un `$` literal
--
-- Una variable desconocida ($FOO) se deja intacta.
-- `$SHORTTEXT`/`$PACKAGE` reales requieren que se haya leído el metadato ADT del objeto:
-- M.prime(bufnr) lo hace async una vez al abrir (lo llama source.open). Si aún no llegó,
-- $PACKAGE cae al paquete configurado y $SHORTTEXT a "".

local M = {}

-- Método que contiene la fila `row` (sube hasta `method <name>.`; si antes hay un
-- `endmethod`, no estamos dentro de ningún método). Acotado por rendimiento.
local function enclosing_method(bufnr, row)
  if not row then
    local ok, cur = pcall(vim.api.nvim_win_get_cursor, 0)
    row = ok and cur[1] or 0
  end
  if row <= 0 then return "" end
  local from = math.max(1, row - 400)
  local ok, lines = pcall(vim.api.nvim_buf_get_lines, bufnr, from - 1, row, false)
  if not ok then return "" end
  for i = #lines, 1, -1 do
    local l = lines[i]
    if l:lower():match("^%s*endmethod%f[^%w]") then return "" end
    local m = l:match("^%s*[Mm][Ee][Tt][Hh][Oo][Dd]%s+([%w_~]+)")
    if m then return m end
  end
  return ""
end

-- Reúne el contexto disponible (buffer + config + conexión ADT). Puro, sin red.
function M.context(bufnr, row)
  bufnr = bufnr or 0

  local name, pkg_obj, shorttext, group = "", "", "", ""
  local ok_obj, obj = pcall(function() return vim.b[bufnr].sap_obj end)
  if ok_obj and obj then
    name = obj.name or ""
    pkg_obj = obj.package or ""
    shorttext = obj.shorttext or ""
    group = obj.group or ""
  end

  local pkg = pkg_obj
  if pkg == "" then
    local ok_cfg, cfg = pcall(function() return require("sap-nvim.core.config").new() end)
    if ok_cfg and cfg then pkg = cfg.package or "" end
  end

  local user, system = "", ""
  local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
  if ok_adt and adt.get_current_context then
    local ok_ctx, c = pcall(adt.get_current_context)
    if ok_ctx and c then
      user = c.user or c.username or ""
      system = c.name or c.sysid or ""
    end
  end
  if user == "" then user = (vim.env and vim.env.USER) or os.getenv("USER") or "" end

  return {
    object = name, package = pkg, shorttext = shorttext, group = group,
    method = enclosing_method(bufnr, row), user = user, system = system,
  }
end

local function values(ctx)
  ctx = ctx or {}
  return {
    DATE      = os.date("%Y-%m-%d"),
    TIME      = os.date("%H:%M:%S"),
    YEAR      = os.date("%Y"),
    MONTH     = os.date("%m"),
    DAY       = os.date("%d"),
    USER      = ctx.user or "",
    AUTHOR    = ctx.user or "",
    OBJECT    = ctx.object or "",
    PACKAGE   = ctx.package or "",
    SYSTEM    = ctx.system or "",
    SHORTTEXT = ctx.shorttext or "",
    METHOD    = ctx.method or "",
    DOLLAR    = "$",
  }
end

-- Sustituye $VAR (mayúsculas) por su valor. No toca los tabstops ${n} / ${n:...} / $0.
function M.expand(body, ctx)
  if not body or body == "" then return body end
  if not body:find("%$%u") then return body end -- atajo: nada que expandir
  local vals = values(ctx)
  return (body:gsub("%$(%u[%u_]*)", function(var)
    local v = vals[var]
    if v ~= nil then return v end
    return "$" .. var -- desconocida: intacta
  end))
end

-- Lee async los metadatos ADT del objeto (descripción + paquete real) y los guarda en
-- vim.b[bufnr].sap_obj.{shorttext,package}. Best-effort: sin conexión, no hace nada.
-- Lo llama source.open una vez tras abrir; NO se usa en el hot-path del completado.
function M.prime(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  if not vim.b[bufnr] or not vim.b[bufnr].sap_obj then return end
  local ok_http, adt_http = pcall(require, "sap-nvim.core.adt_http")
  if not ok_http or not adt_http.is_available() then return end
  local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
  if not ok_intel or not intel.object_uri then return end
  local src_uri = intel.object_uri(bufnr)
  if not src_uri then return end
  local obj_uri = src_uri:gsub("/source/main$", "")

  adt_http.request_async({ method = "GET", path = obj_uri, accept = "application/*" }, function(body)
    if not body then return end
    local function unxml(s)
      return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
    end
    local desc = body:match('adtcore:description="([^"]*)"')
    local pkg = body:match('packageRef[^>]-adtcore:name="([^"]*)"')
    vim.schedule(function()
      if not vim.api.nvim_buf_is_valid(bufnr) then return end
      local m = vim.b[bufnr].sap_obj
      if not m then return end
      if desc and desc ~= "" then m.shorttext = unxml(desc) end
      if pkg and pkg ~= "" then m.package = pkg end
      vim.b[bufnr].sap_obj = m
    end)
  end)
end

return M
