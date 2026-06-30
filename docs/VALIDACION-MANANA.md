# Validación mañana — sap-nvim

Objetivo: validar sap-nvim de punta a punta sin depender de memoria ni de comandos sueltos. Sigue el orden. Si una fase falla, para ahí, copia la salida indicada y no pases a pruebas con escritura.

Regla base: no pruebes escrituras en paquetes reales hasta completar las fases de solo lectura. Las pruebas de creación/activación/release solo se hacen con un paquete `Z*/Y*` autorizado y una orden de transporte real de pruebas.

## Datos que debes tener antes de empezar

Rellena esta tabla en un bloc o en el ticket de validacion:

| Dato | Valor |
|---|---|
| Sistema / contexto sapcli | |
| Mandante | |
| Usuario SAP | |
| Host HTTPS ICM | |
| Puerto HTTPS ICM | |
| Paquete sandbox `Z*/Y*` | |
| Orden real de pruebas, si aplica | |
| Objeto ABAP existente read-only | |
| Clase con AUnit existente, si aplica | |
| Tabla pequena para data browser | `T000` si esta permitida |
| Programa/clase para debugger | |

Si falta paquete sandbox u orden real, completa solo las fases `LOCAL`, `SOLO LECTURA` y `$TMP`.

## Mapa de riesgo

| Tipo | Toca SAP | Permitido sin transporte | Ejemplos |
|---|---:|---:|---|
| Local | No | Si | tests offline, `abaplint`, logs, carga de plugin |
| Seguridad local | No | Si | permisos de `~/.sapcli/config.yml`, ausencia de password en repo |
| ADT read-only | Solo GET/POST de consulta | Si | `:SapDoctor`, busqueda, repositorio, hover, dumps, data preview |
| `$TMP` | No en SAP | Si | exportar logs a `/tmp`, estado aislado de Neovim |
| Escritura SAP | Si | No | `:SapNew`, `:SapPush`, `:SapActivate`, `<leader>aA` |
| Transporte real | Si | Requiere orden | crear objeto transportable, release assistant, release |

## 0. Preparar reporte de validacion

En shell, desde el repo:

```sh
cd /home/joaquin/sap-nvim
mkdir -p /tmp/sap-nvim-validacion
date -Is | tee /tmp/sap-nvim-validacion/inicio.txt
git rev-parse --show-toplevel | tee /tmp/sap-nvim-validacion/repo.txt
git status --short | tee /tmp/sap-nvim-validacion/git-status-inicial.txt
```

Criterio de exito: estas en `/home/joaquin/sap-nvim` y el directorio `/tmp/sap-nvim-validacion` existe.

Si falla: copia el comando y todo el error de terminal.

## 1. Validacion local

Estas pruebas no conectan a SAP.

### 1.1 Dependencias basicas

```sh
command -v nvim
nvim --version | head -n 3
command -v luajit
command -v python3
command -v node || true
command -v npm || true
command -v sapcli || true
command -v abaplint || true
```

Criterio de exito: `nvim`, `python3` y `luajit` existen. `sapcli` y `abaplint` deben existir para la validacion completa; si falta alguno, marca bloqueo parcial antes de conectar.

Si falla: copia la salida completa y anota que dependencia falta.

### 1.2 Tests offline del repo

```sh
bash test/run_offline.sh 2>&1 | tee /tmp/sap-nvim-validacion/offline-tests.log
```

Criterio de exito: termina con `sap-nvim offline tests OK`.

Si falla: copia:

```sh
tail -n 120 /tmp/sap-nvim-validacion/offline-tests.log
```

No sigas a pruebas SAP si falla carga de plugin, seguridad productiva, source, quickfix, transport, release o debugger.

### 1.3 Carga minima del plugin

```sh
env XDG_STATE_HOME=/tmp/sap-nvim-validacion/state \
  nvim --headless -u NONE -i /tmp/sap-nvim-validacion/shada \
  +'set rtp+=/home/joaquin/sap-nvim' \
  +'lua require("sap-nvim").setup(); print("LOAD_OK")' +qa
```

Criterio de exito: imprime `LOAD_OK`.

Si falla: copia toda la salida.

## 2. Seguridad local

### 2.1 Repo sin secretos obvios

