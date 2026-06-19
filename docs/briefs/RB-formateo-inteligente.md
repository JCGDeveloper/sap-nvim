# Brief R-B — Formateo inteligente al guardar (pretty printer ABAP real)

## Objetivo
Que al guardar, el código quede formateado como en ADT/VSCode: keywords en mayúsculas
(TODOS, incl. compuestos), indentación por estructura y **espaciado correcto de la nueva
sintaxis** para que SAP no rechace los paréntesis.

## Estado (actualizado 2026-06-19)
- **R-B4 ✅ HECHO** — `formatter.format_via_adt()` usa el Pretty Printer real de ADT
  (`POST /sap/bc/adt/abapsource/prettyprinter`, el mismo de SE80/VSCode). `format_file()`
  lo prefiere para objetos remotos con conexión; cae al regex nativo solo offline. Expuesto
  en `<leader>aF`, `:SapFormat` y format-on-save (`config.format.on_save`).
- **R-B1 ✅** — los keywords compuestos (`CLASS-METHODS`, `CLASS-DATA`, `FIELD-SYMBOLS`...)
  ya están en `KEYWORDS` y el regex es consciente del guion.
- **R-B2 ✅** — indentación por bloque (`BLOCK_START`/`BLOCK_END`).
- **R-B3 ⚠️ parcial (seguro)** — el nativo offline ahora espacia el interior de los
  paréntesis de **constructor** `#( ... )` (`space_ctor_parens`, idempotente, probado).
  NO se espacian genéricamente otros paréntesis a propósito: corromper­ía offset/length
  `lv_text+0(10)` e inline `DATA(lv_x)`. El espaciado interior de llamadas a método
  (`meth( a )`) lo cubre el Pretty Printer de ADT online; offline se deja como está.

Conclusión: el camino preferente (printer de ADT) está cubierto; el resto es pulido del
fallback offline. **No rehacer `format_via_adt`.**

## Problemas actuales (verificados por el usuario)
- `core/formatter.lua` capitaliza pero **se deja keywords** (p.ej. `CLASS-METHODS`,
  `class methods`, `FIELD-SYMBOLS`). No es un pretty printer real.
- No respeta el espaciado estricto de ABAP 7.40+: `VALUE #( ... )`, `lo->meth( p = 1 )`,
  `cond #( ... )`. Un espaciado incorrecto hace que SAP marque el paréntesis como inválido.

## Requisitos
- **R-B1** Capitalizar TODOS los keywords ABAP incluyendo compuestos con guion
  (`CLASS-METHODS`, `CLASS-DATA`, `FIELD-SYMBOLS`, `READ-ONLY`, etc.) y multi-palabra
  (`READ TABLE`, `SORT BY`...), manteniendo identificadores en su caja original.
- **R-B2** Indentación por estructura (bloques CLASS/METHOD/IF/LOOP/...), no shift fijo.
- **R-B3** Espaciado de la nueva sintaxis: forzar `kw #( ... )` con los espacios exactos
  que exige SAP; respetar `meth( a = 1 )`. **Investigar las reglas en la extensión de
  VSCode (abapPrettyPrinter / abaplint) y replicarlas.**
- **R-B4 Preferente:** usar un pretty printer real en vez de reglas ad-hoc. Opciones:
  (a) **abaplint `--fix`** / sus reglas de formato (ya está integrado como LSP),
  (b) el **Pretty Printer de ADT** si es accesible vía API, (c) reescribir `formatter.lua`
  con un tokenizador robusto. Evaluar (a) primero: abaplint tiene reglas de keyword case y
  formato.

## Archivos
- `core/formatter.lua` (mejorar) o nuevo integrando abaplint `--fix`; el dispatcher actual
  ya separa ABAP/CDS.

## Verificación en vivo
Tomar un objeto propio con `class methods`, `value #(...)`, etc., guardar, y comprobar:
keywords todos en mayúscula, identificadores intactos, paréntesis con el espaciado que
SAP acepta (activar sin errores de sintaxis de paréntesis).

## Abierto / investigar
- Reglas exactas de espaciado de la nueva sintaxis (fuente: abaplint config del repo,
  `abaplint.json`, y la extensión de VSCode).
- Si abaplint `--fix` cubre keyword-case + spacing → es el camino más fiable.
