# Brief F17 — Autocompletado ADT (baja prioridad)

## Objetivo
Autocompletado ABAP "real" basado en el sistema (propuestas ADT), como la extensión de
VSCode, más allá de lo que da abaplint en local.

## Situación
- **Gap real:** sapcli NO expone code completion. abaplint LSP ya da algo de completado
  local; medir si es suficiente antes de invertir.
- Opciones: (a) usar `vsp`/ADT directo (la API ADT tiene `codeCompletion`), (b) conformarse
  con abaplint. Baja prioridad si (b) cubre el día a día.

## Requisitos (si se aborda)
- **R17.1** Fuente de completado que consulte ADT en el punto del cursor y devuelva
  propuestas; integrarla como source de `blink`/`nvim-cmp` (ya hay `integrations/blink.lua`,
  `completion.lua`).

## Archivos a tocar
- `integrations/completion.lua`, `integrations/blink.lua`, posible `integrations/vsp.lua`.

## Verificación
Completar un nombre de método/tipo en un objeto propio y comparar con abaplint.

## Abierto / a decidir
- ¿Merece la pena vs abaplint? Hacer una evaluación corta primero y decidir con el usuario.