```sh
git status --short
rg -n --hidden --glob '!*.bak' --glob '!test/reports/**' \
  'password:|passwd|BEGIN RSA PRIVATE KEY|api[_-]?key|secret' . || true
```

Criterio de exito: no aparecen passwords reales, claves privadas ni tokens. Falsos positivos de documentacion son aceptables si no contienen valores reales.

Si falla: copia la linea exacta, no pegues secretos en chats publicos. Sustituye valores por `<redacted>`.

### 2.2 Configuracion sapcli

```sh
ls -l ~/.sapcli/config.yml 2>/dev/null || true
rg -n 'password:' ~/.sapcli/config.yml 2>/dev/null || true
```

Criterio de exito: si existe `~/.sapcli/config.yml`, no debe tener `password:` en claro y sus permisos deben ser privados.

Corre esto si los permisos no son privados:

```sh
chmod 600 ~/.sapcli/config.yml
```

Si falla: copia `ls -l ~/.sapcli/config.yml` y elimina cualquier password antes de compartir.

## 3. Conexion SAP

Estas pruebas hacen login y lectura de sistema. No crean ni modifican objetos.

### 3.1 Configurar o seleccionar contexto

Dentro de Neovim:

```vim
:SapSetup
```

Usa el menu para crear o activar la conexion. Despues:

```vim
:SapLogin
:SapStatus
```

Criterio de exito: `:SapStatus` muestra contexto, host, mandante y usuario esperados.

Si falla: copia el mensaje exacto de `:SapStatus` o `:messages`.

### 3.2 Validacion read-only general

Dentro de Neovim:

```vim
:SapDoctor
```

Criterio de exito: checks de herramientas, TLS, permisos de config, login y consulta basica en verde. Warnings de permisos funcionales pueden ser aceptables si estan explicados.

Si falla: copia todo el panel de `:SapDoctor` y despues ejecuta:

```vim
:SapLogs
```

Exporta los logs:

```vim
:SapLogsExport /tmp/sap-nvim-validacion/saplogs-doctor.jsonl
```

Comparte `saplogs-doctor.jsonl` quitando datos sensibles si aparecen.

### 3.3 Discovery y daemon

```vim
:SapDiscovery
:SapDiscovery checkruns
:SapDiscovery transport
:SapDaemonTest
```

Criterio de exito: `:SapDiscovery` lista endpoints publicados por el sistema y `:SapDaemonTest` confirma conexion persistente o informa claramente que no esta disponible.

Si falla: copia codigos HTTP, ruta ADT y mensaje. Un `404` en endpoints opcionales no bloquea toda la validacion; un `401/403` en discovery/login si bloquea funciones ADT.

## 4. ADT read-only

Usa el objeto existente de la tabla inicial. Ejemplos: `ZCL_ALGO`, `ZPROG_ALGO`, `ZI_ALGO`.

### 4.1 Busqueda y apertura

```vim
:SapSearchLive
:SapSearch <OBJETO_EXISTENTE>
:SapRepository
```

En `:SapRepository`: expande un paquete, abre un objeto con Enter, filtra con `f`, refresca con `r`, copia metadata con `y` si aplica.

Criterio de exito: busqueda devuelve objetos esperados, el repositorio no bloquea la UI, y abrir un objeto muestra codigo remoto.

Si falla: copia query usada, tipo de objeto, mensaje y `:messages`.

### 4.2 Navegacion e inteligencia

Con un objeto remoto abierto:

```vim
:SapComplete
:SapHover
:SapCheck
:SapOutline
:SapWhereUsed
:SapHelp
:SapHelpPanel
:SapHelpRoutes
:SapCompleteDebug
```

Tambien prueba teclas:

| Tecla | Esperado |
|---|---|
| `K` | Hover con firma/documentacion |
| `gd` | Salta a definicion o informa que no hay destino |
| `gr` | Referencias o quickfix |
| `<C-Space>` / `<C-x><C-o>` | Completado manual |
| `<leader>aH` | Panel de documentacion |

Criterio de exito: no hay errores Lua, los paneles abren, y los fallos funcionales vienen como mensajes controlados.

Si falla: copia `:messages`, nombre del objeto, cursor aproximado y salida de `:SapCompleteDebug`.

