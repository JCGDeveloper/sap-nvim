# Paridad de edición de código ABAP — sap-nvim vs VSCode (abap-remote-fs) y Eclipse ADT

> **Propósito:** inventario EXHAUSTIVO de toda la experiencia de *escribir código ABAP* en
> (1) la extensión de VSCode `abap-remote-fs` de Marcello Urbani (con su librería
> `abap-adt-api`) y (2) Eclipse ADT, mapeado contra lo que **sap-nvim ya implementa hoy**,
> con el gap concreto, el endpoint/medio que lo respalda y una prioridad de fase.
>
> **Estado de la investigación:** el código actual de sap-nvim se leyó directamente
> (`core/intel.lua`, `adt_http.lua`, `formatter.lua`, `navigate.lua`, `snippets.lua`,
> `message.lua`, `textsymbol.lua`, `data.lua`, `integrations/adt_completion.lua`). Las
> capacidades de `abap-adt-api` / `abap-remote-fs` y los endpoints ADT, así como las reglas
> del Pretty Printer y las plantillas de Eclipse, se documentan a partir del conocimiento
> del API REST de ADT (no hubo acceso de red en esta sesión: WebSearch/WebFetch denegados;
> los nombres de método/endpoint se dan tal como los expone `abap-adt-api`, contrastar
> contra el repo cuando haya red). Donde un dato no se pudo verificar en vivo se marca con
> **(verificar)**.

---

## 0. Resumen ejecutivo

sap-nvim ya replica el **núcleo de inteligencia** de la extensión de VSCode usando el
**mismo motor**: el cliente HTTP directo contra la API REST de ADT (`core/adt_http.lua`),
que es exactamente lo que `abap-adt-api` hace por debajo. Ya están hechos, y en varios casos
**igual o mejor** que VSCode: code completion automático (blink), hover/elementinfo
bloqueable, go-to-definition/type/implementation del sistema, referencias (usageReferences),
syntax check real de SAP con posiciones exactas, Pretty Printer real de ADT, y dos
innovaciones que VSCode **no tiene** (SE91 directo + text elements; plantillas/snippets con
nomenclatura configurable).

Lo que falta para paridad **total** son los "bloques mayores" del API de ADT que la
extensión sí usa y sap-nvim aún no: **quick fixes / fix proposals con aplicación de deltas**,
**rename con todos los usos**, **call/type hierarchy**, **documentación completa en el item de
completado (resolve perezoso)**, **revisiones/comparar versiones**, y la inteligencia "fina"
(kinds ya están; falta doc-on-item y un float de signature help dedicado). Y la lista de
**plantillas/keywords contextuales de Eclipse** todavía no está cargada como insumo de R-A1
(hoy esos keywords llegan vía el code completion de ADT, no como plantillas estructuradas).

---

## 1. Tabla maestra de features de edición de código

Leyenda estado sap-nvim: `OK` hecho · `~` parcial · `falta` pendiente · `N/A` no aplica.
Prioridad: **A** = pulido alto valor/bajo riesgo · **B** = ayudas/datos · **C** = bloques
mayores e innovaciones.

