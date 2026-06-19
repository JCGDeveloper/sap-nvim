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
| F18 | Depurador (nvim-dap ⇄ ADT) | contrato de API mapeado; pendiente spike + adaptador |
| F19 | Revisiones / comparar versiones | pendiente |
| F20 | CDS preview | pendiente |

F0–F11, F13, F14, F16 ya implementados (ver SDD y `PLAN-MAESTRO.md §1`).

### Nuevos (sesión 2026-06-17 — capturas del usuario, ver `PLAN-MAESTRO.md §3`)

| Brief | Feature | Tipo |
|---|---|---|
| RB  | Formateo inteligente al guardar (pretty printer real) | pulido (alta prioridad) |
| RD1 | SE91: crear texto de mensaje directo | innovación |
| RD2 | Plantillas dinámicas estilo Eclipse | ✅ hecho (`core/templates.lua` + `template_vars.lua`) |

Pendientes de brief (especificados en `PLAN-MAESTRO.md §3`): keywords contextuales (R-A1),
ADT completion de sistema (R-A2), `gr` referencias (R-A3), go-to-type (R-A4), hover
bloqueable (R-A5), nav rápida buffers (R-A6), SE16N flotante (R-C1), debugging nvim-dap
(R-E, ver también F18).
