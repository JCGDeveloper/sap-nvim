-- sap-nvim.core.config
-- Configuración central del plugin (defaults de creación + convención de nombres de
-- variables). Se rellena desde require("sap-nvim").setup({ new=..., naming=... }) y la
-- leen new.lua (defaults de los pickers) y snippets.lua (prefijos de variables).
--
-- Ejemplo de configuración por proyecto:
--   require("sap-nvim").setup({
--     new    = { name_prefix = "ZCAR_", package = "ZCAR_PKG", function_group = "ZCAR_FG" },
--     naming = { itab = "it_", struct = "wa_", var = "lv_" },  -- nomenclatura del proyecto
--   })

local M = {}

local function deepcopy(v)
  return vim.deepcopy(v)
end

local defaults = {
  profile = "dev", -- dev|qa|prod. Dev mantiene compatibilidad y no fuerza TLS/solo lectura.
  new = {
    name_prefix    = "Z",   -- default del input de NOMBRE al crear
    package        = nil,   -- paquete por defecto (nil = pedir por prefijo)
    package_prefix = "Z",   -- prefijo de BÚSQUEDA de paquetes
    function_group = "Z",   -- default del grupo para function modules
    language       = "ES",  -- idioma original al crear por ADT (tu sistema rechaza EN)
  },
  -- Prefijos de variables (convención del proyecto). Usados por los snippets y como
  -- sugerencia de nombres. SAP clásico por defecto; cada proyecto los puede sobreescribir.
  naming = {
    var     = "lv_",  -- variable local
    itab    = "lt_",  -- tabla interna local
    struct  = "ls_",  -- estructura/work area local
    ref     = "lo_",  -- referencia a objeto local
    gvar    = "gv_",  -- variable global
    gitab   = "gt_",  -- tabla interna global
    gstruct = "gs_",  -- estructura global
    gref    = "go_",  -- referencia global
    const   = "c_",   -- constante
  },
  -- Visualización de datos (F14).
  data = {
    rows = 100,       -- nº de filas por defecto en datapreview osql
  },
  -- Formateo.
  format = {
    on_save = false,  -- formatear con el Pretty Printer de SAP al guardar (objetos remotos)
  },
  -- Documentacion/ayuda oficial SAP. No hace scraping: usa ADT quickSearch cuando hay
  -- conexion validada y compone URLs oficiales configurables como fallback.
  docs = {
    help_url = "https://help.sap.com/docs/search?q={query}",
    api_hub_url = "https://api.sap.com/search?searchterm={query}",
    always_show_api_hub = false,
    max_results = 25,
    panel_width = 72,
  },
  quality = {
    release_activate_helper = true,
    block_release_on_errors = true,
    block_activate_on_errors = false,
  },
  -- Seguridad de transporte. Por compatibilidad con sistemas SAP internos/self-signed,
  -- verify_tls arranca desactivado; para productivo debe activarse y, si aplica, ca_file.
  security = {
    verify_tls = false,
    ca_file = nil,
    connect_timeout = 10,
    request_timeout = 45,
    allow_plaintext_password = false, -- compat legacy: usar password: de ~/.sapcli/config.yml
  },
  -- Seguridad para uso profesional/productivo.
  productive = {
    safe_mode = true,
    require_tls = false, -- prod lo eleva a true mediante profiles.prod
    confirm_destructive = true, -- exige escribir el nombre/orden exacta para borrar/liberar/reasignar
    audit_sensitive_actions = true, -- log local JSONL de acciones sensibles permitidas/bloqueadas
    audit_file = nil, -- nil = stdpath("state")/sap-nvim/audit.log
    read_only = false,
    allow_create_objects = true,
    allow_write_objects = true,
    allow_release_transports = true,
    allow_delete_objects = false, -- opt-in explícito para borrar objetos/subobjetos remotos
    allow_delete_transports = false, -- opt-in explícito para borrar órdenes de transporte
    allow_oil_write = false, -- el adaptador oil sap:// es solo lectura por defecto
    allow_debug_set_variable = false, -- mutar variables en runtime queda desactivado por defecto
  },
}

local profile_defaults = {
  dev = {
    productive = {
      read_only = false,
      require_tls = false,
      allow_create_objects = true,
      allow_write_objects = true,
      allow_release_transports = true,
    },
  },
  qa = {
    productive = {
      read_only = false,
      require_tls = true,
      safe_mode = true,
      allow_create_objects = true,
      allow_write_objects = true,
      allow_release_transports = false,
    },
  },
  prod = {
    productive = {
      read_only = true,
      require_tls = true,
      safe_mode = true,
      allow_create_objects = false,
      allow_write_objects = false,
      allow_release_transports = false,
      allow_delete_objects = false,
      allow_delete_transports = false,
      allow_oil_write = false,
      allow_debug_set_variable = false,
    },
  },
}

M.values = deepcopy(defaults)
M._user_productive = {}

local function normalized_profile(value)
  value = tostring(value or ""):lower()
  if value == "production" or value == "productive" then value = "prod" end
  if profile_defaults[value] then return value end
  return "dev"
end

function M.setup(opts)
  opts = opts or {}
  M._user_productive = opts.productive or {}
  M.values = vim.tbl_deep_extend("force", deepcopy(defaults), {
    profile = normalized_profile(opts.profile or opts.environment or defaults.profile),
    new = opts.new or {},
    naming = opts.naming or {},
    data = opts.data or {},
    format = opts.format or {},
    docs = opts.docs or {},
    quality = opts.quality or {},
    security = opts.security or {},
    productive = opts.productive or {},
  })
  M.values.profile = normalized_profile(M.values.profile)
end

function M.new() return M.values.new end
function M.naming() return M.values.naming end
function M.data() return M.values.data end
function M.format() return M.values.format end
function M.docs() return M.values.docs end
function M.quality() return M.values.quality end
function M.security() return M.values.security end
function M.profile_name() return normalized_profile(M.values.profile) end
function M.profile() return profile_defaults[M.profile_name()] end
function M.is_prod() return M.profile_name() == "prod" end

function M.productive()
  local p = profile_defaults[M.profile_name()] or profile_defaults.dev
  return vim.tbl_deep_extend(
    "force",
    deepcopy(defaults.productive),
    deepcopy(p.productive or {}),
    deepcopy(M._user_productive or {})
  )
end

function M.audit_path()
  local prod = M.productive()
  if prod.audit_file and prod.audit_file ~= "" then
    return vim.fn.expand(prod.audit_file)
  end
  return vim.fn.stdpath("state") .. "/sap-nvim/audit.log"
end

local function json_encode(value)
  if vim.json and vim.json.encode then
    return vim.json.encode(value)
  end
  local function esc(s)
    return (tostring(s or ""):gsub("\\", "\\\\"):gsub('"', '\\"'):gsub("\n", "\\n"))
  end
  local parts = {}
  for k, v in pairs(value or {}) do
    parts[#parts + 1] = '"' .. esc(k) .. '":"' .. esc(v) .. '"'
  end
  return "{" .. table.concat(parts, ",") .. "}"
end

function M.audit(action, detail)
  local prod = M.productive()
  if prod.audit_sensitive_actions == false then
    return
  end
  detail = detail or {}
  local path = M.audit_path()
  local dir = path:match("^(.*)/[^/]+$")
  if dir then pcall(vim.fn.mkdir, dir, "p") end
  local entry = vim.tbl_extend("force", {
    ts = os.date("!%Y-%m-%dT%H:%M:%SZ"),
    profile = M.profile_name(),
    action = action or "unknown",
  }, detail)
  pcall(vim.fn.writefile, { json_encode(entry) }, path, "a")
end

return M