| # | Feature | Cómo lo hace VSCode (`abap-remote-fs`/`abap-adt-api`) y Eclipse | Estado sap-nvim hoy | Gap | Endpoint ADT / medio | Prio |
|---|---|---|---|---|---|---|
| 1 | **Code completion automático** (clases/tipos/variables al escribir) | `codeCompletion(url, source, line, col)` → propuestas; despliegue automático | **OK** `intel.proposals_async` + fuente blink `adt_completion.lua` (≥2 chars y tras `=>`/`->`/`~`) | — | `POST /sap/bc/adt/abapsource/codecompletion/proposal?uri=…%23start=l,c` | A (hecho) |
| 2 | **Completion de miembros** tras `=>`/`->`/`~` | mismo endpoint, lista fija de la clase | **OK** (blink: una llamada, filtra local) | — | idem | A (hecho) |
| 3 | **Iconos/kind en el item** (método/clase/var/keyword) | mapea el `kind` ADT a `CompletionItemKind` | **OK** `KIND_MAP` (1 var, 2 clase, 3 método, 52 keyword) | resto de kinds ADT no mapeados (atributo, evento, tipo, interfaz…) caen a `Text` | campo `<KIND>` del proposal | A (menor) |
| 4 | **Info de tipo en el item** (label details) | `codeCompletionElement` enriquece el item | **OK** `labelDetails.description` por kind | descripción genérica; sin firma | `<KIND>` (label local) | B |
| 5 | **Doc completa en el item** (resolve perezoso al resaltar) | `codeCompletionFull` / `codeCompletionElement(url,src,l,c)` → firma + doc del item resaltado | **falta** | mostrar firma/doc del item resaltado (resolve) | `POST …/codecompletion/elementinfo` por item | C (bloque) |
| 6 | **Signature help** (parámetros al abrir `(`) | la extensión NO tiene float de firma propio: usa el completion de params | **~** la fuente blink dispara con `(`/`,` y completa nombres de params | float dedicado resaltando el param actual (opcional; VSCode tampoco lo tiene) | mismo proposal | B (menor) |
| 7 | **Hover / quick info** (firma + propiedades + doc) | `findDefinition`+`abapDocumentation` / element info → tooltip | **OK e igual/mejor** `intel.hover` (K), **bloqueable** (2ª K entra, scroll hjkl) | — | `POST …/codecompletion/elementinfo` | A (hecho) |
| 8 | **ABAP Doc** (documentación rica del objeto) | `abapDocumentation(url, source, line, col, lang)` → HTML | **~** la doc sale dentro del hover (limpia de tags) | render completo del HTML de ABAP Doc en float dedicado | `GET /sap/bc/adt/…/abapdocumentation` (o el de element info) | C |
| 9 | **Go-to-definition** (incl. sistema) | `findDefinition(url, source, line, startCol, endCol, mainProgram?)` | **OK** `intel.goto_definition("definition")` (gd) | — | `POST /sap/bc/adt/navigation/target?filter=definition` | A (hecho) |
| 10 | **Go-to-type** (tipo del dato) | mismo navigation/target con filtro de tipo | **OK** `gy` / `:SapGotoType` | — | `…/navigation/target?filter=typeDefinition` | A (hecho) |
| 11 | **Go-to-implementation** (de método de interfaz) | `findDefinition` con `implementation` | **OK** `gI` / `:SapGotoImpl` | — | `…/navigation/target?filter=implementation` | A (hecho) |
| 12 | **References / usos del símbolo** | `usageReferences(url, line, col)` + `usageReferenceSnippets` | **OK** `intel.references` (gr) → picker, Enter abre | sin snippets de contexto por uso; abre solo tipos conocidos (CLAS/INTF/PROG/FUGR) | `POST /sap/bc/adt/repository/informationsystem/usageReferences` | A (hecho) |
| 13 | **Snippets de cada uso** (línea de contexto) | `usageReferenceSnippets(references)` | **falta** | mostrar la línea/fragmento de cada referencia en el picker | `POST …/usageReferences/snippets` (verificar) | C |
| 14 | **Where-used clásico** | (ADT) | **OK** `:SapWhereUsed` (sapcli `<group> whereused`) | — | sapcli | A (hecho) |
| 15 | **Outline / document symbols** | `objectStructure(url)` (sección de fragmentos) | **OK** `:SapOutline` (escaneo de buffer, incl. INCLUDEs) | no usa `objectStructure` ADT (parsea el buffer); suficiente | escaneo local; alt. `GET …/objectstructure` | A (hecho) |
| 16 | **Workspace symbols / buscar objeto** | `searchObject(query, objType?, max)` | **OK** `:SapSearch` (sapcli `abap find`) | — | sapcli / `GET /sap/bc/adt/repository/informationsystem/search` | A (hecho) |
| 17 | **Syntax check en vivo** (posición exacta) | `syntaxCheck(...)` / check runs; diagnósticos con `#start=l,c` | **OK e igual** `intel.check_syntax` (debounce + on-save + `:SapCheck`) | solo mensajes del propio objeto (no de includes externos) | `POST /sap/bc/adt/checkruns?reporters=abapCheckRun` | A (hecho) |
| 18 | **Diagnósticos de estilo** (abaplint) | — (VSCode usa ADT; abaplint es aparte) | **OK + extra** abaplint LSP coexiste con el namespace propio | — | abaplint LSP local | A (hecho) |
| 19 | **Pretty Printer / formateo** (formateador real de SAP) | `prettyPrinter(source)` + `prettyPrinterSetting()` | **OK e igual** `formatter.format_via_adt` (regex como fallback) | no lee/expone los **settings** del PP del usuario (keyword case: Upper/Lower/None); no formatea **rango/selección** | `POST /sap/bc/adt/abapsource/prettyprinter` | A (hecho) / B (settings+rango) |
| 20 | **Format on save** | configurable | **OK** `setup({format={on_save=true}})` (BufWritePre, PP de ADT) | — | idem | A (hecho) |
| 21 | **Quick fixes / code actions (evaluar)** | `fixProposals(url, source, line, col)` → lista de propuestas | **~** la evaluación es factible (mismo cliente), no expuesta como acción | listar las propuestas de arreglo bajo el cursor | `POST /sap/bc/adt/quickfixes/evaluation` | C (bloque) |
| 22 | **Quick fixes (aplicar deltas)** | `fixEdits(proposal, source)` → deltas de texto a aplicar al buffer | **falta** | aplicar el delta devuelto al buffer | `POST /sap/bc/adt/quickfixes/edits` | C (bloque) |
| 23 | **Rename / refactor** (con todos los usos) | `renameEvaluate(uri,line,startCol,endCol)` → `renamePreview` → `renameExecute(...)` | **falta** | renombrar símbolo y propagar a todos los usos + transporte | `POST /sap/bc/adt/refactorings/renamings` (evaluate/preview/execute) | C (bloque, riesgo S1/S2) |
| 24 | **Extract method / otros refactors** | refactorings ADT | **falta** | extracción de método/variable | `POST /sap/bc/adt/refactorings/*` | C (bloque) |
| 25 | **Call hierarchy** | (ADT call hierarchy) | **falta** | quién llama / a quién llama | `…/callhierarchy` (verificar) | C (bloque) |
| 26 | **Type hierarchy** (super/subclases) | `typeHierarchy(url, source, line, col, superTypes?)` | **falta** | jerarquía de tipos en picker | `POST /sap/bc/adt/abapsource/typehierarchy` (verificar) | C (bloque) |
| 27 | **ATC (quality checks)** | `atcCustomizing`/`createAtcRun`/`atcWorklists` | **OK** ATC run | sin worklist navegable con exenciones | sapcli `atc run` / `…/atc/*` | A (hecho) |
| 28 | **ABAP Unit** | `unitTestRun(url)` | **OK** `:SapAUnit` | — | sapcli `aunit run` / `…/abapunit/testruns` | A (hecho) |
| 29 | **Activar (+ inactivos)** | `activate(...)`/`inactiveObjects()` | **OK** `:SapActivate`, `:SapInactive` | posiciones exactas de error de activación (F1b) usan heurística de token | sapcli + `…/activation` | A (hecho, F1b ~) |
| 30 | **Abrir/editar/guardar con lock+transporte** | FS remoto: `lock`/`setObjectSource`/`unLock` | **OK e igual** `core/source.lua` (vía sapcli read/write con lock+corrnr) | — | sapcli | A (hecho) |
| 31 | **Crear objetos** | `createObject(...)` | **OK** `:SapNew` | — | sapcli `<group> create` | A (hecho) |
| 32 | **Borrar objetos** | `deleteObject(...)` | **OK** `:SapDelete` (con confirmación S1/S2) | — | sapcli | A (hecho) |
| 33 | **Revisiones / comparar versiones** | `revisions(url)` + diff de revisiones | **~** `:SapDiff` (local vs activo); sin revisiones | listar versiones y comparar dos revisiones | `GET …/vit/versions` (verificar) | C (bloque) |
| 34 | **CDS: editar + preview** | edición + data preview | **~** editar sí; preview de CDS por entidad reciente | preview integrada estable | sapcli ddl/dcl/bdef + `datapreview` | B |
| 35 | **Data preview / SE16N** | `tableContents`/`runQuery` (Open SQL) | **OK** `:SapTableData`/`:SapData` (osql, alineado, reintento) | falta UI flotante SE16N (R-C1) + metadatos (nº filas/tipos) | sapcli `datapreview osql` / `…/datapreview` | B |
| 36 | **DDIC de tabla** | metadatos de tabla | **OK** `:SapTable` | — | sapcli `table read` | A (hecho) |
| 37 | **Document highlights** (resaltar ocurrencias) | LSP highlight del símbolo | **OK + ya hecho** `intel.document_highlight` (CursorHold) | local (no semántico) — VSCode tampoco resalta semántico aquí | local | A (hecho) |
| 38 | **Semantic highlighting** | tokens semánticos del servidor | **falta** (treesitter cubre lo visual) | colorear según análisis del servidor | tokens ADT (verificar) | C (menor) |
| 39 | **Inlay hints** | N/A (la extensión ABAP no los implementa) | **N/A** | — | — | — |
| 40 | **Code lens** | N/A (la extensión ABAP no los implementa) | **N/A** | — | — | — |
| 41 | **Templates / plantillas de código** | Eclipse: "ABAP templates" (Window→Preferences); VSCode: snippets básicos | **OK + mejor (base)** `snippets.lua` con **nomenclatura configurable** | falta el set COMPLETO de plantillas Eclipse + plantillas dinámicas guardables (R-D2) | LuaSnip + store local | A/C |
| 42 | **Completado contextual de keywords** (IMPORTING/RETURNING…) | Eclipse: propuestas contextuales por sección | **OK (vía ADT)** los keywords llegan del code completion de ADT por contexto | no hay un set local de plantillas de declaración (insumo R-A1, §2) | code completion ADT + plantillas locales | A |
| 43 | **SE91 mensaje directo desde `MESSAGE`** (INNOVACIÓN) | **No existe en VSCode ni Eclipse** | **OK — innovación** `message.lua` (`:SapMessage`/`<leader>am`): crea SE91 o text element y reescribe la línea | text element vía ADT en construcción (`textsymbol.lua`) | sapcli `messageclass` + ADT text elements | C (hecho, pulir) |
| 44 | **Plantillas dinámicas estilo Eclipse** (INNOVACIÓN buscador/guardar/`${OBJECT}`) | parcial en Eclipse; no en VSCode | **falta** (R-D2) | picker + guardar + variables `${OBJECT}/${DATE}/${AUTHOR}` | LuaSnip + store | C |
| 45 | **Debugging** (breakpoints/step/variables) | `debuggerListeners`/`debuggerStep`/… (ADT debugger) | **~ stub** `debugger.lua`/`vsp.lua` | suite nvim-dap completa | ADT debugger API vía `vsp` | C (mayor, fase E) |
| 46 | **Abrir en SAP GUI / transacción** | `runClass`/GUI link | **~** `adt.open_gui` | — | sapcli/ADT GUI link | B |
| 47 | **Auto-cerrar paréntesis/comillas, comentar, multicursor, folding** | editor VSCode | **OK** Neovim nativo / plugins del usuario + treesitter | — | nativo | A (hecho) |
| 48 | **Resaltado de sintaxis** | TextMate/treesitter | **OK** treesitter | — | `core/treesitter.lua` | A (hecho) |