### 4.3 Check, quickfix y aA sin modificar

Primero ejecuta solo check:

```vim
:SapCheck
:copen
```

Criterio de exito: quickfix abre con errores/warnings o indica que no hay problemas.

Para validar que el comando de activacion recursiva existe sin activarlo:

```vim
:verbose command SapActivateRecursive
```

No ejecutes `<leader>aA` ni `:SapActivateRecursive` todavia. Eso va en la fase con transporte real.

Si falla: copia `:verbose command SapActivateRecursive` y `:messages`.

## 5. Repositorio

Dentro de Neovim:

```vim
:SapRepository
:SapRepositoryRefresh
:SapIndexStatus
```

Opcional solo lectura si hay paquete sandbox:

```vim
:SapRepository <PAQUETE_SANDBOX>
:SapIndexBuild <PAQUETE_SANDBOX>
:SapIndexSearch <PATRON_Z>
```

Criterio de exito: el arbol muestra roots, favoritos, inactivos o transportes segun permisos; `SapIndexBuild` termina o reporta limitacion clara.

Si falla: copia paquete, filtro, status y `:messages`.

## 6. Transportes y release assistant

### 6.1 Read-only sin liberar

```vim
:SapTransports
:SapTransportHistory
:SapReleaseAssistant
```

Si tienes orden real de pruebas:

```vim
:SapTransportContents <TRKORR>
:SapTransportObjects <TRKORR>
:SapTransportReadiness <TRKORR>
:SapTransportConsistency <TRKORR>
:SapTransportReleaseJobs <TRKORR>
:SapTransportActions <TRKORR>
:SapReleaseAssistant <TRKORR>
```

Criterio de exito: lista ordenes/tareas, objetos, owner, target, readiness, inactivos y warnings. `:SapReleaseAssistant` no libera nada.

Si falla: copia TRKORR, comando, codigo HTTP y panel. `403` significa autorizacion CTS insuficiente; `404/405` en consistency/releasejobs puede ser endpoint no publicado y debe quedar anotado, no necesariamente bloquea.

### 6.2 Crear transporte real de prueba

Hazlo solo si hay autorizacion para crear una orden.

```vim
:SapTransportCreate
```

Criterio de exito: devuelve un TRKORR tecnico, por ejemplo `S4HK9xxxxx`, y aparece en `:SapTransports`.

Si falla: copia prompt, paquete usado, target y mensaje. No intentes release.

### 6.3 Release real

No liberes ordenes compartidas ni ordenes con objetos no creados para esta validacion.

Antes de liberar:

```vim
:SapReleaseAssistant <TRKORR>
```

Solo si el panel no muestra bloqueos y el responsable lo autoriza:

```vim
:SapTransportRelease <TRKORR>
```

Criterio de exito: el comando exige confirmacion fuerte y la orden/tarea queda liberada en SAP.

Si falla: copia el checklist completo, el mensaje de release y el estado posterior con `:SapTransportReadiness <TRKORR>`.

## 7. Pruebas en `$TMP`

Estas pruebas usan estado temporal local. No modifican SAP.

### 7.1 Estado aislado de Neovim

```sh
env XDG_STATE_HOME=/tmp/sap-nvim-validacion/state \
  nvim --headless -u NONE -i /tmp/sap-nvim-validacion/shada \
  +'set rtp+=/home/joaquin/sap-nvim' \
  +'lua require("sap-nvim").setup({ productive = { audit_file = "/tmp/sap-nvim-validacion/audit.log" } }); print(vim.fn.stdpath("state"))' +qa
```

Criterio de exito: imprime `/tmp/sap-nvim-validacion/state` o una ruta equivalente bajo `/tmp`.

Si falla: copia salida completa.

### 7.2 Export de logs

Dentro de una sesion normal de Neovim:

```vim
:SapLogs
:SapLogsExport /tmp/sap-nvim-validacion/saplogs-final.jsonl
```

Criterio de exito: existe `/tmp/sap-nvim-validacion/saplogs-final.jsonl`.

Si falla:

```sh
ls -la /tmp/sap-nvim-validacion
```

## 8. Crear CDS/DDIC seguro

Divide esto en plan read-only y creacion real.

### 8.1 Plan sin POST

