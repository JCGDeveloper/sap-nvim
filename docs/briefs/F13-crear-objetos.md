# Brief F13 — Crear objetos

## Objetivo
Crear objetos ABAP nuevos desde Neovim y abrirlos para editar, cubriendo los tipos del día
a día. Cierra el ciclo: crear → editar → push → activar.

## Comandos sapcli verificados
- `sapcli class create NAME DESCRIPTION PACKAGE [--corrnr T]`
- Mismo patrón `create NAME DESC PACKAGE` para: `program`, `interface`, `table`,
  `structure`, `dataelement`, `domain`, `transaction`, `messageclass`, `ddl`, `dcl`, `bdef`.
  (Verificar la firma exacta de cada uno con `sapcli <group> create --help`; algunos
  -p.ej. functiongroup/functionmodule, transaction- tienen positional distintos.)
- Tras crear, abrir con `require('sap-nvim.core.source').open(NAME, group)`.

## Requisitos
- **R13.1** `:SapNew` (extender `core/new.lua`, que ya tiene plantillas) con picker de tipo
  (class, program, interface, function group, table, structure, data element, domain, CDS,
  message class, transaction).
- **R13.2** Pedir nombre → descripción → paquete; si el grupo es transportable, resolver
  transporte reutilizando `source.resolve_transport` (extraer/exponer si hace falta) o
  `adt.fetch_transport_orders`. Llamar `<group> create ... [--corrnr]`.
- **R13.3** Para objetos vacíos que lo requieran (clase), tras crear hacer `source.open`
  para que el usuario edite el esqueleto que SAP genera.
- **R13.4** Validar nombre (debe empezar por Z/Y o namespace) y avisar de errores de create
  (stderr de sapcli) a `vim.notify`.

## Archivos a tocar
- `lua/sap-nvim/core/new.lua` (ya existe; ampliar tipos y flujo de paquete/transporte).
- Posible refactor: exponer `source.resolve_transport` como API pública para reutilizar.
- `core/keymaps.lua` (ayuda), `init.lua` (ya carga `new`).

## Patrón a seguir
`core/source.lua` para async/notify/transporte; `core/new.lua` para las plantillas existentes.

## Verificación en vivo
Crear una clase `ZCAR_TEST_JCG` en el paquete del usuario con la orden `S4FK901556`,
confirmar que se abre, y **borrarla al final** (`sapcli class delete ZCAR_TEST_JCG`) para no
dejar basura. Repetir con un programa.

## Abierto / a decidir
- Firma exacta de `create` para functiongroup/functionmodule/transaction (consultar --help).
- ¿Pedir también superclase/interfaces al crear clase? (v1: no, esqueleto por defecto.)
