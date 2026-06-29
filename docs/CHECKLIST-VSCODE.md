# Checklist de paridad con VSCode — picar código y editor

> Lista **exhaustiva** de lo que ofrece VSCode (su extensión ABAP `abap-remote-fs` + el
> editor en sí) para escribir/editar código ABAP, con el estado en sap-nvim. Documento vivo:
> se va tachando.
>
> Leyenda: `[x]` hecho · `[~]` parcial · `[ ]` pendiente.
> Última actualización: 2026-06-17.

---

## A. Inteligencia de lenguaje (lo que da el LSP/ADT)

- [x] **Autocompletado** mientras escribes (nombres de clase/tipo) — `intel`/`adt_completion`, ADT `codecompletion/proposal`
- [x] **Autocompletado de miembros** tras `=>` / `->` / `~` (métodos/atributos del sistema)
- [x] **Parámetros del método** al abrir `(` (signature-help básico)
- [x] **Completado manual** on-demand — `:SapComplete` / `<C-x><C-o>`
- [x] **Hover** (firma + propiedades + documentación) — `K` / `:SapHover`, ADT `elementinfo`
- [x] **Hover bloqueable** (2ª `K` entra, scroll con `hjkl`)
- [x] **Ir a definición** (incl. clases/métodos/tipos del SISTEMA) — `gd`, ADT `navigation/target`
- [x] **Ir al tipo del dato** — `gy` / `:SapGotoType`
- [x] **Referencias** (usos del símbolo) en picker — `gr` / `:SapReferences`, ADT `usageReferences`
- [x] **Diagnósticos en vivo** con posición exacta del SAP — `intel.check_syntax`, ADT `checkruns` (abapCheckRun); + abaplint para estilo
- [x] **Outline / símbolos del documento** — `:SapOutline` / `<leader>ao` (métodos, forms, includes…)
- [x] **Búsqueda de objetos del repositorio** (workspace symbols) — `:SapSearch`
- [x] **Ir a implementación** (de un método de interfaz) — `gI` / `:SapGotoImpl`, ADT `navigation/target?filter=implementation`
- [x] **Iconos por tipo en el completado** (método/clase/variable/keyword) — mapea `<KIND>` ADT
- [x] **Tipo/info en el item del completado** — `labelDetails` (variable/clase/método/keyword)
- [x] **Document highlights** (resaltar apariciones del símbolo bajo el cursor) — CursorHold local
- [~] **Signature help** — cubierto por el completado de parámetros al abrir `(` (la extensión de
  VSCode tampoco muestra un float de firma aparte; usa el completado)
- [—] **Inlay hints** — N/A: la extensión ABAP de VSCode no los implementa
- [—] **Code lens** — N/A: la extensión ABAP de VSCode no los implementa
- [ ] **Documentación completa en el item** (resolve perezoso con doc del método) — bloque mayor
- [~] **Quick fixes / code actions** — quick fixes locales y preview funcionan; falta aplicar
  edits ADT remotos completos desde `quickfixes/edits`
- [ ] **Rename / refactor** (renombrar con todos los usos) — bloque mayor + riesgo (ADT rename)
- [ ] **Call hierarchy / type hierarchy** — bloque mayor (ADT type hierarchy)

## B. Extensión ABAP (abap-remote-fs) — gestión de objetos

