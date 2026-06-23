-- sap-nvim.core.secret
-- Almacén de contraseñas estilo VSCode: la tecleas UNA sola vez y queda guardada en el
-- llavero del KERNEL de Linux (keyctl, keyring de usuario `@u`). Vive en RAM, NUNCA en disco,
-- y persiste entre sesiones de nvim mientras siga viva tu sesión de usuario (en WSL, mientras
-- no cierres la distro). Así no te vuelve a pedir la contraseña cada vez que abres el IDE
-- — exactamente como hace la extensión de VSCode con el almacén seguro del SO.
--
-- Si `keyctl` no está disponible, TODO degrada con elegancia: get() devuelve nil y set() es
-- un no-op, de modo que el flujo cae a "contraseña en memoria por sesión + prompt" sin romperse.
--
-- SEGURIDAD: la contraseña se inyecta por STDIN (`keyctl padd`), nunca por argv, así que no
-- aparece en `ps` (misma filosofía que el `curl -K -` de adt_http).

local M = {}

local function has_keyctl()
  return vim.fn.executable("keyctl") == 1
end
M.available = has_keyctl

-- Descripción de la key en el keyring: un nombre estable por contexto SAP.
local function key_desc(ctx)
  return "sapnvim_" .. tostring(ctx or "default"):gsub("[^%w_%-]", "_")
end

-- Lee la contraseña guardada para `ctx`, o nil si no hay / keyctl no está.
function M.get(ctx)
  if not has_keyctl() then
    return nil
  end
  local desc = key_desc(ctx)
  -- `search` devuelve el id numérico de la key (o error si no existe).
  local ids = vim.fn.systemlist({ "keyctl", "search", "@u", "user", desc })
  if vim.v.shell_error ~= 0 or not ids[1] or ids[1] == "" then
    return nil
  end
  -- `pipe` vuelca el payload CRUDO a stdout (sin el formateo/hex de `print`).
  local out = vim.fn.system({ "keyctl", "pipe", ids[1] })
  if vim.v.shell_error ~= 0 or out == nil or out == "" then
    return nil
  end
  return out
end

-- Guarda (o reemplaza) la contraseña de `ctx` en el keyring. Devuelve true si lo logró.
function M.set(ctx, password)
  if not has_keyctl() or not password or password == "" then
    return false
  end
  -- Payload por STDIN para que la contraseña NO viaje en argv (visible en `ps`).
  vim.fn.system({ "keyctl", "padd", "user", key_desc(ctx), "@u" }, password)
  return vim.v.shell_error == 0
end

-- Borra la contraseña de `ctx` del keyring (p.ej. cuando SAP la rechaza: ya no sirve).
function M.clear(ctx)
  if not has_keyctl() then
    return
  end
  pcall(vim.fn.system, { "keyctl", "purge", "user", key_desc(ctx) })
end

return M
