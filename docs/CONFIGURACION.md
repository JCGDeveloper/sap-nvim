# Configuración de sap-nvim

Todo se pasa a `require("sap-nvim").setup({...})`. Si cargas el plugin con lazy.nvim,
ponlo en el `config`:

```lua
-- ~/.config/nvim/lua/plugins/sap-nvim.lua
return {
  "JCGDeveloper/sap-nvim",
  dir = vim.fn.expand("~/sap-nvim"),   -- desarrollo local
  config = function()
    require("sap-nvim").setup({

      -- Defaults del asistente de creación (:SapNew). Antes salía "Z" en todo;
      -- ahora cada campo es configurable por proyecto.
      new = {
        name_prefix    = "ZCAR_",     -- default del NOMBRE del objeto
        package        = "ZCAR_PKG",  -- paquete por defecto (nil = pedir prefijo)
        package_prefix = "ZCAR",      -- prefijo de BÚSQUEDA de paquetes
        function_group = "ZCAR_FG",   -- grupo por defecto para function modules
      },

      -- Convención de nombres de variables (la usan los snippets y, en el futuro,
      -- sugerencias de nombres). Cada proyecto define la suya — algo que la
      -- extensión de VSCode no tiene.
      naming = {
        var     = "lv_",   -- variable local        (snippets data, case)
        itab    = "lt_",   -- tabla interna local    (loop, select all, alv)
        struct  = "ls_",   -- estructura/work area   (loop, select single)
        ref     = "lo_",   -- referencia a objeto    (try/catch, alv)
        gvar    = "gv_",   -- variable global
        gitab   = "gt_",   -- tabla interna global
        gstruct = "gs_",   -- estructura global
        gref    = "go_",   -- referencia global
        const   = "c_",    -- constante
      },
    })
  end,
}
```

Ejemplo: un proyecto que usa `it_` para tablas internas y `wa_` para work areas:

```lua
require("sap-nvim").setup({ naming = { itab = "it_", struct = "wa_" } })
```

Con eso, el snippet `loop` se expande como
`LOOP AT it_table INTO wa_row.` en vez de `lt_table`/`ls_row`.

## Crear y borrar objetos

- **Crear:** `:SapNew` / `<leader>an` → tipo → nombre → descripción → paquete →
  (transporte) → crea en SAP y abre el esqueleto para editar.
- **Borrar:** `:SapDelete` / `<leader>aX` sobre el objeto abierto → pide confirmación,
  resuelve transporte y lo elimina del sistema (`sapcli <group> delete`).

Todos los valores tienen default razonable; `setup()` sin argumentos sigue funcionando.
