# Brief F18 — Depurador ABAP (nvim-dap ⇄ ADT Debugger)

> SDD del depurador. Contrato de API extraído de `abap-adt-api/src/api/debugger.ts` (el mismo
> backend que usa la extensión de VSCode). **sapcli NO depura**; todo va por la API ADT
> debugger sobre una sesión **stateful** (⇒ requiere el daemon persistente). Alta incertidumbre:
> **hacer el spike (§6.1) antes de escribir el adaptador.**

## 0. Modelo mental (lo más importante)

El debugger ADT **no usa un `session-id` en la URL**. El estado se mantiene con:
- **`terminalId` + `ideId`**: dos GUIDs que **genera el cliente** y se envían en TODAS las
  llamadas. Identifican "este IDE".
- **Sesión HTTP stateful** (cookies + `X-sap-adt-sessiontype: stateful`, sticky al mismo work
  process) — igual que el lock. ⇒ **obliga a conexión persistente: el daemon**.
- **External Breakpoints**: se registran con `scope="external"` + `requestUser`. Disparan
  cuando **ese usuario** ejecuta el código **en cualquier sitio** (SE38/WebGUI/RFC/batch).
- **Listener long-poll**: `POST /listeners` **bloquea hasta 100 h** hasta que un *debuggee*
  llega a un breakpoint; entonces devuelve el `Debuggee`. Es el "attach and wait".

**Flujo:** generar GUIDs → `setBreakpoints(external)` → `POST /listeners` (bloquea) → el usuario
ejecuta el objeto y para → el listener devuelve el debuggee → `attach` → ya se puede
`stack`/`variables`/`step` sobre la sesión stateful.

## 1. Endpoints esenciales

| Acción | Método + endpoint | Notas |
|---|---|---|
| Esperar breakpoint | `POST /sap/bc/adt/debugger/listeners` `?debuggingMode&requestUser&terminalId&ideId&checkConflict&isNotifiedOnConflict` | long-poll (bloquea) |
| Comprobar conflicto | `GET /sap/bc/adt/debugger/listeners` | mismo qs |
| Quitar listener | `DELETE /sap/bc/adt/debugger/listeners` | al desconectar |
| Set breakpoints | `POST /sap/bc/adt/debugger/breakpoints` (XML `dbg:breakpoints`) | `scope="external"` |
| Del breakpoint | `DELETE /sap/bc/adt/debugger/breakpoints/{id}` | |
| Attach | `POST /sap/bc/adt/debugger?method=attach&debuggeeId&debuggingMode&requestUser&dynproDebugging` | tras el listener |
| Settings | `POST /sap/bc/adt/debugger?method=setDebuggerSettings` (XML `dbg:settings`) | system/update debugging |
| **Stack** | `GET /sap/bc/adt/debugger/stack?method=getStack&emode=_&semanticURIs=true` | call stack |
| Ir a frame | `PUT /sap/bc/adt/debugger/stack/type/{type}/position/{n}` | selecciona frame |
| **Variables** | `POST /sap/bc/adt/debugger?method=getVariables` (XML asx:abap) | por IDs |
| Expandir var | `POST /sap/bc/adt/debugger?method=getChildVariables` (XML HIERARCHIES) | árbol (tablas/estructuras) |
| Set variable | `POST /sap/bc/adt/debugger?method=setVariableValue&variableName=` body=valor | |
| **Step** | `POST /sap/bc/adt/debugger?method=<step>` | `stepInto/stepOver/stepReturn/stepContinue/stepRunToLine/stepJumpToLine/terminateDebuggee` |

Headers comunes: `Accept: application/xml`. Variables usan
`...dataname=com.sap.adt.debugger.Variables`/`.ChildVariables`.

## 2. Payloads XML

### 2.a Set breakpoints (request)
```xml
<?xml version="1.0" encoding="UTF-8"?>
<dbg:breakpoints scope="external" debuggingMode="user" requestUser="DEV01"
  terminalId="<GUID>" ideId="<GUID>" systemDebugging="false" deactivated="false"
  xmlns:dbg="http://www.sap.com/adt/debugger">
  <syncScope mode="full"></syncScope>
  <breakpoint xmlns:adtcore="http://www.sap.com/adt/core" kind="line" clientId="bp1"
    skipCount="0" adtcore:uri="/sap/bc/adt/programs/programs/zrjcg_report/source/main#start=42"/>
</dbg:breakpoints>
```

### 2.b Stack (request → response)
`GET /sap/bc/adt/debugger/stack?method=getStack&emode=_&semanticURIs=true`
```xml
<stack>
  <stackEntry stackPosition="0" type="ABAP" program="ZRJCG_REPORT" line="42"
    uri="/sap/bc/adt/programs/programs/zrjcg_report/source/main#start=42"/>
  <stackEntry stackPosition="1" type="ABAP" program="ZCL_FOO=========CP" line="15"
    uri="/sap/bc/adt/oo/classes/zcl_foo/source/main#start=15"/>
</stack>
```

