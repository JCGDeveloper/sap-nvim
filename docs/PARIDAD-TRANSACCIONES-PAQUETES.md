# Paridad: transacciones · órdenes de transporte (CTS) · paquetes · ejecución de programas

> Referencia función-por-función VSCode (`abap-adt-api` / `vscode_abap_remote_fs`) vs sap-nvim,
> con endpoint/medio y el gap a implementar. Verificado contra el código real de `abap-adt-api`
> (src/api/transports.ts, objectcreator.ts, nodeContents.ts) y las capacidades de `sapcli`.
> Sistema de pruebas: el host/cliente vienen de tu `~/.sapcli/config.yml` (no se anotan aquí).
> Objetos de ejemplo del usuario: programa `ZCAR_PRACFINAL_JCG`, paquete (ver `package stat`),
> transacción `ZPFJCG`.

## 1. Órdenes de transporte (CTS)

| Función | VSCode (`abap-adt-api`) — endpoint ADT | sap-nvim hoy | Gap / acción |
|---|---|---|---|
| Listar transportes del usuario | `userTransports` GET `/sap/bc/adt/cts/transportrequests?user=&targets=` | `transport.list_transports` (`sapcli cts list`, `:SapTransports`/`<leader>atl`) | ok (sapcli) |
| Crear orden | `createTransport` POST `/sap/bc/adt/cts/transports` (XML CreateCorrectionRequest) | `transport.create_transport` (`sapcli cts create transport DESC`, `<leader>atc`) | ok |
| Liberar | `transportRelease` POST `/sap/bc/adt/cts/transportrequests/{n}/{action}` | `transport.release_transport` (`sapcli cts release`, `<leader>atr`) | ok |
| **Borrar** orden | `transportDelete` DELETE `/sap/bc/adt/cts/transportrequests/{n}` | `:SapTransportDelete` / `core.cts.delete_transport` | ok, opt-in productivo |
| **Reasignar** dueño | `transportSetOwner` PUT `/sap/bc/adt/cts/transportrequests/{n}` | `:SapTransportReassign` (`sapcli cts reassign`) | ok, opt-in productivo |
| Qué orden usar para un objeto | `transportInfo` POST `/sap/bc/adt/cts/transportchecks` | `source.resolve_transport` (selector + recordado por sesión) | ok (equivalente) |
| Detalles/objetos de una orden | `transportDetails` GET `.../transportrequests/{n}` | `:SapTransportContents`, `:SapTransportObjects`, abrir objeto/diff/GUI | ok best-effort |
| Añadir usuario/tarea | `transportAddUser` POST `.../{n}/tasks` | `:SapTransportAddUser` informativo: copia orden y abre SE09 si no hay wrapper seguro | safe fallback |
| Usuarios del sistema | `systemUsers` GET `/sap/bc/adt/system/users` | — | opcional (para reassign) |

`sapcli cts` soporta: **create / release / delete / reassign / list**. → exponer delete y reassign.

## 2. Paquetes

| Función | VSCode (`abap-adt-api`) | sap-nvim hoy | Gap / acción |
|---|---|---|---|
| **Crear paquete** | `createObject` con `pak:package` → POST `/sap/bc/adt/packages` (XML con name/type DEVC/K/packageType/superPackage/softwareComponent/transportLayer) | NO está en `:SapNew` (la lista de tipos no incluye paquete) | **AÑADIR** (`sapcli package create NAME DESC [--super-package] [--software-component] [--transport-layer] [--corrnr]`) |
| Explorar contenido | `nodeContents` POST `/sap/bc/adt/repository/nodestructure` (`parent_type=DEVC/K`, `parent_name`) | `browser.browse_package` (`sapcli package list -l`, `:SapBrowse`/`<leader>afb`) | ok (medio distinto, funciona) |
| Info/estado del paquete | — | — | **AÑADIR** (`sapcli package stat NAME` → `:SapPackageInfo`) |
| Sub-paquetes (recursivo) | nodeContents anidado | `package list -r` disponible, no expuesto | opcional |

## 3. Transacciones

| Función | VSCode (`abap-adt-api`) | sap-nvim hoy | Gap / acción |
|---|---|---|---|
| **Crear transacción** | **NO soportado** (TRAN no está en createObject) | `:SapNew`→Transacción, pero **ROTO**: `do_create` manda `NAME DESC PKG` y `sapcli transaction create` exige `-t {report,parameter,dialog,oo,variant}` (+ `--report-name` para report) | **ARREGLAR** new.lua: preguntar tipo y, si report, el programa; firma real `transaction create NAME DESC PKG -t TYPE [--report-name PROG] [--corrnr]` |
| Leer / where-used | (ADT) | `sapcli transaction read/whereused` | ok vía sapcli si se necesita |
| **Ejecutar** transacción | SAP GUI (webview / escritorio / navegador) | — | **AÑADIR** (WebGUI: `/sap/bc/gui/sap/its/webgui?~transaction=TCODE`, verificado 200) |

> sap-nvim es MÁS capaz que la extensión aquí: la extensión no crea transacciones; sapcli sí.

## 4. Ejecución de programas / reports

