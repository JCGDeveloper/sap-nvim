# Plan Maestro — sap-nvim: IDE ABAP en Neovim con paridad VSCode + innovaciones

> **Para quién:** este documento es el punto de entrada para cualquiera (humano o IA) que
> continúe `sap-nvim`. Define qué está hecho, qué falta, cómo trabajar y los límites de
> seguridad. Léelo entero antes de tocar nada. Complementa a
> [`SDD-PARIDAD-VSCODE.md`](SDD-PARIDAD-VSCODE.md), [`CONFIGURACION.md`](CONFIGURACION.md)
> y los [`briefs/`](briefs/).

## 0. Principio rector

Que programar ABAP clásico en Neovim **se sienta como VSCode/Eclipse ADT**: fluido,
con las ayudas justas, no intrusivo — y además con innovaciones que VSCode no tiene
(SE91 directo, plantillas dinámicas). Todo **sin romper nada en SAP** (ver §7 Seguridad).

Arquitectura base ya establecida (no rehacer): todo se apoya en **sapcli** (CLI sobre la
API REST de ADT). Patrón: leer con `sapcli <area> read/list`, escribir con
`sapcli <area> write/create [--corrnr]`, caché local real en `~/.cache/nvim/sap-nvim/<ctx>/`
(nombre abapGit → LSP/abaplint/treesitter funcionan), todo async con `jobstart`+`schedule`,
errores a quickfix. Único hueco que sapcli NO cubre: **debugging** (requiere ADT debugger
HTTP, vía el binario `vsp` en `~/sap-mcp/vsp` o reimplementación).

## 1. Estado actual — YA HECHO (no rehacer)

| Área | Estado | Dónde |
|---|---|---|
| Abrir/editar/guardar (lock+transporte) | ✅ | `core/source.lua` |
| Push explícito + activar (=push+activate) | ✅ | `source.push/activate`, `:SapPush`/`:SapActivate`/`<leader>aa` |
| Errores de activación a quickfix (E/W, salto a línea por token) | ✅ parcial | `adt._parse_activation_errors` (ver §6 F1b: faltan posiciones exactas) |
| Crear objetos EN SAP + abrir | ✅ | `core/new.lua`, `:SapNew` |
| Borrar objetos | ✅ | `source.delete`, `:SapDelete`/`<leader>aX` |
| Buscar objetos / explorar paquete | ✅ | `:SapSearch` / `:SapBrowse` |
| Outline (símbolos, incl. INCLUDEs) | ✅ | `core/navigate.lua`, `:SapOutline`/`<leader>ao` |
| Go-to-definition cross-include (INCLUDE/PERFORM→FORM/variable→decl) | ✅ | `navigate.goto_definition`, `gd`/`<leader>ag` |
| Navegación back (`-`) entre archivos | ✅ | `navigate.back` |
| Where-used | ✅ | `:SapWhereUsed`/`<leader>aw` |
| AUnit / ATC | ✅ | `:SapAUnit` / ATC |
| Ver tablas: DDIC + datos (osql, alineado) | ✅ | `core/data.lua`, `:SapTable`/`:SapTableData`/`:SapData` |
| Transportes (list/create/release) | ✅ | `core/transport.lua` |
| Checkout de paquete a disco | ✅ | `:SapCheckout` |
| Config central (defaults + nomenclatura) | ✅ | `core/config.lua`, `setup({new,naming,data})` |
| Snippets ABAP (con nomenclatura configurable) | ✅ básico | `core/snippets.lua` (ver §3 para ampliar) |
| Keymaps ABAP buffer-local (ganan a plugins IA) | ✅ | `core/keymaps.lua` (FileType abap) |
| Formateo al guardar (upper + indent nativo) | ⚠️ parcial | `core/formatter.lua` (ver §3.B: incompleto) |

## 2. Bugs conocidos a corregir (PRIORITARIO)

1. **Crear clase → "redefinition":** al crear/abrir una clase aparece un error de
   redefinition. Investigar si viene del esqueleto que genera SAP, de abaplint, o de un
   resto de plantilla local. Reproducir con `:SapNew` → clase, y con `class read` del
   objeto creado. Arreglar para que una clase nueva quede limpia.
2. **Formateo incompleto:** al guardar capitaliza keywords pero **se deja algunos**
   (p.ej. `CLASS-METHODS`, `class methods`). El formateador nativo no es un pretty printer
   real. Ver §3.B.
