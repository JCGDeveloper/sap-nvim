# Briefs por feature — paridad VSCode

Un brief por feature pendiente del [SDD](../SDD-PARIDAD-VSCODE.md), listo para entregar a
un subagente (o ejecutar yo mismo). Cada brief es autocontenido.

## Cómo usar con un subagente

Lanzar con `isolation: worktree` (copia aislada del repo) y pasarle:
> Lee `docs/briefs/<Fxx>.md` y `docs/SDD-PARIDAD-VSCODE.md`. Implementa la feature
> siguiendo el patrón de `lua/sap-nvim/core/source.lua` y `core/navigate.lua`. Registra
> el módulo en `lua/sap-nvim/init.lua` y los keymaps/ayuda en `core/keymaps.lua`.
> Verifica en vivo contra el contexto `PruebasJoaquin` con un objeto `ZCAR_*` propio,
> sin tocar objetos estándar SAP, dejando el sistema como estaba.

## Convenciones (todas las features)

- Operaciones async con `vim.fn.jobstart` + `vim.schedule`; feedback con `vim.notify`
  (prefijo `[sap-nvim]`); errores a quickfix.
- Reutilizar `core/objtype.lua` (group↔extensión), `core/adt.lua` (contexto, parseo de
  errores) y `core/source.lua` (open/push/cache).
- Nunca escribir en el `cwd` del usuario; usar `source.cache_dir()`.
- Comprobar `adt.is_configured()` antes de tocar SAP.

## Índice

| Brief | Feature | Estado |
|---|---|---|
| F12 | Árbol del repositorio navegable | pendiente |
| F13 | Crear objetos | pendiente (siguiente) |
| F14 | Visualizar tablas (DDIC + datos osql) | pendiente |
| F15 | BAdIs / enhancements | pendiente |
| F17 | Autocompletado ADT | pendiente (baja prioridad) |
| F18 | Depurador (vsp/ADT) | pendiente (alto esfuerzo) |
| F19 | Revisiones / comparar versiones | pendiente |
| F20 | CDS preview | pendiente |

F0–F11, F16 ya implementados (ver SDD).
