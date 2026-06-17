# Brief F14 — Visualizar tablas (DDIC + datos)

## Objetivo
Ver la definición DDIC de una tabla y consultar sus datos sin salir de Neovim, como el
data preview de la extensión de VSCode.

## Comandos sapcli verificados
- Datos: `sapcli datapreview osql "SELECT * FROM ZTABLE" --rows N -o json` (también
  `-o human`, `-n/--noheadings`). El statement es ABAP SQL **sin punto final**.
- Definición DDIC: `sapcli table read NAME` (también `structure read`, `dataelement read`,
  `domain read`).

## Requisitos
- **R14.1** `:SapTable NAME` → `table read NAME` en un buffer (filetype abap o texto).
- **R14.2** `:SapData {SELECT...}` y/o `:SapTableData NAME` (→ `SELECT * FROM NAME`):
  ejecutar `datapreview osql ... -o json --rows N`, parsear el JSON (`vim.json.decode`) y
  renderizar como tabla alineada en un buffer scratch (calcular ancho de columnas) o,
  alternativa simple, volcar a quickfix.
- **R14.3** `--rows` configurable (default p.ej. 100); avisar si se trunca.
- **R14.4** Manejar errores de osql (tabla inexistente, sin autorización) → notify.

## Archivos a tocar
- Nuevo `lua/sap-nvim/core/data.lua` (o `tables.lua`).
- `init.lua`, `core/keymaps.lua` (ayuda + `<leader>at?` libre, ojo: `<leader>at*` es
  transportes; usar otro prefijo, p.ej. `<leader>av` de "ver datos").

## Patrón a seguir
async/notify de `core/source.lua`. Render tabular: buffer scratch
(`nvim_create_buf`, `nvim_buf_set_lines`), `modifiable=false`, `buftype=nofile`.

## Verificación en vivo
`datapreview osql "SELECT * FROM T000 INTO TABLE @DATA(x)"`… mejor: `:SapData SELECT * FROM
T000` (tabla de mandantes, segura y pequeña) y `:SapTable T000`. Confirmar render legible.

## Abierto / a decidir
- Formato de render: tabla ASCII alineada (mejor UX) vs quickfix (más simple). Recomendado
  buffer scratch con columnas alineadas.
- ¿Editar datos? NO en v1 (solo lectura).
