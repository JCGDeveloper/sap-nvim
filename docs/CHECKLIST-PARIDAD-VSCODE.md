# Mapeo COMPLETO extensión VSCode `abap-remote-fs` → sap-nvim

> Objetivo: que programar en Neovim sea IDÉNTICO a VSCode. Aquí están **las 92 funciones**
> que registra la extensión (`client/src/commands/registry.ts`, objeto `AbapFsCommands`),
> mapeadas 1:1 contra lo que sap-nvim tiene HOY (inventario real del repo).
> Estado: ✅ hecho · ~ parcial/mejorar · ➕ FALTA (a implementar) · ⏸ nicho/diferido · N/A no aplica a nvim.
> Detalle por área: `PARIDAD-EDICION-CODIGO.md`, `PARIDAD-TRANSACCIONES-PAQUETES.md`.

## Conexión / setup (7)
| # | VSCode cmd | nvim | Estado |
|---|---|---|---|
|1|abapfs.connect|`:SapSetup` use-context|✅|
|2|abapfs.disconnect|—|➕ (menor)|
|3|abapfs.createConnection|`:SapSetup` crear contexto|✅|
|4|abapfs.connectionManager|`:SapSetup` gestionar|✅|
|5|abapfs.clearPassword|creds en config.yml|⏸|
|6|abapfs.changePassword|—|⏸|
|7|abapfs.selectDB|`:SapSetup` use-context|✅|

## Código (16)
| # | VSCode cmd | nvim | Estado |
|---|---|---|---|
|8|abapfs.activate|`:SapActivate`/`<leader>aa`|✅|
|9|abapfs.activateMultiple|—|➕ (activar paquete: `package activate`)|
|10|abapfs.search|`:SapSearchLive`/`<leader>aS` **en vivo + filtro de tipo `<C-f>`** (`&objectType`); CDS: `:SapSearchCds`/`<leader>cc`|✅|
|11|abapfs.create|`:SapNew`/`<leader>an`|✅|
|12|abapfs.createInEditor|crear + abrir|✅|
|13|abapfs.execute|`:SapRun`/`<leader>aR`|✅|
|14|abapfs.runInGui|`:SapRunTransaction`/SAP GUI|✅|
|15|abapfs.runInEmbeddedGui|(webview)|N/A (abrimos navegador)|
|16|abapfs.runTransaction|`:SapRunTransaction`/`<leader>ax`|✅|
|17|abapfs.quickfix|`:SapQuickfix`/`:SapQuickfixPreview`|~ **quick fixes locales/ADT detectados; falta aplicar edits ADT remotos completos**|
|18|abapfs.changeInclude|—|➕ **fijar programa principal del include (arregla `gd` cross-include)**|
|19|abapfs.showdocu|hover (`K`) parcial|~ (ABAP Doc completo)|
|20|abapfs.showObject|`source.open`/`gd`|✅|
|21|abapfs.extractMethod|`:SapRefactor`|✅|
|22|abapfs.cleanCode|pretty printer (`<leader>aF`)|~ (clean code/cleaner)|
|23|abapfs.setupCleaner|—|⏸|

## Test / calidad (14)
| # | VSCode cmd | nvim | Estado |
|---|---|---|---|
|24|abapfs.unittest|`:SapAUnit`/`<leader>aT`|✅|
|25|abapfs.createtestinclude|—|➕ crear include de test|
|26|abapfs.atcChecks|`<leader>aK` (ATC run)|✅|
|27-37|atcIgnore/atcRefresh/atcRequestExemption(+All)/atcShowDocumentation/atcAutoRefreshOn/Off/atcDocHistoryFwd/Back/atcFilterExemptOn/Off|`:SapQuality`/`:SapAtcPanel`|~ **ATC run + panel; falta worklist/exenciones/documentación completa**|

## Favoritos / organización (3)
|38|abapfs.addfavourite|—|➕ favoritos|
|39|abapfs.deletefavourite|—|➕|
|40|abapfs.manageTextElements|`:SapTextElements`/`:SapMessageManage`|~ (ver sí; editar text symbols por ADT pendiente)|

## Clase / jerarquía (4)
|41|abapfs.refreshHierarchy|`gh`/`gH` type hierarchy|✅|
|42|abapfs.pickObject|`:SapSearch` parcial|~ (picker de objeto)|
|43|abapfs.pickAdtRootConn|—|⏸ (UI)|
|44|abapfs.runClass|`:SapRunClass`/`<leader>aE`|✅|

## Revisiones / diff / merge (14)
|45-58|clearScmGroup/filterScmGroup/openrevstate/opendiff/opendiffNormalized/togglediffNormalize/prevRevLeft/nextRevLeft/prevRevRight/nextRevRight/changequickdiff/remotediff/comparediff/openMergeEditor|`:SapDiff`, `:SapRevisions`|~ local vs activo + historial ADT; falta diff entre dos revisiones, normalizar y merge|