---

## 2. Keywords y plantillas contextuales de Eclipse ADT (insumo de R-A1 "completado contextual")

Eclipse ADT ofrece dos mecanismos que el usuario percibe como "el editor me enseña la
estructura":

1. **Content assist contextual** (Ctrl+Espacio): propone los keywords válidos en la posición
   actual según la sección (definición de clase vs implementación vs método vs report). Esto
   en sap-nvim **ya llega del code completion de ADT** (endpoint `codecompletion/proposal`,
   kind 52 = keyword), porque ADT es contextual. **No hay que reimplementar la lógica de
   contexto**: ADT ya la aplica.
2. **ABAP templates** (Window → Preferences → ABAP Development → Editors → Source Code
   Editors → ABAP Templates): bloques expandibles con placeholders. Es lo que falta cargar en
   sap-nvim como plantillas estructuradas (hoy `snippets.lua` cubre un subconjunto).

### 2.1 Plantillas de **definición de clase/interfaz** (la lista que pide el usuario)

Forma exacta de las propuestas/plantillas más usadas al definir miembros (en `PUBLIC/
PROTECTED/PRIVATE SECTION`):

```abap
" Método de instancia con todos los parámetros
METHODS name
  IMPORTING
    !iv_param TYPE type
  EXPORTING
    !ev_param TYPE type
  CHANGING
    !cv_param TYPE type
  RETURNING
    VALUE(rv_result) TYPE type
  RAISING
    cx_exception .

" Método estático
CLASS-METHODS name
  IMPORTING !iv_param TYPE type
  RETURNING VALUE(rv_result) TYPE type
  RAISING   cx_exception .

" Constructores
METHODS constructor
  IMPORTING !iv_param TYPE type .
CLASS-METHODS class_constructor .

" Datos / constantes / tipos de instancia y estáticos
DATA mv_attr TYPE type .
CLASS-DATA gv_attr TYPE type .
CONSTANTS co_name TYPE type VALUE 'x' .
TYPES ty_name TYPE type .

" Eventos y alias
EVENTS evt_name EXPORTING VALUE(ev_x) TYPE type .
CLASS-EVENTS evt_name .
ALIASES alias FOR intf~member .

" Interfaces y redefiniciones
INTERFACES if_name .
METHODS meth REDEFINITION .
METHODS meth FINAL .
METHODS meth ABSTRACT .
```