### 2.c Variables locales (request → response)
`POST /sap/bc/adt/debugger?method=getChildVariables`
```xml
<?xml version="1.0" encoding="UTF-8"?>
<asx:abap version="1.0" xmlns:asx="http://www.sap.com/abapxml"><asx:values><DATA>
  <HIERARCHIES>
    <STPDA_ADT_VARIABLE_HIERARCHY><PARENT_ID>@ROOT</PARENT_ID></STPDA_ADT_VARIABLE_HIERARCHY>
  </HIERARCHIES>
</DATA></asx:values></asx:abap>
```
```xml
<asx:abap><asx:values><DATA><VARIABLES>
  <STPDA_ADT_VARIABLE>
    <ID>@ROOT\LV_CARRID</ID><NAME>LV_CARRID</NAME><VALUE>LH</VALUE>
    <LENGTH>3</LENGTH><TABLE_LINES>0</TABLE_LINES><META_TYPE>simple</META_TYPE>
  </STPDA_ADT_VARIABLE>
  <STPDA_ADT_VARIABLE>
    <ID>@ROOT\LT_FLIGHTS</ID><NAME>LT_FLIGHTS</NAME><VALUE>Standard Table</VALUE>
    <TABLE_LINES>17</TABLE_LINES><META_TYPE>table</META_TYPE>
  </STPDA_ADT_VARIABLE>
</VARIABLES></DATA></asx:values></asx:abap>
```
Para expandir una tabla/estructura: repetir `getChildVariables` con `<PARENT_ID>@ROOT\LT_FLIGHTS</PARENT_ID>`.

## 3. Arquitectura del adaptador (decisión)

**El adaptador es un PROCESO externo, no Lua in-process.** Razones: el listener long-poll
bloquea horas, la sesión stateful debe persistir (proceso vivo), y **nvim-dap habla DAP/JSON
con adaptadores externos** (stdio/TCP) de forma nativa.

- **Recomendado (A) — reutilizar `abap-adt-api`:** vscode-abap-remote-fs YA tiene un debug
  adapter sobre estas funciones. Portarlo a un **DAP server standalone** (stdio) es lo más
  rápido y probado. `dap.adapters.abap = { type="executable", command="node", args={"abap-dap.js"} }`.
- **(B) — extender `vsp` (Go)** (stub ya integrado) para hablar DAP. Más trabajo, sin Node.

### Mapeo DAP ⇄ ADT
| DAP | ADT | Traducción |
|---|---|---|
| `attach` | GUIDs → `setBreakpoints` → `POST /listeners` | debuggee → `attach` → evento `stopped` |
| `setBreakpoints` | `POST /debugger/breakpoints` (external) | fichero local → ADT uri `#start=line` |
| `stackTrace` | `getStack` | `stackEntry[]` → `StackFrame{ id, name=program, line, source=<cache file> }` |
| `scopes` | (fijo) | Locals → ref `@ROOT`; Globals → `@DATAAGING` |
| `variables` | `getChildVariables(parent)` | `STPDA_ADT_VARIABLE` → `Variable{ name, value, variablesReference>0 si table/struct }` |
| `next/stepIn/stepOut/continue` | `step(stepOver/Into/Return/Continue)` | `<step>` → evento `stopped` |
| `setVariable` | `setVariableValue` | |
| `disconnect` | `terminateDebuggee` + `DELETE /listeners` | |

### Lado Lua de sap-nvim
- `core/debugger.lua` + `integrations/vsp.lua` (o nuevo `integrations/dap.lua`): configurar
  `dap.adapters.abap` y `dap.configurations.abap`, keymaps F5/F10/F11/Shift-F11, nvim-dap-ui.
- **Mapeo fichero↔uri** (crítico): breakpoints y source se traducen entre el fichero de caché
  (`~/.cache/nvim/sap-nvim/<ctx>/zcl_foo.clas.abap`) y la ADT uri
  (`/sap/bc/adt/oo/classes/zcl_foo/source/main#start=line`). Reutilizar `objtype.gitfile` y
  `source.cache_dir` que ya existen.

## 4. Tipos de step (DebugStepType)
`stepInto`, `stepOver`, `stepReturn`, `stepContinue`, `stepRunToLine`, `stepJumpToLine`,
`terminateDebuggee`.

## 5. Seguridad (§7 del plan)
- El debugger **no debe modificar datos de producción**: `setVariableValue` solo bajo
  confirmación; avisar fuerte si el contexto es productivo (statusline ya lo muestra).
- `requestUser` = el propio usuario (user-debugging). No depurar sesiones ajenas sin permiso.
- Limpiar SIEMPRE al desconectar: `terminateDebuggee` + `DELETE /listeners` (no dejar
  listeners colgados 100 h).

## 6. Roadmap por fases

1. **Spike (validar EN VIVO antes de diseñar):** con el daemon, a mano:
   `setBreakpoints(external)` → `POST /listeners` → ejecutar un `ZRJCG_*` en WebGUI → ver que
   el listener devuelve el debuggee → `getStack` + `getChildVariables`. **Valida el riesgo #1:
   que el daemon mantiene la sesión stateful del debugger.**
2. **Adaptador mínimo:** attach + breakpoints + `stopped` + stackTrace + continue/step.
3. **Variables/scopes** (árbol con `getChildVariables`) + watch.
4. **setVariable, run-to-line, breakpoints condicionales, disconnect/cleanup.**
5. **UX:** nvim-dap-ui, keymaps, mapeo de uris, indicador en statusline.

**Riesgo #1 = la sesión stateful del listener long-poll vía el daemon.** Por eso el spike va
primero.

## 7. Archivos
- `lua/sap-nvim/core/debugger.lua` (ampliar el stub), `integrations/vsp.lua`,
  posible `integrations/dap.lua`. Adaptador externo: nuevo (Node sobre `abap-adt-api`, o `vsp`).

## 8. Referencias
- Contrato: `abap-adt-api/src/api/debugger.ts` (listeners/attach/breakpoints/stack/variables/step).
- Stub actual: `core/debugger.lua`, `integrations/vsp.lua` (`vsp` en `~/sap-mcp/vsp`).
- Modelo user-debugging + external breakpoints: ver §0.
