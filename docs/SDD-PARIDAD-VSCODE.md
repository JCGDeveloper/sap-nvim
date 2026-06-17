# SDD — Paridad con la extensión ABAP de VSCode en Neovim

> **Estado:** vivo. Documento de diseño (SDD) + requisitos para replicar la experiencia
> de la extensión `abap-remote-fs` de VSCode (Marcello Urbani) dentro de `sap-nvim`.
> **Base ya conseguida:** abrir → editar → push → activar con errores a quickfix
> (commit `8d0cf81`), vía `sapcli read/write/activate` sobre la API ADT.

## 1. Visión

Trabajar ABAP clásico íntegramente desde Neovim: navegar el repositorio SAP, abrir y
editar cualquier objeto, navegar dentro y entre objetos, crear objetos nuevos, ver datos
de tablas, programar BAdIs/enhancements, ejecutar tests/ATC, gestionar transportes y
depurar — sin salir del editor. La extensión de VSCode es el listón de referencia.

## 2. Principio de arquitectura

Todo se apoya en **sapcli** (CLI que envuelve la API REST de ADT). Patrón uniforme ya
establecido en `core/source.lua`:

- **Leer** estado remoto: `sapcli <area> read/list/...` → parsear stdout.
- **Escribir**: `sapcli <area> write/create/... [--corrnr T]` (stdin o archivo).
- **Caché local real** en `~/.cache/nvim/sap-nvim/<contexto>/` con nombre abapGit, para
  que treesitter/abaplint/LSP funcionen.
- Operaciones **async** con `vim.fn.jobstart` + `vim.schedule`; feedback a `vim.notify`
  y errores a **quickfix**.

**Único hueco que NO cubre sapcli: depuración.** Requiere la API ADT debugger (HTTP),
disponible vía el binario `vsp` (Go, `~/sap-mcp/vsp`) ya presente, o reimplementación.

## 3. Inventario de features (VSCode) → estado y mapeo a sapcli

| # | Feature VSCode | Estado en sap-nvim | Mecanismo / comando |
|---|---|---|---|
| F0 | Abrir/editar/guardar con lock + transporte | ✅ hecho | `core/source.lua` (read/write) |
| F1 | Activar + objetos inactivos | ✅ hecho | `source.activate`, `:SapInactive` |
| F2 | Buscar objeto (Ctrl+Shift+A) | ✅ hecho | `:SapSearch` (`abap find`) |
| F3 | Explorar paquete | ✅ parcial | `:SapBrowse` (`package list -l`) |
| F4 | Where-used / referencias | ✅ hecho | `:SapWhereUsed` (`<group> whereused`) |
| F5 | ABAP Unit | ✅ hecho | `:SapAUnit` (`aunit run`) |
| F6 | ATC (quality) | ✅ hecho | `run_atc` (`atc run`) |
| F7 | Pretty printer / formato | ✅ hecho | `core/formatter.lua` |
| F8 | Transportes (list/create/release) | ✅ hecho | `core/transport.lua` (`cts`) |
| F9 | Checkout de paquete a disco | ✅ hecho | `:SapCheckout` (`checkout package`) |
| F10 | Diff local vs sistema | ✅ parcial | `:SapDiff` |
| **F11** | **Outline / navegar dentro del objeto** | ❌ pendiente | treesitter symbols + LSP documentSymbol |
| **F12** | **Árbol del repositorio (FS virtual)** | ❌ pendiente | `package list -l` recursivo en un árbol navegable |
| **F13** | **Crear objetos (todos los tipos)** | ⚠️ parcial (`new.lua`) | `<group> create NAME DESC PKG` |
| **F14** | **Visualizar tablas (datos + DDIC)** | ❌ pendiente | `datapreview osql`, `table read` |
| **F15** | **BAdIs / enhancements** | ❌ pendiente | `badi list/set-active` + editar clase impl |
| **F16** | **Ir a definición (cross-object)** | ❌ pendiente | navegación ADT / resolver nombre → `source.open` |
| **F17** | **Autocompletado ADT** | ⚠️ parcial (abaplint) | gap: ADT completion (vsp / ADT directo) |
| **F18** | **Depurador** | ⚠️ stub (`debugger.lua`/vsp) | ADT debugger API vía `vsp` |
| F19 | Revisiones / comparar versiones | ❌ pendiente | gap: ADT revisions API |
| F20 | CDS (ddl/dcl/bdef) editar + preview | ⚠️ parcial | `ddl/dcl/bdef read/write` + `datapreview` |
| F21 | Abrir en SAP GUI / transacción | ✅ parcial | `adt.open_gui` |

## 4. Requisitos por feature (las pendientes prioritarias)

### F11 — Outline y navegación dentro del objeto
- **R11.1** Comando `:SapOutline` / `<leader>ao` que liste símbolos del buffer ABAP
  (clases, métodos, forms, types, eventos) en un picker (`vim.ui.select` o telescope si hay).
- **R11.2** Saltar a la línea del símbolo elegido.
- **R11.3** Fuente de símbolos: LSP `textDocument/documentSymbol` si abaplint está adjunto;
  fallback a consulta treesitter (`@function`, `methods`, `form`, `class definition`).