3. **Posiciones exactas de errores** (F1b del SDD): los errores de activación salen sin
   nº de línea fiable para includes; sapcli descarta la posición del checkRun. Solución:
   parsear el XML de ADT `checkruns` directamente.

## 3. NUEVOS requisitos (de esta sesión / capturas del usuario)

### 3.A — Autocompletado y LSP (sensación VSCode)
- **R-A1 Keywords contextuales:** ✅ HECHO (2026-06-19) — `integrations/abap_local.lua`
  detecta el contexto (firma de método / sección de clase / cuerpo / global) y prioriza
  (`score_offset`) los keywords propios: `IMPORTING`/`EXPORTING`/`RETURNING VALUE()`/
  `CHANGING`/`RAISING` en una firma; `METHODS`/`CLASS-METHODS`/`DATA`/secciones en la
  definición de clase. Detección heurística pura, probada offline. No requiere red.
- **R-A2 Métodos/clases del sistema:** autocompletar métodos y clases estándar de SAP
  (p.ej. `cl_abap_*`, `if_*`). Requiere **ADT code completion** (sapcli no lo expone →
  vía `vsp`/ADT directo) o, mínimo, un índice de los objetos del sistema.
- **R-A3 `gr` referencias:** ver referencias de la variable/objeto bajo el cursor en un
  picker (Telescope), con Enter para navegar. Reutiliza where-used + navegación local.
- **R-A4 Go-to-type:** además de ir a la definición, **ir al TIPO** de un dato (el tipo de
  `DATA x TYPE zcl_y` → abrir `zcl_y`). Extiende `navigate.goto_definition`.
- **R-A5 Hover bloqueable:** `Shift-K` muestra documentación/firma en flotante; segunda
  pulsación **fija** la ventana y permite scroll con `hjkl` (como VSCode). Ventana flotante
  propia o `vim.lsp.buf.hover` + lógica de focus.
- **R-A6 Navegación rápida a buffers abiertos:** `<Space><Space>` → picker de buffers
  abiertos (Telescope/snacks). (Es UI de nvim, coordinar con la config del usuario.)

### 3.B — Formateo inteligente al guardar (pretty printer ABAP real)
- **R-B1** Capitalizar TODOS los keywords (incl. compuestos `CLASS-METHODS`, `FIELD-SYMBOLS`,
  `READ TABLE`, etc.), manteniendo identificadores/variables en su caja.
- **R-B2** Indentación correcta por estructura (no solo shift fijo).
- **R-B3 Espaciado de la nueva sintaxis:** ABAP 7.40+ exige espacios exactos en paréntesis
  de constructores/expresiones: `VALUE #( ... )`, `lo->meth( p = 1 )`, `cond #(...)`. Hay
  que **respetar/forzar** las reglas para que SAP no rechace el paréntesis. Investigar
  reglas exactas en la extensión de VSCode / abapPrettyPrinter.
