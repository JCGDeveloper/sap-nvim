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

local defaults = {
  new = {
    name_prefix    = "Z",   -- default del input de NOMBRE al crear
    package        = nil,   -- paquete por defecto (nil = pedir por prefijo)
    package_prefix = "Z",   -- prefijo de BÚSQUEDA de paquetes
    function_group = "Z",   -- default del grupo para function modules
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
}

M.values = vim.deepcopy(defaults)

function M.setup(opts)
  opts = opts or {}
  M.values = vim.tbl_deep_extend("force", vim.deepcopy(defaults), {
    new = opts.new or {},
    naming = opts.naming or {},
    data = opts.data or {},
  })
end

function M.new() return M.values.new end
function M.naming() return M.values.naming end
function M.data() return M.values.data end

return M
