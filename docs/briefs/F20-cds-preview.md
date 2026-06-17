# Brief F20 — CDS: editar + preview de datos

## Objetivo
Editar vistas CDS (DDL/DCL/Behavior) y previsualizar sus datos, como la extensión de VSCode.

## Comandos sapcli verificados
- Editar: `sapcli ddl read/write` (CDS views), `sapcli dcl ...` (access control),
  `sapcli bdef ...` (behavior definition). Ya mapeados en `core/objtype.lua` (ddl/dcl/bdef).
- Preview de datos: `sapcli datapreview osql "SELECT * FROM Z_CDS_VIEW"` (la vista CDS se
  consulta como una entidad SQL).

## Requisitos
- **R20.1** Abrir/editar CDS con `source.open` (ya soportado vía objtype: ddl/dcl/bdef) —
  validar que `read/write/activate` funcionan para estos grupos.
- **R20.2** `:SapCdsData` sobre la vista CDS actual → `datapreview osql SELECT * FROM <view>`
  reutilizando el render de F14.
- **R20.3** Filetype/treesitter para CDS (ya hay algo en `core/treesitter.lua`/formatter
  dispatcher CDS).

## Archivos a tocar
- Reutilizar `core/source.lua` y el módulo de datos de F14; ajustes en `objtype.lua` si falta
  extensión CDS; `core/keymaps.lua`.

## Dependencias
- **F14** (render de datos osql) debe estar hecho primero.

## Verificación en vivo
Abrir una vista CDS `Z*` del usuario, editar+activar, y previsualizar sus datos.

## Abierto / a decidir
- Confirmar firmas `ddl/dcl/bdef read/write/activate` con `--help`.
- Nombre de la entidad SQL de la CDS (puede diferir del nombre del objeto DDLS).