- **R-B4** Lo ideal: usar el **pretty printer de ADT** (el mismo que SE80/ADT "Pretty
  Printer") vía ADT, en vez de reglas locales. Evaluar si sapcli/ADT lo exponen; si no,
  mejorar `formatter.lua` con reglas robustas o abaplint `--fix`.

### 3.C — SE16N / datos (leader-T)
- **R-C1** `<leader>T` (o el atajo que el usuario tiene) → previsualización de datos de
  tabla **en ventana flotante**, estilo SE16N, con metadatos. Ya existe `:SapTableData`
  (base de F14); falta la UI flotante + el atajo + metadatos (nº filas, tipos).

### 3.D — Innovaciones exclusivas (NO existen en VSCode — obligatorias)
- **R-D1 SE91 mensaje directo:** detectar `MESSAGE 'texto'(001) ... DISPLAY LIKE 'E'` y
  ofrecer una acción que **cree el texto del mensaje** directamente en la clase de mensajes
  (SE91) como literal. Manejar la lógica de variables `&1 &2 &3 &4`. Investigar si sapcli
  `messageclass` (tiene `create`/`message`) lo permite; `write` está "not implemented yet",
  así que quizá haya que usar ADT directo para el texto.
- **R-D2 Plantillas dinámicas estilo Eclipse:** buscador (Telescope) de plantillas de
  código; **guardar** plantillas nuevas desde UI; plantillas **dinámicas/parametrizadas**
  (placeholders, variables de entorno como nombre de objeto/fecha/autor). Motor: **LuaSnip**
  + un store en disco (`~/.config/sap-nvim/templates/` o en el repo del proyecto).
  - ✅ **Variables dinámicas — paridad Eclipse/ADT (2026-06-19):** `core/template_vars.lua`
    expande con el contexto real al proponer (no en caché), sin tocar los tabstops `${n}`:
    `$OBJECT`(=`${enclosing_object}`), `$PACKAGE`(real, =`${enclosing_package}`),
    `$SHORTTEXT`(=`${shortText}`), `$METHOD`(=`${enclosing_method}`), `$AUTHOR`/`$USER`,
    `$SYSTEM`, `$DATE/$YEAR/$MONTH/$DAY/$TIME`, `$DOLLAR`(=`${dollar}`). `$SHORTTEXT`/`$PACKAGE`
    reales se cargan con `template_vars.prime()` (lee metadatos ADT async al abrir, vía
    `source.open`). Cableado en `abap_local` y `templates`; snippet `hdr` de ejemplo. Probado offline.
  - ✅ **Plantillas completas (2026-06-19):** `core/templates.lua` — store en disco
    (`~/.config/sap-nvim/templates/`, un `*.abap` por plantilla, editable a mano), picker
    Telescope con preview (fallback `vim.ui.select`), guardar buffer/selección desde UI con
    opción de generalizar el objeto a `$OBJECT`, e inserción vía `vim.snippet` (tabstops) +
    `template_vars` (vars dinámicas). `:SapTemplate`/`:SapTemplateSave`/`<leader>aP`. Seed de
    ejemplo `cabecera`. Helpers puros probados offline; store probado con IO real.

### 3.E — Debugging completo (nvim-dap)
- **R-E1** Suite completa: breakpoints (set/toggle/clear en buffer), step over (F10),
  step into (F11), step out (Shift+F11), continue (F5); inspección de variables, watch,
  call stack, scopes local/global. Atachar a sesiones de debugging del backend SAP.
- **R-E2** Mecanismo: **sapcli NO depura**. Usar el ADT debugger API. Punto de partida:
  el binario `vsp` (Go) ya integrado como stub (`core/debugger.lua`, `integrations/vsp.lua`).
  Hacer un **spike** primero (ver `briefs/F18-depurador.md`): entender qué expone `vsp`,
  y diseñar un **adaptador nvim-dap** que hable con `vsp`/ADT. Alta incertidumbre.

## 4. Stack técnico objetivo

- **Completado:** el usuario usa `blink.cmp` (hay `integrations/blink.lua`) — mantenerlo;
  añadir una fuente ABAP-aware (keywords contextuales + ADT completion).
- **LSP:** abaplint (local, ya integrado) para sintaxis/diagnóstico; ADT (vía vsp) para
  completion/navegación de objetos del sistema.
- **Formateo:** `conform.nvim` o mejorar `formatter.lua` / abaplint `--fix`.
- **Debugging:** `nvim-dap` + `nvim-dap-ui` con adaptador a `vsp`/ADT.
- **Snippets/plantillas:** `LuaSnip` + store propio.
- **UI/pickers:** el usuario usa **snacks**; usar snacks.picker o Telescope si está. No
  imponer un picker: detectar lo disponible (`vim.ui.select` como fallback ya funciona).
- **Async obligatorio:** toda llamada a SAP con `jobstart`; 0 lag en teclas; timeouts en
  operaciones que puedan colgarse (ya aplicado en `data.lua`).

## 5. Roadmap por fases (actualizado)

- **Fase A — Pulido de lo existente (alta prioridad, bajo riesgo):**
  bug "redefinition" (§2.1), formateo completo §3.B (R-B1/B2), keywords contextuales §3.A
  (R-A1), `gr` referencias (R-A3), go-to-type (R-A4).
- **Fase B — Datos y ayudas:** SE16N flotante §3.C, hover bloqueable (R-A5),
  navegación rápida buffers (R-A6).
- **Fase C — Innovaciones:** SE91 directo (R-D1), plantillas dinámicas (R-D2).
- **Fase D — Completado del sistema:** ADT code completion (R-A2) — depende de vsp/ADT.
- **Fase E — Debugging:** nvim-dap + vsp (R-E1/E2). La más compleja; spike primero.
- **Transversal:** F1b posiciones exactas de error (XML checkRun), F12 árbol de repo,
  config por proyecto (`.sap-nvim.json`/`.lua` desde el cwd — el usuario la quiere).

## 6. Cómo trabajar (obligatorio)

- **SDD primero:** para cada feature nueva, escribir/actualizar su brief en `briefs/`
  (objetivo, comandos sapcli/ADT verificados, requisitos, archivos, verificación) ANTES de
  codificar. Patrón de referencia: `core/source.lua`, `core/navigate.lua`, `core/data.lua`.
- **Verificar EN VIVO** cada cambio contra el contexto `PruebasJoaquin` con objetos
  **propios** (`ZCAR_*`, `ZRJCG_*`), NUNCA sobre objetos estándar SAP, dejando el sistema
  como estaba (patrón roundtrip + revert).
- **Módulos limpios:** un módulo por feature en `lua/sap-nvim/core/`, registrado en
  `init.lua`, atajos buffer-local en `keymaps.lua` (FileType abap) para no chocar con los
  plugins de IA del usuario (`<leader>a` está compartido).
- **Reutilizar:** `objtype` (group↔ext), `adt` (contexto/errores), `source` (open/push/
  cache), `config` (defaults/naming). No duplicar.

## 7. SEGURIDAD — no romper SAP (requisito innegociable)

Toda operación que **modifica** el sistema debe ser segura y reversible-por-diseño:

- **S1 Solo objetos propios:** avisar/bloquear si se va a escribir/crear/borrar un objeto
  que no empiece por `Z`/`Y`/namespace propio (los estándar SAP NO se tocan). `source.delete`
  ya confirma; extender la validación a write/create.
- **S2 Confirmación explícita** en operaciones destructivas (borrar, sobreescribir,
  activar con errores ignorados). Ya hay confirm en delete; aplicar a `--ignore-errors`.
- **S3 Transporte correcto:** nunca escribir en una orden ajena sin querer; el selector ya
  filtra por owner. No auto-confirmar transportes de producción.
- **S4 Contexto/sistema visible:** mostrar SIEMPRE en statusline el sistema+cliente+usuario
  activos (ya hay statusline) para no editar en producción por error. Avisar fuerte si el
  contexto parece productivo.
- **S5 Lock/unlock:** sapcli gestiona el lock en write; asegurarse de no dejar objetos
  bloqueados (si un write falla, el lock se libera). No implementar writes ADT "a mano" sin
  el unlock.
- **S6 Check antes de guardar:** ofrecer `abapCheckRun` antes del push (sapcli
  `write --check` / `SAPCLI_CHECK_BEFORE_SAVE`) para no subir código que rompe activación.
- **S7 Sin acciones masivas:** nada de borrados/activaciones en lote sin confirmación
  objeto a objeto. El debugger NO debe poder modificar datos de producción.
- **S8 Auditoría:** registrar (log local) las operaciones que modifican SAP (write/create/
  delete/activate) con objeto, transporte, timestamp y usuario.
- **S9 Timeouts y async:** ninguna operación debe colgar el editor (timeouts ya en data.lua;
  aplicar a todas las llamadas potencialmente lentas).
- **S10 Datos:** la preview de datos es **solo lectura** (SELECT). No exponer UPDATE/DELETE
  por OpenSQL desde la UI sin una barrera explícita.

## 8. Trabajo con subagentes (para el equipo)

Cada feature/fase es relativamente independiente → un subagente por feature, en su propio
**worktree** (`isolation: worktree`) para no chocar, con un brief de `briefs/` + este plan
+ §7 Seguridad. Roles sugeridos (se pueden mapear a subagentes especializados):
Arquitecto Lua/estado, Ingeniero de paridad VSCode, Experto LSP/AST/completion,
Especialista DAP/debugging, Diseñador UI/UX (flotantes/pickers), Ingeniero de integración
SAP (SE16N/SE91). Integración secuencial + revisión por fase. **Toda feature que toque SAP
se valida en vivo con objetos propios y respeta §7.**

## 9. Referencias

- Arquitectura del flujo de edición: `[[sapcli-read-write-workflow]]` (memoria) y commits
  `8d0cf81`, `118e7f8`, `3ce3ed5`, `6f9bc83`, `f220887`, `b9756d3`.
- Capacidades de sapcli verificadas: ver tabla en `SDD-PARIDAD-VSCODE.md §3`.
- Briefs por feature pendientes: `briefs/F12..F20`. Pendiente crear briefs para los nuevos
  R-A*/R-B*/R-C*/R-D* de §3.