Keywords de **cabecera de método** que el completado contextual debe ofrecer dentro de una
declaración: `IMPORTING`, `EXPORTING`, `CHANGING`, `RETURNING VALUE( )`, `RAISING`,
`EXCEPTIONS`, `DEFAULT`, `OPTIONAL`, `PREFERRED PARAMETER`, `REDEFINITION`, `ABSTRACT`,
`FINAL`, `FOR TESTING`, `FOR EVENT … OF …`, `AMDP OPTIONS`.

Keywords de **definición de clase**: `CLASS … DEFINITION [PUBLIC] [FINAL] [ABSTRACT]
[INHERITING FROM …] [CREATE PUBLIC|PROTECTED|PRIVATE] [FOR TESTING] [FRIENDS …]`,
`PUBLIC SECTION`, `PROTECTED SECTION`, `PRIVATE SECTION`, `INTERFACES`, `ALIASES`,
`METHODS`, `CLASS-METHODS`, `DATA`, `CLASS-DATA`, `CONSTANTS`, `TYPES`, `EVENTS`,
`CLASS-EVENTS`.

### 2.2 Plantillas de **estructuras de control** (las clásicas de Eclipse)

`if/endif`, `ifelse`, `case/when/endcase`, `do/enddo`, `while/endwhile`, `loop/endloop`,
`try/catch/endtry`, `method/endmethod`, `form/endform`, `module/endmodule`,
`select/endselect`, `class def/impl`, `function/endfunction`, `at selection-screen`,
`start-of-selection`. (sap-nvim ya cubre la mayoría en `snippets.lua`; faltan algunas y las
de declaración de miembros de §2.1.)

