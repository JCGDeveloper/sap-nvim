# Brief F19 — Revisiones / comparar versiones

## Objetivo
Ver el historial de versiones de un objeto y comparar (diff) entre revisiones, como el
"compare versions" de la extensión de VSCode.

## Situación
- sapcli no expone revisiones de forma directa (verificar `sapcli adt` y subcomandos).
- La API ADT tiene versiones/revisions; puede requerir `vsp`/ADT directo.
- Ya existe `core/diff.lua` (diff local vs sistema) como base de UI de diff.

## Requisitos
- **R19.1** `:SapRevisions` → listar versiones del objeto actual (timestamp, autor, transporte).
- **R19.2** Elegir dos revisiones (o una vs la activa) y abrir un diff (`vim.cmd('diffsplit')`
  o `core/diff.lua`).

## Archivos a tocar
- Nuevo `lua/sap-nvim/core/revisions.lua`; reutilizar `core/diff.lua`.

## Verificación
Sobre un objeto propio con varias versiones, listar y diffear dos.

## Abierto / a decidir — INVESTIGAR
- Si sapcli/`vsp` exponen el historial de revisiones; si no, evaluar coste de ADT directo.
- Prioridad media-baja; depende de F18/vsp para el acceso ADT.
