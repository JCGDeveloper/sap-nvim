# Brief F19 — Revisiones / comparar versiones

## Objetivo
Ver el historial de versiones de un objeto y comparar (diff) entre revisiones, como el
"compare versions" de la extensión de VSCode.

## Situación
- sapcli no expone revisiones de forma directa (verificar `sapcli adt` y subcomandos).
- Primer bloque implementado por ADT directo: discovery del `link rel=.../versions`, probes de
  rutas conservadoras y fallback claro cuando el backend no expone historial/contenido.
- Ya existe `core/diff.lua` (diff local vs sistema) como base de UI de diff.

## Requisitos
- **R19.1** `:SapRevisions` → listar versiones del objeto actual (timestamp, autor, transporte).
- **R19.2 parcial** Panel: `d` diff local vs revision, `a` activo vs revision si ADT devuelve
  contenido de fuente; `:SapRevisionRoutes` prueba rutas ADT; `:SapRevisionDiff [id]` abre diff.
- Pendiente: diff revision-vs-revision y validación contra más variantes de backend ADT.

## Archivos a tocar
- Nuevo `lua/sap-nvim/core/revisions.lua`; reutilizar `core/diff.lua`.

## Verificación
Sobre un objeto propio con varias versiones, listar y diffear dos.
Offline: `test/revisions_spec.lua` cubre parser XML/Atom/JSON y registro de comandos.

## Abierto / a decidir — INVESTIGAR
- Si sapcli/`vsp` exponen el historial de revisiones; si no, evaluar coste de ADT directo.
- Prioridad media-baja; depende de F18/vsp para el acceso ADT.
