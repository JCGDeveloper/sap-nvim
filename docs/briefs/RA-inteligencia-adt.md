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

## Pendiente (mismo cliente ADT) — endpoints de la extensión de VSCode
- **R-A2b Completado automático:** fuente `blink.cmp` async que llame `intel.proposals`
  (debounce; no bloquear). Hoy es omnifunc (on-demand, sync).
- **R-A5 Hover/elementinfo (Shift-K):** `POST /sap/bc/adt/abapsource/codecompletion/elementinfo`
  → firma + documentación del símbolo bajo el cursor. Ventana flotante; doble Shift-K la
  fija y se navega con hjkl.
- **R-A4/R-A1 Go-to-def del sistema + go-to-type:** `/sap/bc/adt/navigation/target`
  (navigation) → URI+posición del símbolo → abrir con `source.open`. Cubre ir a la
  definición de clases/métodos/tipos del sistema (no solo Z).
- **R-A3 Referencias (gr):** `/sap/bc/adt/repository/informationsystem/usageReferences`
  → lista de usos; mostrar en picker (Telescope/snacks) con Enter para navegar.
- **Keywords contextuales (R-A1):** el propio completion de ADT ya propone IMPORTING/
  EXPORTING/RETURNING según contexto — al integrar R-A2b se obtiene gratis.

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