### 2.3 Plantillas de **nueva sintaxis 7.40+** (Eclipse las propone como content assist)

```abap
DATA(lv_x) = VALUE ty_tab( ( col1 = 1 col2 = 2 ) ).
DATA(lv_y) = COND #( WHEN cond THEN a ELSE b ).
DATA(lv_z) = SWITCH #( var WHEN 'A' THEN 1 ELSE 0 ).
DATA(lo_o) = NEW zcl_x( iv_param = 1 ).
DATA(lv_c) = CONV i( '1' ).
DATA(lr_r) = REF #( var ).
DATA(lv_s) = REDUCE i( INIT s = 0 FOR wa IN itab NEXT s = s + wa-n ).
DATA(lt_f) = FILTER #( itab WHERE n > 0 ).
DATA(lt_m) = CORRESPONDING #( src MAPPING tgt = src ).
LOOP AT itab INTO DATA(wa) ... .
LOOP AT itab ASSIGNING FIELD-SYMBOL(<fs>) ... .
```

### 2.4 Variables dinámicas que Eclipse resuelve en sus templates (insumo R-D2)

`${date}`, `${time}`, `${user}` (autor), `${class_name}`, `${enclosing_object}`,
`${cursor}`. sap-nvim debe mapear: `${OBJECT}` (de `vim.b.sap_obj`), `${AUTHOR}` (usuario
sapcli), `${DATE}`, `${PACKAGE}`.