| Función | VSCode | sap-nvim hoy | Gap / acción |
|---|---|---|---|
| Ejecutar transacción | "Transaction Execution" + SAP GUI | — | **AÑADIR** `:SapRunTransaction [TCODE]` / `<leader>ax` → WebGUI `~transaction=` |
| Ejecutar report/programa | SAP GUI (SA38) | — | **AÑADIR** correr el programa del buffer vía WebGUI (SA38) o su transacción |
| Abrir objeto en SAP GUI | webview / desktop GUI / navegador | — | **AÑADIR** abrir WebGUI (navegador) — equivalente al "Web Browser GUI" de la extensión |

Mecanismo de ejecución (verificado): `GET <base>/sap/bc/gui/sap/its/webgui?sap-client=<cli>&~transaction=<TCODE>` → 200. Abrir esa URL en el navegador (WSL: `wslview`/`explorer.exe`; Linux: `xdg-open`; `vim.ui.open` si existe) replica el "Web Browser GUI" de la extensión. Para un report, `~transaction=SA38` y el programa, o la transacción propia del report.

## 5. Plan de implementación (función a función)

1. **new.lua** — arreglar creación de transacción (tipo + report-name) y añadir tipo "paquete"
   (firma propia, sin `source.open` tras crear; ofrecer explorar). Validación §7 S1 (Z/Y).
2. **core/gui.lua** (nuevo) — ejecutar transacción / abrir WebGUI (navegador) + ejecutar el
   report del buffer. Comandos `:SapRunTransaction`, `:SapRun`, `:SapWebGui` + atajos.
3. **transport.lua** — añadir borrar (`cts delete`) y reasignar (`cts reassign`) órdenes;
   `:SapTransportDelete` / `:SapTransportReassign`.
4. **core/data.lua o new.lua** — `:SapPackageInfo` (`package stat`).

## 6. CATÁLOGO EXHAUSTIVO por sección (todo lo que puede hacer)

> Fuente: TODOS los métodos del `ADTClient` de abap-adt-api + capacidades de sapcli. Estado:
> ✅ hecho · ➕ gap a implementar · ⏸ avanzado/diferido.

### 6.1 Transacciones (sapcli `transaction` — la extensión VSCode NO las gestiona)
- ✅ **Crear** (`create`, con tipo report/parameter/dialog/oo/variant) — `:SapNew`.
- ✅ **Ejecutar** (WebGUI) — `:SapRunTransaction`/`<leader>ax`.
- ➕ **Ver/leer** (`read`) — mostrar la definición de la transacción.
- ➕ **Borrar** (`delete`) — con confirmación §7.
- ➕ **Dónde se usa** (`whereused`).
- (write/activate existen en sapcli; poco habituales para una transacción.)

### 6.2 Órdenes de transporte / CTS (AdtClient transport*)
- ✅ transportInfo ≈ `resolve_transport` (qué orden usar al guardar).
- ✅ userTransports → **listar** (`<leader>atl`).
- ✅ createTransport → **crear** (`<leader>atc`).
- ✅ transportRelease → **liberar** (`<leader>atr`).
- ✅ transportDelete → **borrar** (`<leader>atd`).
- ✅ transportSetOwner → **reasignar dueño** (`<leader>ato`).
- ➕ transportDetails → **ver contenido** de una orden (objetos/tareas): `cts list transport NUM -r`.
- ⏸ transportAddUser → añadir usuario/tarea (sapcli no lo expone; ADT directo).
- ⏸ transportReference → localizar la orden de un objeto (ADT directo).
- ⏸ transportConfigurations/getTransportConfiguration/setTransportsConfig/createTransportsConfig/
  transportsByConfig → configuraciones de búsqueda de transportes (avanzado, niche).

### 6.3 Paquetes (AdtClient nodeContents/createObject/packageSearchHelp + sapcli package)
- ✅ **Crear** (`createObject` pak:package / `package create`) — `:SapNew`.
- ✅ **Explorar contenido** (`nodeContents` / `package list`) — `:SapBrowse`/`<leader>afb`.
- ✅ packageSearchHelp → buscar paquetes (ya se usa en el picker de crear, `adt.fetch_packages`).
- ➕ **Info/estado** (`package stat`) — `:SapPackageInfo`.
- ⏸ Explorar recursivo (sub-paquetes) — `package list -r` (disponible, no expuesto).
- ⏸ activate/check de paquete (`package activate`/`check`) — masivo, con cuidado §7.

### 6.4 Ejecución / running (AdtClient run*)
- ✅ runUnitTest → ABAP Unit (`:SapAUnit`).
- ✅ runQuery ≈ data preview OpenSQL (`:SapData`/`:SapTableData`).
- ✅ Ejecutar transacción / programa (WebGUI) — `:SapRunTransaction`/`:SapRun`.
- ➕ runClass → **ejecutar una clase** (F9, su método main/test) — vía WebGUI (SE24/ejecutar) o ADT.
- ✅ inactiveObjects → objetos inactivos (`:SapInactive`).

### 6.5 Ciclo de vida de objetos (transversal, ya cubierto)
- ✅ create/delete/activate/lock/unLock/getObjectSource/setObjectSource (vía sapcli en `source.lua`/
  `new.lua`); validateNewObject (➕ se podría usar para validar el nombre antes de crear).
- ✅ searchObject (`:SapSearch`), objectStructure (outline local), revisions (⏸ comparar versiones).

---

Seguridad §7: crear/borrar transacción y paquete = solo objetos Z/Y, confirmación en borrado,
transporte vía selector. Ejecutar/abrir GUI = solo lectura (no modifica). Todo async / system con
timeout. La ejecución abre el navegador del usuario (no expone credenciales en claro).