- **R11.4** Soportar las 4 secciones de clase (def/impl/locals/test) si el objeto las tiene.

### F12 — Árbol del repositorio navegable
- **R12.1** Vista en árbol de paquetes Z* → subpaquetes → objetos, perezosa (lazy: expandir
  bajo demanda con `package list -l`).
- **R12.2** Enter sobre un objeto → `source.open`. Sobre paquete → expandir.
- **R12.3** Implementar sobre un buffer/ventana lateral propio o, si está disponible,
  integrar con `oil.nvim` / `snacks` / un picker recursivo. Decisión de UI en fase de diseño.

### F13 — Crear objetos
- **R13.1** `:SapNew` (extender `new.lua`) con picker de tipo: class, program, interface,
  function group/module, table, structure, data element, domain, CDS, message class, transaction.
- **R13.2** Pedir nombre + descripción + paquete (+ transporte si transportable) y llamar
  `<group> create`. Tras crear, `source.open` para empezar a editar.
- **R13.3** Plantilla mínima local para objetos que la requieran (p.ej. esqueleto de clase).

### F14 — Visualizar tablas
- **R14.1** `:SapTable <NOMBRE>` → `table read` muestra la definición DDIC en un buffer.
- **R14.2** `:SapData <SELECT...>` o `:SapTableData <TABLA>` → `datapreview osql "SELECT * FROM t"
  --rows N -o json`, render en un buffer tabular (alinear columnas) o quickfix.
- **R14.3** Límite de filas configurable; aviso si la tabla es enorme.

### F15 — BAdIs / enhancements
- **R15.1** `:SapBadi <ENH_IMPL>` → `badi list -i <impl>` para listar BAdIs y su estado.
- **R15.2** Activar/desactivar una implementación: `badi set-active`.
- **R15.3** Abrir la **clase de implementación** del BAdI como clase normal (`source.open`)
  para programarla. (Investigar cómo resolver el nombre de la clase impl desde el BAdI.)

### F16 — Ir a definición cross-object
- **R16.1** Sobre la palabra bajo el cursor (nombre de clase/método/include/FM), resolver el
  objeto y `source.open`. Estrategia: heurística de nombre (Z*, CL_*, IF_*) + `abap find`
  para confirmar tipo; si ambiguo, picker.
- **R16.2** Idealmente exponer como `vim.lsp` definition handler o `<leader>ad`/`gd` propio.

### F17 — Autocompletado ADT
- **R17.1** Gap real: sapcli no expone completion. Opciones: (a) usar `vsp`/ADT directo,
  (b) quedarse con abaplint LSP. Decisión en diseño; baja prioridad si abaplint cubre lo básico.

### F18 — Depurador
- **R18.1** Mayor esfuerzo. sapcli no depura. Usar `vsp` (ADT debugger API) ya integrado como
  base; definir adaptador (¿nvim-dap? ¿terminal?). Investigar el protocolo que expone `vsp`.
- **R18.2** Breakpoints, step into/over/out, ver variables, pila. Probablemente vía `nvim-dap`
  con un adaptador que hable con `vsp`/ADT.

## 5. Gestión de la caché (responde a la duda del ciclo de vida)

Los objetos abiertos viven en `~/.cache/nvim/sap-nvim/<contexto>/` como **archivos reales en
disco** (no RAM): no consumen memoria y **persisten al cerrar Neovim** (necesario para LSP).

- **R-CACHE.1** `:SapCacheClean` para borrar la caché del contexto actual.
- **R-CACHE.2** Al re-abrir un objeto ya cacheado, ofrecer "re-leer de SAP" vs "abrir caché"
  (evita editar una copia obsoleta). Por defecto re-leer de SAP.
- **R-CACHE.3** Marcar en statusline si el buffer puede estar desincronizado.

## 6. Roadmap por fases

- **Fase 1 — Navegación (alto valor, bajo riesgo, sin SAP nuevo):** F11 outline, F16 go-to-def,
  R-CACHE.1/2. Todo local + sapcli ya conocido.
- **Fase 2 — Datos y creación:** F14 tablas (osql), F13 crear objetos, F12 árbol de repo.
- **Fase 3 — Enhancements:** F15 BAdIs.
- **Fase 4 — Avanzado:** F18 depurador (vsp), F19 revisiones, F17 completado ADT, F20 CDS preview.

## 7. Modelo de ejecución con subagentes

Cada feature es relativamente independiente → un subagente por feature, **en su propio
worktree** (`isolation: worktree`) para evitar conflictos de merge, con un brief que apunte a
este SDD y al patrón de `core/source.lua`. Integración secuencial (revisar + merge por fase).
Para cada feature se preparará un brief/skill con: objetivo, requisitos (sección 4), comandos
sapcli verificados, archivos a tocar y criterios de verificación en vivo.

## 8. Verificación

Cada feature se valida **en vivo contra el sistema** (contexto `PruebasJoaquin`) con un
objeto de prueba propio (p.ej. paquete/programa `ZCAR_*`), nunca sobre objetos estándar SAP,
y dejando el sistema en su estado original (patrón roundtrip + revert ya usado).
