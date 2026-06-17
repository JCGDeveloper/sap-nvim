# Brief F15 — BAdIs / enhancements

## Objetivo
Listar, activar/desactivar y **programar** implementaciones de BAdI desde Neovim.

## Comandos sapcli verificados
- `sapcli badi list -i <ENHANCEMENT_IMPLEMENTATION>` → lista de BAdIs del enhancement impl.
- `sapcli badi set-active ...` → modificar estado activo (ver `--help` para flags exactos).
- Programar el BAdI = editar su **clase de implementación** como clase normal con
  `source.open(clase_impl, 'class')`.

## Requisitos
- **R15.1** `:SapBadi <ENH_IMPL>` → `badi list -i` y mostrar BAdIs + estado en picker/quickfix.
- **R15.2** Activar/desactivar la implementación seleccionada con `badi set-active`.
- **R15.3** Desde la lista, abrir la clase de implementación del BAdI para editarla.

## Archivos a tocar
- Nuevo `lua/sap-nvim/core/badi.lua`.
- `init.lua`, `core/keymaps.lua`.

## Patrón a seguir
`core/browser.lua` (listar+picker) + `core/source.lua` (abrir la clase impl).

## Verificación en vivo
Con un enhancement implementation del usuario (si existe). Si no hay uno propio, validar al
menos `badi list -i` sobre un enhancement conocido (solo lectura) y dejar el set-active para
prueba manual del usuario.

## Abierto / a decidir — INVESTIGAR
- **Cómo resolver el nombre de la clase de implementación desde el BAdI/enhancement.**
  Opciones: salida de `badi list`, o `adt`/`abap find` por convención de nombre. Clave para R15.3.
- Flags exactos de `badi set-active` (`sapcli badi set-active --help`).
- Crear nuevas implementaciones de BAdI: ¿soportado por sapcli? (probablemente no; quizá
  solo editar existentes). Documentar el límite.