## Transportes (13)
|59|abapfs.transportObjectDiff|—|⏸|
|60|abapfs.openTransportObject|—|➕ abrir objeto desde la orden|
|61|abapfs.openLocation|—|⏸|
|62|abapfs.deleteTransport|`:SapTransportDelete`/`<leader>atd`|✅|
|63|abapfs.refreshtransports|`:SapTransports`/`<leader>atl`|✅|
|64|abapfs.releaseTransport|`:SapTransportRelease`/`<leader>atr`|✅|
|65|abapfs.transportOwner|`:SapTransportReassign`/`<leader>ato`|✅|
|66|abapfs.transportAddUser|—|➕ añadir usuario a la orden|
|67|abapfs.transportRevision|—|⏸|
|68|abapfs.transportUser|`cts list --owner`|~|
|69|abapfs.transportCopyNumber|copia ID al portapapeles|✅|
|70|abapfs.transportRunAtc|—|⏸|
|71|abapfs.transportOpenGui|—|~ (abrir en GUI)|

## abapGit (14)
|72-85|refreshrepos/revealPackage/openRepo/pullRepo/createRepo/unlinkRepo/registerSCM/refreshAbapGit/pullAbapGit/pushAbapGit/addAbapGit/removeAbapGit/resetAbapGitPwd/switchBranch|`:SapCheckout` (solo bajar)|➕ **abapGit completo (sapcli `abapgit`/`gcts`): pull/push/repos/branch**|

## Trazas / diagnóstico (6)
|86-91|refreshTraces/deleteTrace/showDump/refreshDumps/activateCommLog/deactivateCommLog|`:SapDumps`/`:SapST22`|~ dumps ST22/ADT hecho; trazas y comm log pendientes|

## Datos / utilidades (4)
|—|abapfs.tableContents|`:SapTableData`/`:SapData`|✅|
|—|abapfs.exportToJson|(json interno)|➕ exportar datos a JSON|
|—|abapfs.showWalkThrough|—|N/A (tutorial)|
|—|abapfs.createObjectProgrammatically|`:SapNew`|✅|

## Feeds (8) ⏸ nicho (noticias/feeds ADT)
configureFeeds/refreshFeedInbox/viewFeedEntry/markAllFeedsRead/markFeedFolderRead/deleteFeedEntry/clearFeedFolder/showFeedInbox → ⏸

## Blame / sistema (3)
|—|showBlame/hideBlame|—|➕ blame (autor por línea, de revisiones) — nicho|
|—|refreshSystemInfoCache|—|⏸|

## RAP / S/4HANA (11)
|—|rapGenFromEditor|snippet RAP|~ (generador RAP)|
|—|publishServiceBinding/testServiceBinding|—|➕ service bindings (OData)|
|—|s4hLoad/Refresh/OpenObject/RunAtc/AskCopilot/OpenNote/Filter/ClearFilter|—|⏸ (S/4 Cloud / copilot, nicho)|

---

## Resumen (de 92)
- **✅ hecho:** ~26 (núcleo de edición, navegación, transacciones, transportes, paquetes, AUnit/ATC-run, datos, crear/borrar, activar).
- **~ parcial/mejorar:** ~9 (showdocu, cleanCode, manageTextElements, pickObject, transportUser, diff→revisiones, rapGen). _(búsqueda en vivo + filtro de tipo: hecha ✅)_
- **➕ FALTA (a implementar):** núcleo: changeInclude, createtestinclude, gestión ATC avanzada, favoritos, comparediff/remotediff/revisiones, abapGit (pull/push/repos/branch), transportAddUser/openTransportObject, exportToJson, showdocu completo.
- **⏸ nicho/diferido:** feeds, trazas/comm log, blame, S4H copilot, GUI embebida, walkthrough, setupCleaner, transportObjectDiff/openLocation/RunAtc/Revision, clearPassword/changePassword.
- **N/A:** runInEmbeddedGui (webview), showWalkThrough.

## Orden de ejecución para "idéntico" (núcleo primero)
1. **changeInclude** → fijar programa principal del include (arregla `gd` cross-include). [BUG]
2. ~~**search en vivo** (searchObject as-you-type)~~ ✅ hecho — `<C-f>` filtra por tipo (`&objectType`).
3. **quickfix / code actions ADT remotos** (fixProposals + fixEdits completos).
4. **createtestinclude**.
5. **gestión ATC** (exenciones, navegación, refresh).
6. **revisiones/comparediff/remotediff** (versiones de servidor).
7. **abapGit** (pull/push/repos/branch vía sapcli).
8. **favoritos**, transportAddUser/openTransportObject/transportUser, exportToJson, showdocu completo, cleanCode.
9. Nicho (feeds/trazas/dumps/blame/S4H/service bindings) al final, según interés.

Método por función: el orquestador (con red) saca de `abap-adt-api`/sapcli el endpoint exacto y
lo verifica en vivo; los subagentes implementan y auditan (código/§7). Verificar SIEMPRE con
objetos JCG del usuario.
