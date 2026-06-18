# Paridad: transacciones · órdenes de transporte (CTS) · paquetes · ejecución de programas

> Referencia función-por-función VSCode (`abap-adt-api` / `vscode_abap_remote_fs`) vs sap-nvim,
> con endpoint/medio y el gap a implementar. Verificado contra el código real de `abap-adt-api`
> (src/api/transports.ts, objectcreator.ts, nodeContents.ts) y las capacidades de `sapcli`.
> Sistema de pruebas: sap-system.example.com:44310 cliente 501. Objetos JCG del usuario:
> programa `ZCAR_PRACFINAL_JCG`, paquete (ver `package stat`), transacción `ZPFJCG`.

## 1. Órdenes de transporte (CTS)

| Función | VSCode (`abap-adt-api`) — endpoint ADT | sap-nvim hoy | Gap / acción |
|---|---|---|---|
| Listar transportes del usuario | `userTransports` GET `/sap/bc/adt/cts/transportrequests?user=&targets=` | `transport.list_transports` (`sapcli cts list`, `:SapTransports`/`<leader>atl`) | ok (sapcli) |
| Crear orden | `createTransport` POST `/sap/bc/adt/cts/transports` (XML CreateCorrectionRequest) | `transport.create_transport` (`sapcli cts create transport DESC`, `<leader>atc`) | ok |
| Liberar | `transportRelease` POST `/sap/bc/adt/cts/transportrequests/{n}/{action}` | `transport.release_transport` (`sapcli cts release`, `<leader>atr`) | ok |
| **Borrar** orden | `transportDelete` DELETE `/sap/bc/adt/cts/transportrequests/{n}` | — | **AÑADIR** (`sapcli cts delete`) |
| **Reasignar** dueño | `transportSetOwner` PUT `/sap/bc/adt/cts/transportrequests/{n}` | — | **AÑADIR** (`sapcli cts reassign`) |
| Qué orden usar para un objeto | `transportInfo` POST `/sap/bc/adt/cts/transportchecks` | `source.resolve_transport` (selector + recordado por sesión) | ok (equivalente) |
| Detalles de una orden | `transportDetails` GET `.../transportrequests/{n}` | — | opcional |
| Añadir usuario/tarea | `transportAddUser` POST `.../{n}/tasks` | — | opcional |
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

Seguridad §7: crear/borrar transacción y paquete = solo objetos Z/Y, confirmación en borrado,
transporte vía selector. Ejecutar/abrir GUI = solo lectura (no modifica). Todo async / system con
timeout. La ejecución abre el navegador del usuario (no expone credenciales en claro).