Estos comandos calculan ruta y payload sin crear objeto:

```vim
:SapNewAdtPlan domain ZD_VALID_TMP <PAQUETE_SANDBOX>
:SapNewAdtPlan data_element ZDE_VALID_TMP <PAQUETE_SANDBOX>
:SapNewAdtPlan structure ZS_VALID_TMP <PAQUETE_SANDBOX>
:SapNewAdtPlan table ZT_VALID_TMP <PAQUETE_SANDBOX>
:SapNewAdtPlan cds_view ZI_VALID_TMP <PAQUETE_SANDBOX>
:SapNewValidateRoutes
:SapNewValidateRoutes ddic
```

Criterio de exito: muestra rutas ADT, MIME/XML calculado y rutas disponibles sin modificar SAP.

Si falla: copia tipo, nombre, paquete, ruta ADT calculada y codigo HTTP.

### 8.2 Creacion real con transporte

Hazlo solo con paquete sandbox y TRKORR de pruebas. Usa nombres unicos para evitar colisiones:

| Tipo | Nombre sugerido |
|---|---|
| Dominio | `ZD_VALID_<INICIALES>` |
| Data Element | `ZDE_VALID_<INICIALES>` |
| Estructura | `ZS_VALID_<INICIALES>` |
| Tabla | `ZT_VALID_<INICIALES>` |
| CDS | `ZI_VALID_<INICIALES>` |
| Clase AUnit | `ZCL_VALID_<INICIALES>` |

Dentro de Neovim:

```vim
:SapNew
```

Selecciona tipo, nombre, descripcion, paquete sandbox y transporte real de pruebas.

Criterio de exito: el objeto se crea, se abre el buffer remoto y aparece en `:SapRepository <PAQUETE_SANDBOX>` o en `:SapTransportObjects <TRKORR>`.

Si falla: copia tipo, nombre, paquete, TRKORR, ultimo prompt y `:messages`. Si el error es `409 already exists`, cambia nombre y anota colision. Si es `403`, no reintentes con mas permisos sin autorizacion.

## 9. Activar, check y AUnit

Usa solo objetos sandbox de la validacion.

### 9.1 Check antes de activar

```vim
:SapCheck
:copen
```

Criterio de exito: quickfix sin errores `E`. Warnings aceptables solo si estan entendidos.

Si falla: copia quickfix completo con `:copen`, lineas afectadas y `:messages`.

### 9.2 Activar objeto actual

```vim
:SapActivate
```

Atajo equivalente:

```text
<leader>aa
```

Criterio de exito: activacion OK o quickfix con errores posicionados.

Si falla: copia quickfix, nombre del objeto, TRKORR y panel de mensajes.

### 9.3 Activar raiz + includes relacionados

Solo en objeto sandbox con includes relacionados:

```vim
:SapActivateRecursive
```

Atajo equivalente:

```text
<leader>aA
```

Criterio de exito: preaudit/activacion conserva orden, no activa objetos ajenos y reporta cada objeto.

Si falla: copia lista de objetos que iba a activar, quickfix y `:messages`.

### 9.4 AUnit y ATC

```vim
:SapAUnit
:SapAUnitPanel
:SapAtcPanel
:SapQuality atc object <OBJETO_SANDBOX>
:SapQualityHistory
:SapAtcWorklist
```

Criterio de exito: AUnit pasa o muestra fallos en quickfix; ATC abre panel/worklist sin romper la sesion.

Si falla: copia panel, quickfix y cualquier `worklistId`/timestamp si aparece.

## 10. Completado, hover y documentacion

Con un objeto sandbox o read-only abierto:

1. Escribe `DATA lv_` y prueba completado manual.
2. En una referencia DDIC, ejecuta `:SapHover` o pulsa `K`.
3. En una clase/metodo, prueba `gd`, `gr`, `:SapGotoType`.
4. Busca documentacion:

```vim
:SapHelp CL_ABAP_TYPEDESCR
:SapHelpPanel
:SapHelpSearch BAPI_USER_GET_DETAIL
:SapHelpOpen CL_ABAP_TYPEDESCR
:SapHelpBrowser
```

Criterio de exito: completado devuelve candidatos relevantes o mensaje controlado; hover muestra firma/documentacion; docs abren panel/enlace oficial; navegador diagnostica plataforma.

