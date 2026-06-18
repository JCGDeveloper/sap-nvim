# Checklist maestro de paridad con la extensión VSCode `abap-remote-fs`

> Objetivo: tener EN NEOVIM **cada función** que tiene la extensión de VSCode, con el MISMO
> comportamiento. Columna vertebral del proyecto. Fuente: TODOS los métodos de `ADTClient`
> (abap-adt-api) + los comandos de la extensión. Estado: ✅ hecho · ~ parcial/mejorar ·
> ➕ falta · ⏸ diferido/niche. Se trabaja SECCIÓN a SECCIÓN: para cada una se saca el catálogo
> completo, se compara, y se replica función a función verificando en vivo.
> Detalle por área en: `PARIDAD-EDICION-CODIGO.md`, `PARIDAD-TRANSACCIONES-PAQUETES.md`.

## A. Conexión / sesión
- ✅ Login básico + sap-client + CSRF + cookies (`adt_http`).
- ✅ Conexión persistente keep-alive (daemon, como VSCode) + ping 120s (`adt_daemon`).
- ➕ Sesión stateful para lock+PUT (text elements/edición ADT) — daemon ya lo permite, falta usarlo.

## B. Navegación / abrir objetos (FS remoto)
- ✅ Abrir/editar/guardar con lock+transporte (`source.lua`, sapcli).
- ~ **Go-to-definition (`gd`)**: local ✅, sistema vía ADT ✅, PERO **cross-include (variable del
  TOP) FALLA** porque ADT `findDefinition` en un include necesita el **mainProgram** (contexto del
  programa principal) y aún no se pasa → BUG a corregir (ver §F navegación).
- ✅ Go-to-type (`gy`), go-to-implementation (`gI`) — verificar que `gd` sobre un tipo lleva al tipo.
- ✅ Referencias (`gr`, usageReferences). ~ falta usageSnippets (línea de contexto).
- ✅ Type hierarchy (`gh`/`gH`). ✅ Outline (`<leader>ao`).
- ➕ Navegación a buffers/objetos abiertos (quickpick). ⏸ findObjectPath (ruta del objeto).

## C. Edición inteligente (escribir código)
- ✅ Completado automático ADT (clases/métodos/atributos del sistema, keywords) — `sap_adt`.
- ✅ Completado LOCAL instantáneo (keywords + 51 plantillas) — `abap_local`.
- ✅ Hover (`K`), syntax check en vivo, pretty printer real, document highlights.
- ➕ codeCompletionFull/insertion (insertar método con params al aceptar).
- ➕ Quick fixes / code actions (fixProposals + fixEdits). ➕ Rename/refactor (refactorings).
- ⏸ extractMethod, changePackage, ABAP Doc completo, semantic tokens.

## D. Búsqueda de objetos  ← (sección pedida; ver §G)
- ~ `:SapSearch` (sapcli `abap find`) — funciona pero NO en tiempo real al escribir.
- ➕ **Búsqueda unificada en vivo** (searchObject, quickpick que consulta al teclear) — el "mejor"
  de VSCode. Es el gap principal de esta sección.
- ✅ packageSearchHelp (se usa en el picker de crear paquete).

## E. Paquetes / repositorio
- ✅ Explorar paquete (`:SapBrowse`), crear paquete, info (`:SapPackageInfo`).
- ⏸ Árbol de repositorio navegable (nodeContents anidado, expandir sub-paquetes), favoritos.

## F. Transportes (CTS)
- ✅ listar/crear/liberar/borrar/reasignar/ver-contenido + selección al guardar.
- ⏸ addUser, reference, configuraciones de búsqueda.

## G. Transacciones
- ✅ crear, ejecutar (WebGUI). ~ ver/where-used (sapcli 404 en IAM/Fiori). ✅ borrar.

## H. Ejecución
- ✅ AUnit, OpenSQL/data preview, ejecutar transacción/programa (WebGUI — abre navegador).
- ➕ runClass (ejecutar clase F9). ⏸ runQuery avanzado.

## I. Calidad / ciclo de vida
- ✅ ATC, activar, objetos inactivos, crear/borrar objetos, where-used, diff local.
- ⏸ revisions (comparar versiones del servidor), validateNewObject (validar nombre antes de crear).

## J. Innovaciones propias (NO en VSCode — mantener y ampliar luego)
- ✅ SE91 mensaje directo + gestión (ver/editar/borrar/crear), elementos de texto (3 categorías),
  plantillas/snippets con nomenclatura configurable.

---

## Plan de ejecución (sección a sección, "desde 0" pero sin tirar lo que ya funciona y está verificado)
1. **Navegación (§B)** — corregir `gd` cross-include (mainProgram context para includes), confirmar
   gd-sobre-tipo. Es un bug reportado y es núcleo.
2. **Búsqueda (§D)** — búsqueda unificada en vivo (searchObject as-you-type) con el picker del usuario.
3. **Edición (§C)** — quick fixes/code actions, codeCompletionFull, rename.
4. **Repositorio (§E)** — árbol navegable + favoritos.
5. Resto (runClass, revisions, usageSnippets, etc.) según prioridad.

Cada paso: sacar el catálogo de la sección de `abap-adt-api`, replicar el comportamiento exacto en
nvim, verificar en vivo con objetos JCG del usuario, commit. El validador y el auditor de seguridad
(subagentes) revisan; el orquestador hace lo que necesita red/SAP (los subagentes no tienen red).
