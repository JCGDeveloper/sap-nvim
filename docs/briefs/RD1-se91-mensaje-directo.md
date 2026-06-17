# Brief R-D1 — SE91: crear el texto del mensaje directo (innovación, no en VSCode)

## Objetivo
Desde un `MESSAGE` en el código, crear/editar el texto del mensaje en la clase de mensajes
(SE91) sin salir de Neovim. Manejar variables `&1 &2 &3 &4`.

## Caso de uso
El cursor está sobre algo como:
```abap
MESSAGE 'Material &1 no existe en planta &2' TYPE 'E'.
MESSAGE e001(zmsg_jcg) WITH lv_matnr lv_werks.
```
Acción `:SapMessage` / keymap → detectar clase de mensajes + nº + texto, y crear/actualizar
el texto en SE91. Si es literal (`MESSAGE 'texto'(001)`), ofrecer materializarlo en una
clase de mensajes (preguntar clase + número).

## Comandos / API
- sapcli `messageclass`: `create`, `read`, `message`, `activate`. **`write` está
  "not implemented yet"** → para crear/editar el TEXTO probablemente haya que usar el
  endpoint ADT de message class directamente (HTTP con las credenciales de
  `~/.sapcli/config.yml`) o el subcomando `message` (investigar `sapcli messageclass message --help`).
- Verificar primero qué permite `messageclass message` y `messageclass create`.

## Requisitos
- **R-D1.1** Parsear el statement MESSAGE bajo el cursor: tipo (E/W/I/S/A), nº, clase,
  texto literal y/o variables `WITH a b c d` → `&1..&4`.
- **R-D1.2** Resolver la clase de mensajes (de `MESSAGE exxx(clase)` o preguntar).
- **R-D1.3** Crear/actualizar el texto del mensaje (con los `&1..&4`), respetando longitud
  máxima de SAP y el mapeo de variables.
- **R-D1.4** Si la clase/numero no existe, ofrecer crearlos (`messageclass create`).

## Archivos
- Nuevo `lua/sap-nvim/core/message.lua`; `init.lua`, `keymaps.lua`.

## Verificación en vivo
Sobre una clase de mensajes propia `ZMSG_*`: crear un texto nuevo, releer y confirmar.
Nunca tocar clases de mensajes estándar (§7 Seguridad del plan maestro).

## Abierto / investigar
- Si el texto se puede escribir vía sapcli o hay que ir a ADT directo (alta probabilidad).
- Formato exacto del texto con `&1..&4` en SE91.