Si falla: copia simbolo bajo cursor, filetype, `:SapCompleteDebug`, `:messages` y salida de `:SapHelpBrowser`.

## 11. Debugger: layout, steps, estructuras y tablas

Requisitos: `nvim-dap` disponible, usuario con permisos de debugger y programa/clase sandbox que pueda detenerse en breakpoint.

### 11.1 Layout y arranque

1. Abre el objeto que se va a depurar.
2. Coloca un breakpoint con el keymap de nvim-dap que uses o desde el UI.
3. Ejecuta:

```vim
:SapDebugCockpit
:SapDap
```

Criterio de exito: abre cockpit estilo SAP GUI, no queda dap-ui encima, y la sesion se detiene en el breakpoint o informa que espera ejecucion.

Si falla: copia `:messages`, objeto, linea de breakpoint y estado visual del cockpit.

### 11.2 Steps

Prueba estas teclas cuando la sesion este parada:

| Tecla/comando | Esperado |
|---|---|
| `<F5>` / `<leader>di` | step into |
| `<F6>` / `<F10>` / `<leader>do` | step over |
| `<F7>` / `<S-F11>` / `<leader>du` | step out |
| `<F8>` / `<leader>dc` | continue |

Criterio de exito: el cursor avanza, el cockpit conserva foco razonablemente y stack/variables se refrescan.

Si falla: copia ultimo step ejecutado, linea antes/despues y `:messages`.

### 11.3 Estructuras, tablas y watch

```vim
:SapDapWatch <VARIABLE>
:SapDebugWatchTab 1
:SapDebugDataExplorer
:SapDebugDataFilter <texto>
```

En el cockpit, abre una estructura y una tabla interna desde variables si existen.

Criterio de exito: estructuras son expandibles, tablas muestran filas/paginacion o un mensaje claro de no disponible.

Si falla: copia nombre de variable, tipo esperado, filtro usado y panel de Data Explorer.

### 11.4 Set variable

Por seguridad, solo en sandbox y solo si el perfil permite set-variable:

```vim
:SapDebugSetVariable <VARIABLE> <VALOR>
```

Criterio de exito: si esta bloqueado por `productive.allow_debug_set_variable=false`, el bloqueo queda claro y auditado. Si esta permitido en sandbox, el valor cambia y se ve en variables.

Si falla: copia bloqueo/audit o mensaje ADT. No fuerces opt-in en un sistema compartido.

### 11.5 Cierre

```vim
:SapDebugKillAll
:SapDapClearBreakpoints
```

Criterio de exito: no quedan sesiones colgadas ni breakpoints inesperados.

Si falla: copia `:messages` y pide limpieza en SAP si queda sesion debugger abierta.

## 12. Dumps

Solo lectura.

```vim
:SapDumps
:SapDumpsRoutes
:SapST22
```

Si hay dump reciente listado, abre detalle desde el panel o:

```vim
:SapDumpOpen <ID_O_URI_DEL_DUMP>
```

Criterio de exito: lista dumps o explica que el backend no expone rutas ADT; fallback a ST22 disponible.

Si falla: copia rutas probadas y codigos HTTP. Un `404` en ADT dumps puede ser limitacion del sistema; no bloquea el resto si ST22 funciona.

## 13. Data browser

Solo lectura, pero consulta datos. Usa tablas pequenas y permitidas.

```vim
:SapTable T000
:SapTableData T000
:SapData SELECT * FROM T000
```

Para CDS sandbox o read-only:

```vim
:SapCdsOpen ddls <CDS_EXISTENTE>
:SapCdsPreview
:SapCdsSql
```

Criterio de exito: muestra definicion DDIC, datos en formato legible y SQL/CDS preview si el backend lo permite.

Si falla: copia tabla/CDS, SQL exacto, codigo HTTP y mensaje. Si el error es autorizacion de datos, anota `S_TABU_DIS`/equivalente si aparece y no reintentes con tablas sensibles.

## 14. Rollback y sintomas

### 14.1 Rollback local

Estas acciones no tocan SAP:

```vim
:SapLogsExport /tmp/sap-nvim-validacion/saplogs-before-cleanup.jsonl
:SapLogsClear
:SapDebugKillAll
:SapDapClearBreakpointsRecursive
```