---

## 3. Reglas exactas del Pretty Printer de ABAP (insumo de R-B "formateo")

> **Recomendación firme:** sap-nvim **ya usa el Pretty Printer REAL de SAP** vía
> `POST /sap/bc/adt/abapsource/prettyprinter` (`formatter.format_via_adt`). Ese endpoint
> aplica EXACTAMENTE las reglas de abajo en el servidor — es el mismo motor que SE80/ADT y la
> extensión de VSCode. Por tanto **no hay que replicar estas reglas a mano** para objetos
> remotos; el formateador por regex (`format_abap`) es solo el fallback offline y es el que
> conviene mejorar para casos sin conexión. Estas reglas sirven (a) para entender qué hace el
> PP y (b) para endurecer el fallback regex.

### 3.1 Mayúsculas de keywords (la opción del PP "Convert Uppercase/Lowercase Keyword")

- **Keywords → MAYÚSCULAS, identificadores → tal cual.** Es la configuración por defecto y la
  que el usuario espera ("Keyword Uppercase"). Hay tres modos en ADT
  (`prettyPrinterSetting`): **Upper**, **Lower** y **None** (no tocar). sap-nvim debería leer
  ese setting del servidor (gap del feature #19) para respetarlo.
- **Compuestos con guion son UN keyword:** `CLASS-METHODS`, `CLASS-DATA`, `CLASS-EVENTS`,
  `FIELD-SYMBOLS`, `READ-ONLY`, `NO-GAPS`, `START-OF-SELECTION`, `END-OF-SELECTION`,
  `TOP-OF-PAGE`, `LINE-SELECTION`, `SELECT-OPTIONS`, `FUNCTION-POOL`, `TYPE-POOLS`,
  `SYSTEM-CALL`. (El fallback regex de sap-nvim ya los lista en `KEYWORDS`; es el punto donde
  fallaba antes.)
- **No tocar:** contenido de literales `'...'`, plantillas de cadena `|...|`, comentarios
  (`*` a inicio de línea, `"` inline). El tokenizador de `formatter.lua` ya separa estos
  segmentos correctamente.
- **Identificadores nunca se "autocorrigen"** por similitud (el código actual ya lo evita: solo
  capitaliza coincidencias exactas en `keyword_set`).

### 3.2 Indentación (la opción "Indent")

- Indentación por estructura de bloque (CLASS/METHOD/IF/LOOP/CASE/DO/WHILE/TRY/SELECT…), con
  paso estándar (en ADT es configurable; SAP usa 2 espacios por nivel por defecto en el PP).
- `WHEN` se indenta un nivel dentro de `CASE`; el cuerpo del `WHEN`, otro nivel más.
- `PUBLIC/PROTECTED/PRIVATE SECTION` a un nivel dentro de `CLASS DEFINITION`; los miembros, un
  nivel más.
- Continuaciones de statement (statement partido en varias líneas) se alinean; el PP de ADT
  alinea por cláusula (IMPORTING/EXPORTING bajo METHODS).

### 3.3 Espaciado de la nueva sintaxis 7.40+ (lo crítico para que SAP no rechace el código)

ABAP exige **espacios dentro de los paréntesis** en expresiones/constructores y llamadas a
método. Reglas exactas:

- **Constructor con `#`:** SIEMPRE espacio antes de `#(` y espacios internos:
  `VALUE #( ... )`, `NEW #( ... )`, `COND #( ... )`, `SWITCH #( ... )`, `CONV #( ... )`,
  `REF #( ... )`, `CAST #( ... )`, `REDUCE #( ... )`, `FILTER #( ... )`,
  `CORRESPONDING #( ... )`. → `VALUE#(` es **inválido**; debe ser `VALUE #(`.
  *(El fallback regex ya fuerza `([%w_])#%(` → `%1 #(`.)*
- **Llamada a método / paréntesis funcional:** un espacio tras `(` y antes de `)` cuando hay
  contenido: `lo->meth( iv_a = 1 iv_b = 2 )`, `cl_x=>get( )`. Paréntesis vacío con espacio:
  `get( )` (no `get()`). Los parámetros con nombre llevan espacios alrededor del `=`:
  `iv_a = 1`.
- **Tablas/filas en VALUE:** `VALUE ty_tab( ( c1 = 1 c2 = 2 ) ( c1 = 3 ) )` — espacio tras
  cada `(` de fila y antes de cada `)`.
- **Operadores aritméticos/comparación:** espacios alrededor: `a + b`, `lv = lv + 1`,
  `a = b` (NO `a=b`). En la sintaxis nueva los operadores SIN espacio dan error de sintaxis.
- **Encadenado (`->`, `=>`, `~`)** sin espacios: `lo->meth( )`, `cl_x=>attr`, `if_x~meth`.
- **`@` de host expressions** en Open SQL pegado al nombre: `WHERE matnr = @lv_matnr`,
  `INTO TABLE @DATA(lt)`.

> **Conclusión R-B:** mantener `format_via_adt` como camino principal (ya hace todo esto
> correctamente). Para el fallback offline (`format_abap`), las únicas reglas que faltan
> endurecer son: (i) espacio interno en `meth( ... )` no solo en `#(`, (ii) espacios alrededor
> de `=` con nombre de parámetro, (iii) leer y respetar el setting de keyword case del usuario
> cuando haya conexión.

---

## 4. Backlog priorizado para paridad TOTAL de escritura de código

### 4.0 YA HECHO IGUAL O MEJOR QUE VSCode — NO TOCAR

Estos están al nivel de la extensión (mismo motor ADT) o por encima; cualquier trabajo aquí
es riesgo sin ganancia:

- Code completion automático + miembros + kinds + label details (`intel`, `adt_completion`).
- Hover bloqueable (2ª K entra y scroll) — **mejor que VSCode**.
- Go-to-definition / type / implementation del sistema (`gd`/`gy`/`gI`).
- References (`gr`, usageReferences) con picker.
- Syntax check real de SAP con posiciones exactas + abaplint de estilo en paralelo — **mejor**
  (dos fuentes de diagnóstico).
- Pretty Printer real de SAP (`format_via_adt`) + format-on-save.
- Document highlights, outline, search, where-used, ATC, AUnit, crear/borrar/activar, data
  preview, DDIC.
- Snippets con **nomenclatura configurable** — **mejor que los snippets fijos de VSCode**.
- **SE91 mensaje directo + text elements** — **innovación que VSCode/Eclipse NO tienen**.

### 4.1 Fase A — Pulido (alto valor, bajo riesgo)

- **A1. Plantillas/keywords contextuales (R-A1):** cargar el set completo de §2 (plantillas de
  declaración de miembros: `METHODS … IMPORTING/EXPORTING/RETURNING/RAISING`, `CLASS-METHODS`,
  `CLASS-DATA`, `EVENTS`, redefinición; y los constructores de §2.3) en `snippets.lua`/LuaSnip.
  El completado *contextual de keywords* ya lo da ADT; esto añade los **bloques estructurados**
  que ADT no expande. *Esfuerzo bajo, riesgo nulo (solo snippets locales).*
- **A2. Más kinds en el completado (feature #3):** mapear el resto de `<KIND>` ADT
  (atributo, evento, tipo, interfaz, constante) a iconos. *Esfuerzo bajo.*
- **A3. Endurecer el fallback regex del formateador (R-B, §3.3):** espacio interno en
  `meth( … )` y alrededor de `=` con nombre de param, para que el modo offline no genere
  código que SAP rechace. *Esfuerzo bajo; `format_via_adt` ya cubre el caso online.*

### 4.2 Fase B — Ayudas y datos

- **B1. SE16N flotante (R-C1, feature #35):** ventana flotante para `:SapTableData` con
  metadatos (nº filas, tipos) y `<leader>T`. *Esfuerzo medio; base hecha en `data.lua`.*
- **B2. Settings del Pretty Printer (feature #19):** leer `prettyPrinterSetting` del servidor
  para respetar keyword case Upper/Lower/None del usuario; soportar **formateo de rango**
  (selección visual). *Esfuerzo bajo-medio.*
- **B3. Float de signature help dedicado (feature #6):** resaltar el parámetro actual al
  escribir dentro de `( )`. *Opcional — VSCode tampoco lo tiene; esfuerzo medio.*
- **B4. CDS preview estable (feature #34):** consolidar la preview por entidad. *Medio.*

### 4.3 Fase C — Bloques mayores e innovaciones

- **C1. Quick fixes / fix proposals (features #21–22):** evaluar
  `quickfixes/evaluation` bajo el cursor → mostrar acciones → aplicar el delta de
  `quickfixes/edits` al buffer. *Esfuerzo alto (deltas de texto + UI de code action).*
- **C2. Rename con todos los usos (feature #23):** `refactorings/renamings`
  evaluate→preview→execute. *Esfuerzo alto + RIESGO (modifica muchos objetos → exige §7
  S1/S2/S3: solo objetos propios, confirmación, transporte correcto, preview obligatorio).*
- **C3. Doc completa en el item de completado (feature #5):** resolve perezoso con
  `elementinfo` del item resaltado. *Medio.*
- **C4. Type/Call hierarchy (features #25–26):** pickers de jerarquía. *Medio-alto.*
- **C5. Revisiones / comparar versiones (feature #33):** listar revisiones y diff. *Medio-alto.*
- **C6. Plantillas dinámicas (R-D2, feature #44):** picker + guardar desde UI + variables
  `${OBJECT}/${DATE}/${AUTHOR}/${PACKAGE}`. *Medio.*
- **C7. Pulir text elements del SE91 (feature #43):** terminar `textsymbol.create` vía ADT.
  *Medio.*

### 4.4 Fase E — Debugging (mayor, fuera del alcance de "escribir código" pero clave)

- **E1. nvim-dap + `vsp`/ADT debugger (feature #45):** spike primero. *Muy alto, alta
  incertidumbre.*

---

## 5. Mapa de endpoints ADT usados / por usar (referencia rápida)

| Endpoint ADT | Para qué | Estado |
|---|---|---|
| `…/core/discovery` | CSRF token + cookies | usado (`adt_http.ensure_token`) |
| `…/abapsource/codecompletion/proposal` | completion | usado (`intel`) |
| `…/abapsource/codecompletion/elementinfo` | hover / doc del item | usado (hover); pendiente para resolve del item |
| `…/navigation/target` | def / type / impl | usado (`intel`) |
| `…/repository/informationsystem/usageReferences` | referencias | usado (`intel`) |
| `…/checkruns?reporters=abapCheckRun` | syntax check exacto | usado (`intel`) |
| `…/abapsource/prettyprinter` | Pretty Printer real | usado (`formatter`) |
| `…/abapsource/prettyprinter` settings (`prettyPrinterSetting`) | keyword case del usuario | pendiente (B2) |
| `…/quickfixes/evaluation` + `…/quickfixes/edits` | code actions | pendiente (C1) |
| `…/refactorings/renamings` | rename | pendiente (C2) |
| `…/abapsource/typehierarchy`, callhierarchy | jerarquías | pendiente (C4, verificar) |
| versiones / revisions | comparar versiones | pendiente (C5, verificar) |
| ADT debugger (`debuggerListeners`/`debuggerStep`…) | debugging | pendiente (E1, vía `vsp`) |
| sapcli `read/write/activate/create/delete/whereused/aunit/atc/cts/datapreview/messageclass` | CRUD + lock + transporte + tests + datos | usado (`source`, `transport`, `data`, `message`, etc.) |

> Nota de seguridad (§7 del Plan Maestro): **todo lo de ADT directo en sap-nvim es de
> lectura/análisis**. Las escrituras siguen por sapcli con lock + transporte + confirmación.
> Cuando se implementen rename/quickfixes (C1/C2), que **escriben**, deben pasar por las mismas
> barreras (objetos propios Z/Y, confirmación, preview, transporte) o por sapcli.
