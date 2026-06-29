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
      -- Perfil operativo. Dev es el default para no romper entornos personales.
      -- En prod el plugin arranca en solo lectura, exige TLS verificado y bloquea
      -- create/write/release/delete/set-variable salvo opt-in explícito.
      profile = "dev", -- "dev" | "qa" | "prod"

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

      -- Recomendado para productivo: verificar TLS con la CA corporativa.
      security = {
        verify_tls = true,
        ca_file = "/ruta/a/ca-corporativa.pem", -- nil si el certificado ya confía en el sistema
      },

      productive = {
        safe_mode = true,
        require_tls = true,
        read_only = true, -- default efectivo del perfil prod
        confirm_destructive = true,
        audit_sensitive_actions = true,
        audit_file = nil, -- stdpath("state")/sap-nvim/audit.log
        allow_create_objects = false,
        allow_write_objects = false,
        allow_release_transports = false,
        allow_delete_objects = false,
        allow_delete_transports = false,
        allow_debug_set_variable = false,
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

## Perfiles y productivo

- `profile = "dev"`: mantiene el comportamiento de desarrollo personal; no fuerza TLS ni modo
  solo lectura global.
- `profile = "qa"`: activa `safe_mode` y exige TLS verificado, pero permite create/write salvo
  que lo cierres con `productive`.
- `profile = "prod"`: arranca en `read_only`, exige `security.verify_tls=true` y bloquea
  create/write/release/delete/debug set-variable por defecto.

Para ejecutar una acción sensible en `prod`, desactiva `read_only`, activa el opt-in concreto
(`allow_write_objects`, `allow_create_objects`, `allow_release_transports`, etc.) y deja
`confirm_destructive=true` para exigir escribir el objeto/orden exacta.

Las acciones sensibles permitidas o bloqueadas se auditan localmente en
`stdpath("state")/sap-nvim/audit.log` en formato JSONL. El log no incluye contraseñas.