En shell:

```sh
git status --short
find /tmp/sap-nvim-validacion -maxdepth 2 -type f -print
```

No borres archivos del repo ni hagas `git reset`.

### 14.2 Rollback SAP

No borres objetos ni transportes desde sap-nvim salvo que el responsable lo pida explicitamente.

Para objetos sandbox creados:

1. Verifica en `:SapTransportObjects <TRKORR>` que solo contiene objetos de la prueba.
2. Decide con el responsable si se liberan, se dejan en la orden o se borran via SE80/ADT/SAP GUI.
3. Si hay locks, revisa en SAP GUI/SM12 o pide a Basis/propietario que los libere.

### 14.3 Sintomas frecuentes

| Sintoma | Probable causa | Que copiar |
|---|---|---|
| `401` | Credenciales/login caducado | `:SapStatus`, `:SapLogin`, panel `:SapDoctor` |
| `403` | Falta autorizacion `S_ADT`, CTS, tabla o debugger | comando exacto, objeto, rol esperado |
| `404` | Endpoint ADT no publicado | `:SapDiscovery <filtro>`, ruta ADT |
| `405` | Metodo no permitido | ruta, metodo, panel del comando |
| `409 already exists` | Objeto ya existe | nombre y tipo, elegir otro nombre |
| `423 Locked` | Objeto bloqueado por usuario/sesion | objeto, owner si aparece, TRKORR |
| Quickfix vacio con error | Parser de mensaje no encontro posiciones | `:messages`, salida raw/log |
| Hover/completion sin datos | Cursor sin contexto o endpoint limitado | simbolo, `:SapCompleteDebug` |
| Debugger no para | Breakpoint no registrado o flujo no ejecutado | objeto, linea, evento que dispara programa |
| Data browser falla | Autorizacion de tabla o SQL no soportado | SQL exacto, tabla, codigo HTTP |

## 15. Comandos de reporte

Ejecuta al final, haya exito o fallo:

```sh
cd /home/joaquin/sap-nvim
date -Is | tee /tmp/sap-nvim-validacion/fin.txt
git status --short | tee /tmp/sap-nvim-validacion/git-status-final.txt
find /tmp/sap-nvim-validacion -maxdepth 2 -type f -print | sort | tee /tmp/sap-nvim-validacion/manifest.txt
```

Desde Neovim:

```vim
:SapStatus
:SapCaps
:SapLogsExport /tmp/sap-nvim-validacion/saplogs-final.jsonl
```

Si el fallo fue de comandos Neovim, copia tambien:

```vim
:messages
:checkhealth sap-nvim
```

Si el fallo fue de transporte:

```vim
:SapTransportReadiness <TRKORR>
:SapReleaseAssistant <TRKORR>
:SapTransportObjects <TRKORR>
```

Si el fallo fue de rutas ADT:

```vim
:SapDiscovery <FILTRO>
:SapNewValidateRoutes <FILTRO>
:SapDumpsRoutes
:SapAtcRoutes
:SapHelpRoutes
```

## Cierre: criterios globales

La validacion se considera OK si:

- Tests offline terminan con `sap-nvim offline tests OK`.
- `:SapDoctor` no muestra bloqueos criticos de conexion/login/TLS/config.
- Busqueda, repositorio, apertura remota, hover, completado, check y docs funcionan o fallan con mensajes controlados.
- Transportes read-only y `:SapReleaseAssistant` muestran informacion sin liberar nada.
- `$TMP` contiene logs/export sin tocar estado del repo.
- Creacion/activacion/AUnit/ATC solo se ejecutaron en paquete sandbox y transporte real autorizado.
- Debugger abre cockpit, step funciona o deja una razon clara de permisos/backend.
- Dumps y data browser funcionan o documentan limitacion/autorizacion exacta.

La validacion se considera FAIL si:

- El plugin no carga.
- Los tests offline fallan en modulos centrales.
- `:SapDoctor` falla por login/TLS/config insegura.
- Una accion read-only modifica SAP.
- Una accion sensible no pide confirmacion/opt-in.
- Se activa, libera o borra algo fuera del paquete/orden de pruebas.
- Un error Lua rompe la sesion en flujos principales.
