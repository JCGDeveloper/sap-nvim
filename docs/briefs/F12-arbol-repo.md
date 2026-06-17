# Brief F12 — Árbol del repositorio navegable

## Objetivo
Navegar el repositorio SAP como un árbol (paquetes → subpaquetes → objetos), estilo el
filesystem virtual de la extensión de VSCode, y abrir objetos con Enter.

## Comandos sapcli verificados
- `sapcli package list PATTERN` → lista de paquetes (p.ej. `Z*`).
- `sapcli package list -l PKG` → objetos del paquete en tabla `Object type | Name | Desc`.
  (Reutilizar el parseo de columnas que ya existe en `core/browser.lua`.)

## Requisitos
- **R12.1** Vista en árbol perezosa (lazy): expandir un paquete bajo demanda con
  `package list -l`; cargar subpaquetes con `package list` filtrando por jerarquía.
- **R12.2** Enter sobre objeto → `source.open(name, group)` (mapear tipo ADT→group con la
  tabla de `browser.lua`). Enter sobre paquete → expandir/colapsar.
- **R12.3** UI: decidir entre (a) buffer propio tipo árbol (más control), (b) integrar con
  `oil.nvim`/`snacks` si están, (c) `Neo-tree` source. v1 recomendado: buffer scratch con
  indentación + keymaps locales (Enter/expand, q/cerrar).

## Archivos a tocar
- Nuevo `lua/sap-nvim/core/tree.lua`.
- Reutilizar parseo de `core/browser.lua` (extraer helpers de columnas a un módulo común si
  conviene).
- `init.lua`, `core/keymaps.lua` (`:SapTree`, `<leader>aft` p.ej.).

## Patrón a seguir
`core/browser.lua` (ya hace `package list -l` y parseo de columnas) + `source.open`.

## Verificación en vivo
`:SapTree` → expandir un paquete `ZCAR*` del usuario → abrir un objeto. Confirmar lazy load.

## Abierto / a decidir
- Cómo obtener subpaquetes de un paquete (¿`package list PKG*`? ¿campo padre?). Investigar.
- UI definitiva (buffer propio vs integración). Empezar simple.