- [x] **Filesystem remoto**: abrir/editar/guardar objetos con lock + transporte — `core/source.lua`
- [x] **Activar** objeto (+ objetos inactivos) — `:SapActivate` / `<leader>aa`, `:SapInactive`
- [x] **Crear** objetos en SAP — `:SapNew`
- [x] **Borrar** objetos — `:SapDelete`
- [x] **Pretty Printer** (formateo) con el formateador real de SAP — `<leader>aF`, ADT `prettyprinter`
- [x] **Where-used list** — `:SapWhereUsed`
- [x] **ABAP Unit** (correr tests) — `:SapAUnit`
- [x] **ATC** (checks de calidad) — ATC run
- [x] **Data preview / SE16N** (datos de tabla) — `:SapTableData` / `:SapData` (osql)
- [x] **Definición DDIC de tabla** — `:SapTable`
- [x] **Transportes** (listar/crear/liberar) — `core/transport.lua`
- [x] **Checkout** de paquete a disco — `:SapCheckout`
- [x] **Navegación entre includes** (PERFORM→FORM, variable→decl) + volver con `-`
- [~] **Diff / comparar** con el sistema — `:SapDiff` local vs activo; `:SapRevisions` inicia diff contra revision cuando ADT devuelve fuente
- [~] **Revisiones / historial de versiones** — `:SapRevisions` / `:SapRevisionRoutes`; pendiente validar todos los backends ADT y diff entre dos revisiones
- [x] **Árbol del repositorio** navegable (paquetes→objetos) — `:SapRepositoryToggle` / `<leader>e`
- [ ] **BAdIs / enhancements** — `briefs/F15` (pendiente)
- [x] **Debugging** (breakpoints, step, variables) — cockpit estilo SAP GUI + nvim-dap/ADT
- [ ] **CDS**: editar + preview de datos — `briefs/F20` (parcial; editar sí, preview pendiente)
- [~] **Abrir en SAP GUI / transacción** — `adt.open_gui` (parcial)

## C. Editor / experiencia al picar código (núcleo)

> Muchas las da Neovim nativo o plugins del usuario; se listan para tener el cuadro completo.

- [x] **Resaltado de sintaxis** ABAP — treesitter (`core/treesitter.lua`)
- [x] **Snippets** ABAP (con nomenclatura configurable) — `core/snippets.lua` + blink
- [x] **Indentación automática** — treesitter / formateador
- [x] **Comentar/descomentar**, multicursor, find/replace, folding — nativos de Neovim/plugins
- [x] **Plegado (folding)** por estructura — treesitter
- [x] **Emparejado de paréntesis** — Neovim nativo
- [x] **Statusline** con sistema/cliente/usuario activos — `core/statusline.lua`
- [~] **Auto-cerrar paréntesis/comillas** — depende del plugin de autopairs del usuario
- [x] **Formateo al guardar** (format-on-save) — opcional: `setup({ format = { on_save = true } })`
- [ ] **Formateo de selección / rango** — ADT prettyprinter soporta rango (pendiente)
- [ ] **Semantic highlighting** (colorear según el análisis del servidor, no solo treesitter) — pendiente
- [x] **Resaltar ocurrencias** del símbolo bajo el cursor — CursorHold local

## D. Innovaciones (NO están en VSCode) — pedidas por el usuario

- [ ] **SE91**: crear el texto del mensaje directo desde `MESSAGE '...'(001)` — `briefs/RD1`
- [ ] **Plantillas dinámicas** estilo Eclipse (buscador, guardar, parametrizadas) — `briefs/RD2`
- [ ] **Config por proyecto** (`.sap-nvim.json/lua` desde el cwd) — `SDD §5b`

---

## Resumen

**Sección "picar código / inteligencia" (A + C núcleo): prácticamente completa.** Lo esencial
de VSCode para escribir ABAP (completado, hover, navegación, referencias, diagnósticos reales,
formateo real) está hecho con el cliente ADT directo (`core/adt_http.lua`).

**Menores de inteligencia: COMPLETADOS** (iconos + info de tipo en el completado, document
highlights, ir-a-implementación, format-on-save; signature help cubierto por el completado de
params; inlay hints / code lens no aplican a la extensión ABAP de VSCode).

**Lo que queda son BLOQUES MAYORES** (no "menores"): quick fixes con aplicación, rename/refactor,
call/type hierarchy, doc completa en el item, debugging (F18), revisiones/comparar versiones,
árbol de repo (F12), BAdIs (F15), y las innovaciones (SE91, plantillas, config por proyecto).

Detalle por feature de la inteligencia: `briefs/RA-inteligencia-adt.md`. Plan global:
`PLAN-MAESTRO.md`.
