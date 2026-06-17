# Brief R-D2 — Plantillas dinámicas estilo Eclipse (innovación)

## Objetivo
Un sistema de plantillas de código superior a los snippets: buscable (picker), con
plantillas **guardables desde la UI** y **dinámicas/parametrizadas** (placeholders +
variables de entorno como nombre de objeto, autor, fecha).

## Requisitos
- **R-D2.1 Buscador:** `:SapTemplate` / keymap → picker (snacks/Telescope, fallback
  `vim.ui.select`) con las plantillas disponibles; Enter inserta en el cursor.
- **R-D2.2 Dinámicas:** placeholders LuaSnip (`${1:..}`) + variables automáticas:
  `${OBJECT}` (nombre del objeto actual vía `vim.b.sap_obj`), `${AUTHOR}` (usuario sapcli),
  `${DATE}`, `${PACKAGE}`. Resolverlas al insertar.
- **R-D2.3 Guardar desde UI:** `:SapTemplateSave` → toma la selección visual (o un prompt)
  y la guarda como plantilla nueva (nombre + descripción + trigger).
- **R-D2.4 Store:** plantillas en disco como ficheros (p.ej. `~/.config/sap-nvim/templates/*.lua`
  o `.snippet`), versionables; cargar al inicio. Plantillas de proyecto opcionales en el repo.
- **R-D2.5** Reutilizar/coexistir con `core/snippets.lua` (que ya usa la nomenclatura de
  `config.naming`). Las plantillas dinámicas son el nivel "estructural" (bloques grandes).

## Stack
- **LuaSnip** como motor (parsea `${..}` y permite funciones para variables dinámicas).
- Picker: snacks/Telescope si están; `vim.ui.select` fallback.

## Archivos
- Nuevo `lua/sap-nvim/core/templates.lua`; integrar con `integrations/blink.lua`/LuaSnip;
  `init.lua`, `keymaps.lua`.

## Verificación
Insertar una plantilla con `${OBJECT}/${DATE}` resueltos; guardar una nueva desde selección
y reusarla; comprobar que persiste tras reiniciar.

## Abierto / decidir
- Formato del store (lua table vs json vs formato snippet). Recomendado: lua tables (como
  `snippets.lua`) para poder usar funciones dinámicas.
- ¿Plantillas por proyecto? (encaja con la mejora de config por proyecto del SDD §5b.)
