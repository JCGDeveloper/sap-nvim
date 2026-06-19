-- sap-nvim.core.template_vars  (R-D2, primera porción: variables dinámicas)
-- Variables dinámicas estilo Eclipse para plantillas/snippets: se sustituyen en el cuerpo
-- del snippet en el MOMENTO de proponerlo (no en caché), con valores del contexto actual.
--
-- Sintaxis: $VAR en MAYÚSCULAS — NO choca con los tabstops LSP `${1:...}` / `${0}` (tras
-- `$` viene `{` o un dígito, nunca una mayúscula), así que es seguro mezclarlas.
--   $DATE $TIME $YEAR  -> fecha/hora locales
--   $USER $AUTHOR      -> usuario SAP activo (o del sistema operativo)
--   $OBJECT            -> nombre del objeto ABAP del buffer actual
--   $PACKAGE           -> paquete configurado / del contexto
--   $SYSTEM            -> sistema/contexto SAP activo
-- Una variable desconocida ($FOO) se deja intacta.

local M = {}

-- Reúne el contexto disponible (buffer + config + conexión ADT). Puro, sin red.
function M.context(bufnr)
  bufnr = bufnr or 0

  local name = ""
  local ok_obj, obj = pcall(function() return vim.b[bufnr].sap_obj end)
  if ok_obj and obj and obj.name then name = obj.name end

  local pkg = ""
  local ok_cfg, cfg = pcall(function() return require("sap-nvim.core.config").new() end)
  if ok_cfg and cfg then pkg = cfg.package or "" end

  local user, system = "", ""
  local ok_adt, adt = pcall(require, "sap-nvim.core.adt")
  if ok_adt and adt.get_current_context then
    local ok_ctx, c = pcall(adt.get_current_context)
    if ok_ctx and c then
      user = c.user or c.username or ""
      system = c.name or c.sysid or ""
    end
  end
  if user == "" then user = vim.env and vim.env.USER or os.getenv("USER") or "" end

  return { object = name, package = pkg, user = user, system = system }
end

local function values(ctx)
  ctx = ctx or {}
  return {
    DATE    = os.date("%Y-%m-%d"),
    TIME    = os.date("%H:%M:%S"),
    YEAR    = os.date("%Y"),
    USER    = ctx.user or "",
    AUTHOR  = ctx.user or "",
    OBJECT  = ctx.object or "",
    PACKAGE = ctx.package or "",
    SYSTEM  = ctx.system or "",
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

return M
