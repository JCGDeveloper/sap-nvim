-- sap-nvim.core.secret
-- Almacén de contraseñas estilo VSCode: la tecleas UNA vez y se recuerda. DOS capas:
--
--   1) keyctl (keyring del KERNEL, @u): rápido, en RAM, NUNCA en disco. Pero es de SESIÓN:
--      se pierde al apagar WSL del todo (wsl --shutdown / reinicio / cerrar todo).
--   2) DPAPI de Windows (vía powershell.exe, solo en WSL): PERSISTENTE entre reinicios, igual
--      que el almacén del SO que usa VSCode. La contraseña se cifra con la clave del usuario de
--      Windows (ConvertFrom-SecureString → blob hex) y se guarda cifrada en disco; solo ese
--      usuario de Windows puede descifrarla. Inútil copiada a otra máquina/usuario.
--
-- get() prueba 1ª el keyring (rápido) y cae a DPAPI (y repuebla el keyring para la sesión).
-- set() escribe en ambos. Si no hay keyctl ni powershell, todo degrada a nil/no-op (prompt).
--
-- SEGURIDAD: la contraseña se inyecta por STDIN (keyctl padd / ConvertFrom-SecureString leyendo
-- de Console.In), nunca por argv → no aparece en `ps`. El blob DPAPI que viaja por argv al
-- descifrar ya está cifrado.

local M = {}

local function key_desc(ctx)
  return "sapnvim_" .. tostring(ctx or "default"):gsub("[^%w_%-]", "_")
end

-- ── Capa 1: keyctl (kernel keyring, por sesión) ──────────────────────────────
local function has_keyctl()
  return vim.fn.executable("keyctl") == 1
end

local function kc_get(ctx)
  if not has_keyctl() then
    return nil
  end
  local ids = vim.fn.systemlist({ "keyctl", "search", "@u", "user", key_desc(ctx) })
  if vim.v.shell_error ~= 0 or not ids[1] or ids[1] == "" then
    return nil
  end
  local out = vim.fn.system({ "keyctl", "pipe", ids[1] })
  if vim.v.shell_error ~= 0 or out == nil or out == "" then
    return nil
  end
  return out
end

local function kc_set(ctx, password)
  if not has_keyctl() then
    return false
  end
  vim.fn.system({ "keyctl", "padd", "user", key_desc(ctx), "@u" }, password)
  return vim.v.shell_error == 0
end

local function kc_clear(ctx)
  if has_keyctl() then
    pcall(vim.fn.system, { "keyctl", "purge", "user", key_desc(ctx) })
  end
end

-- ── Capa 2: DPAPI de Windows (persistente, solo WSL) ─────────────────────────
local pwsh_cache = nil -- string (ruta) | false (no hay) | nil (sin resolver)
local function pwsh()
  if pwsh_cache ~= nil then
    return pwsh_cache or nil
  end
  for _, p in ipairs({
    "powershell.exe",
    "/mnt/c/Windows/System32/WindowsPowerShell/v1.0/powershell.exe",
  }) do
    if vim.fn.executable(p) == 1 then
      pwsh_cache = p
      return p
    end
  end
  pwsh_cache = false
  return nil
end

local function dpapi_file(ctx)
  local dir = vim.fn.expand("~/.sapcli/sapnvim-secrets")
  vim.fn.mkdir(dir, "p")
  return dir .. "/" .. key_desc(ctx) .. ".dpapi"
end

local function dpapi_set(ctx, password)
  local ps = pwsh()
  if not ps then
    return false
  end
  -- Cifra: la contraseña entra por STDIN (no argv); la salida es un blob hex (DPAPI).
  local blob = vim.fn.system({
    ps, "-NoProfile", "-NonInteractive", "-Command",
    "$p=[Console]::In.ReadToEnd(); ConvertTo-SecureString $p -AsPlainText -Force | ConvertFrom-SecureString",
  }, password)
  if vim.v.shell_error ~= 0 then
    return false
  end
  blob = (blob or ""):gsub("%s+", "") -- quita \r\n y espacios
  if blob == "" or blob:match("[^%x]") then
    return false -- debe ser hex puro
  end
  local f = io.open(dpapi_file(ctx), "w")
  if not f then
    return false
  end
  f:write(blob)
  f:close()
  pcall(vim.fn.setfperm, dpapi_file(ctx), "rw-------")
  return true
end

local function dpapi_get(ctx)
  local ps = pwsh()
  if not ps then
    return nil
  end
  local f = io.open(dpapi_file(ctx), "r")
  if not f then
    return nil
  end
  local blob = (f:read("*a") or ""):gsub("%s+", "")
  f:close()
  if blob == "" or blob:match("[^%x]") then
    return nil
  end
  -- Descifra: el blob (ya cifrado) va por argv; el texto plano vuelve por stdout.
  local out = vim.fn.system({
    ps, "-NoProfile", "-NonInteractive", "-Command",
    "$s=ConvertTo-SecureString '" .. blob .. "'; "
      .. "$b=[Runtime.InteropServices.Marshal]::SecureStringToBSTR($s); "
      .. "[Runtime.InteropServices.Marshal]::PtrToStringAuto($b)",
  })
  if vim.v.shell_error ~= 0 or out == nil then
    return nil
  end
  out = out:gsub("\r", ""):gsub("\n$", "")
  if out == "" then
    return nil
  end
  return out
end

local function dpapi_clear(ctx)
  pcall(os.remove, dpapi_file(ctx))
end

-- ── API pública ──────────────────────────────────────────────────────────────
function M.available()
  return has_keyctl() or pwsh() ~= nil
end

-- Lee la contraseña: 1º keyring (rápido), 2º DPAPI persistente (y repuebla el keyring).
function M.get(ctx)
  local p = kc_get(ctx)
  if p and p ~= "" then
    return p
  end
  p = dpapi_get(ctx)
  if p and p ~= "" then
    pcall(kc_set, ctx, p) -- cachea en el keyring para el resto de la sesión (rápido)
    return p
  end
  return nil
end

-- Guarda en ambas capas: keyring (sesión) + DPAPI (persistente entre reinicios).
function M.set(ctx, password)
  if not password or password == "" then
    return false
  end
  local ok_kc = kc_set(ctx, password)
  local ok_dp = dpapi_set(ctx, password)
  return ok_kc or ok_dp
end

-- Borra de ambas capas (p.ej. cuando SAP rechaza la contraseña: ya no sirve).
function M.clear(ctx)
  kc_clear(ctx)
  dpapi_clear(ctx)
end

return M
