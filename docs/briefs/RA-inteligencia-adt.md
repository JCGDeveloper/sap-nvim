# Brief R-A — Inteligencia tipo VSCode vía ADT directo (clon de la extensión)

## Hallazgo clave (verificado en vivo)
La "inteligencia" de la extensión de VSCode (`abap-remote-fs` + `abap-adt-api`) — saber los
métodos/atributos de las clases que llamas, hover con firmas, ir a la definición del
sistema, referencias — **NO la da sapcli**. Viene de la **API REST de ADT**. Se confirmó
que se puede llamar a ADT directamente desde Neovim con las credenciales de
`~/.sapcli/config.yml` (auth básica + sap-client + CSRF token). Endpoint de completion:
`POST /sap/bc/adt/abapsource/codecompletion/proposal?uri=<objuri>%23start=<line>,<col>` con
el source en el body → XML `<SCC_COMPLETION>` con `<IDENTIFIER>`.

## Base ya construida
- `core/adt_http.lua`: cliente ADT (curl), creds del config.yml, CSRF + cookies, GET/POST.
  **Es la base de TODO lo de abajo.** Solo lectura/análisis; las escrituras siguen por
  sapcli (lock+transporte).
- `core/intel.lua`: **R-A2 code completion ✅** — omnifunc (`Ctrl-X Ctrl-O`) + `:SapComplete`.
  Conoce los miembros de la clase que llamas. Falta integrarlo con `blink.cmp` para
  completado automático mientras escribes.

## HECHO (mismo cliente ADT) — paridad con la extensión de VSCode
- **R-A2b Completado automático ✅:** fuente `blink.cmp` async
  (`integrations/adt_completion.lua`). Salta solo al escribir nombres de clase/tipo (≥2
  chars) y tras acceso a miembro (`=>`/`->`/`~`). Keywords contextuales (IMPORTING/
  EXPORTING/RETURNING) vienen del propio completion ADT.
- **R-A5 Hover/elementinfo (K) ✅:** `intel.hover` → firma + propiedades + documentación
  (limpia). Flotante bloqueable (2ª K entra, hjkl scroll).
- **R-A4/R-A1 Go-to-def del sistema + go-to-type ✅:** `intel.goto_definition` (navigation/
  target), integrado en `gd`; `gy` para el tipo. Resuelve clases/métodos/tipos del sistema.
- **R-A3 Referencias (gr) ✅:** `intel.references` (usageReferences) → picker, Enter abre.

## Pendiente / mejoras futuras
- **Kinds/iconos en el completado:** mapear `<KIND>` del proposal a método/clase/atributo.
- **Doc en el completado (resolve):** mostrar firma del item resaltado (elementinfo lazy).
- **Signature help:** al escribir `meth( ` mostrar los parámetros.
- **adt_http async total:** hover/def/refs son sync (on-demand, aceptable); migrar a
  jobstart si se quiere 0 bloqueo.

## Arquitectura
Un solo `adt_http` async (migrar de sync a jobstart para no bloquear), parseo de los XML de
ADT, y por cada feature un consumidor (`intel.lua` completion, `intel.hover`, `intel.def`,
`intel.refs`). Reutiliza `object_uri(group,name)` (mapa group→URI ADT) ya en `intel.lua`.

## Verificación
Cada endpoint, en vivo contra `PruebasJoaquin`, sobre objetos propios y del sistema
(solo lectura). Ya verificado: completion (50 propuestas tras `cl_abap_typedescr=>`).

## Seguridad
ADT directo es de **solo lectura/análisis** aquí. NUNCA usar estos endpoints para escribir/
activar/borrar (eso es sapcli con su lock+transporte+confirmaciones). Ver `PLAN-MAESTRO.md §7`.
