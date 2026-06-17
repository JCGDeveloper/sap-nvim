# Brief F18 — Depurador (alto esfuerzo)

## Objetivo
Depurar ABAP desde Neovim: breakpoints, step into/over/out, inspección de variables y pila.
Es la feature más compleja: **sapcli NO depura**; hay que usar la API ADT debugger.

## Punto de partida
- Existe `vsp` (Go, en `~/sap-mcp/vsp`) — servidor MCP/ADT ya integrado como stub en
  `core/debugger.lua` e `integrations/vsp.lua`. **Investigar qué expone `vsp`** sobre el
  debugger ADT (¿comandos de breakpoint/step/variables?).
- La API ADT debugger (la que usa la extensión de VSCode vía `abap-adt-api`) cubre:
  `debuggerListen`, `debuggerAttach`, `debuggerStep` (into/over/return/continue),
  `debuggerStackTrace`, `debuggerVariables`, `debuggerSetBreakpoints`.

## Requisitos
- **R18.1** Adaptador de depuración. Decisión clave: (a) implementar un adaptador `nvim-dap`
  que hable con `vsp`/ADT, o (b) UI propia en terminal/buffers. Recomendado evaluar nvim-dap.
- **R18.2** Breakpoints (set/clear en línea), control de ejecución (into/over/out/continue),
  panel de variables y stack.
- **R18.3** Sesión: arrancar listener, lanzar el objeto (programa/transacción/unit) y atachar.

## Archivos a tocar
- `lua/sap-nvim/core/debugger.lua` (ampliar el stub), `integrations/vsp.lua`.
- Posible nuevo `lua/sap-nvim/integrations/dap.lua` si se usa nvim-dap.

## Verificación en vivo
Poner un breakpoint en un programa `ZCAR_*` propio, ejecutarlo y parar en el breakpoint;
inspeccionar una variable; hacer step. Coordinar con el usuario (requiere ejecución en SAP).

## Abierto / a decidir — INVESTIGAR A FONDO
- Capacidades reales de `vsp` (leer su código/--help en `~/sap-mcp/vsp`).
- ¿Reimplementar las llamadas ADT debugger en Lua (HTTP) si `vsp` no basta?
- Protocolo: el debugger ADT es "user debugging" (atacha a tu sesión) — entender el flujo de
  listen/attach. Riesgo e incertidumbre altos: hacer un spike antes de comprometer diseño.
