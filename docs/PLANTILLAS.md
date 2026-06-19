# Plantillas y variables dinámicas (estilo Eclipse/ADT)

Guía de uso del sistema de plantillas de sap-nvim: store en disco, picker, guardar desde
la UI, variables dinámicas con paridad Eclipse y parametrización de includes completos.

Implementado en `lua/sap-nvim/core/templates.lua` (store/picker/guardar) y
`lua/sap-nvim/core/template_vars.lua` (motor de variables dinámicas). Se integra también con
el completado instantáneo (`integrations/abap_local.lua`) y los snippets (`core/snippets.lua`).

---

## 1. Atajos y comandos

Grupo de teclado **`<leader>aP`** (en buffers ABAP):

| Atajo | Comando | Acción |
|---|---|---|
| `<leader>aPi` | `:SapTemplate` | Insertar plantilla (picker con preview) |
| `<leader>aPs` | `:SapTemplateSave` | Guardar el **buffer** como plantilla |
| `<leader>aPs` (visual) / `<leader>aP` (visual) | `:'<,'>SapTemplateSave` | Guardar la **selección** como plantilla |
| `<leader>aPd` | `:SapTemplatesDir` | Mostrar la ruta de la carpeta |
| `<leader>aPe` | `:SapTemplateEdit` | Abrir/editar la carpeta de plantillas |

Store: **`~/.config/sap-nvim/templates/`** (respeta `$XDG_CONFIG_HOME`). Cada archivo
`*.abap` es una plantilla; el **nombre del archivo = nombre en el picker**; el contenido del
archivo = cuerpo. Son editables a mano.

---

## 2. Las tres sintaxis (no confundir)

| Escribes | Qué es | Cómo se rellena |
|---|---|---|
| `$MAYÚSCULAS` | **Variable dinámica** | Automático, con el contexto |
| `${1:texto}` | **Tab-stop** | Hueco editable; saltas con `Tab` |
| `$1` | **Tab-stop espejado** | Repite el valor del `${1:...}` |
| `${0}` | Posición final del cursor | — |

Las variables `$VAR` van en **MAYÚSCULAS y sin llaves** a propósito: así no chocan con los
tab-stops LSP `${1:...}`.

---

## 3. Variables dinámicas (paridad Eclipse/ADT)

| sap-nvim | Eclipse/ADT | Valor |
|---|---|---|
| `$OBJECT` | `${enclosing_object}` | Nombre del objeto ABAP del buffer |
| `$PACKAGE` | `${enclosing_package}` | Paquete real del objeto |
| `$SHORTTEXT` | `${shortText}` | Descripción del objeto |
| `$METHOD` | `${enclosing_method}` | Método que contiene el cursor |
| `$AUTHOR` / `$USER` | `${author}` / `${user}` | Usuario SAP activo |
| `$SYSTEM` | — | Sistema/contexto SAP activo |
| `$DATE $YEAR $MONTH $DAY $TIME` | `${date}` … | Fecha/hora locales |
| `$DOLLAR` | `${dollar}` | Un `$` literal |
| `${1:...}` / `${0}` | `${cursor}` | Tab-stops |

**Importante:**
- `$OBJECT/$PACKAGE/$SHORTTEXT/$METHOD` solo resuelven en un buffer que sea un **objeto
  SAP abierto con sap-nvim** (`:SapSearch`, `gd`, `:SapNew`). En un `.abap` suelto salen vacíos.
- `$PACKAGE` y `$SHORTTEXT` se leen de los metadatos ADT de forma **async al abrir**
  (`template_vars.prime`, llamado por `source.open`). Si insertas en el primer instante tras
  abrir, puede que aún no estén; `$PACKAGE` cae al paquete configurado y `$SHORTTEXT` a vacío.
  El resto (`$OBJECT/$AUTHOR/$DATE/$METHOD`…) es instantáneo.

---

## 4. Crear una plantilla

### Método A — Guardar desde código (rápido)
1. Abre un objeto **tuyo** con `:SapSearch` (para que `$OBJECT` coja el nombre real).
2. Selecciona el código en visual (`V`) o usa el buffer entero.
3. `<leader>aPs` (buffer) o, en visual, `<leader>aPs` / `<leader>aP`.
4. Escribe el **nombre** de la plantilla.
5. Responde a *"Otros nombres a parametrizar"* (ver §6) — vacío si no quieres.
6. Si el nombre del objeto aparece en el código, elige **generalizar** → `$OBJECT`.

### Método B — A mano (control total)
1. `:e ~/.config/sap-nvim/templates/mi_plantilla.abap`
2. Escribe el cuerpo con variables `$...` y tab-stops `${1:...}` / `${0}`.
3. `:w`.

---

## 5. Usar una plantilla

`<leader>aPi` (o `:SapTemplate`) → picker con preview → Enter. Se inserta con:
- las variables dinámicas ya **rellenadas**, y
- el cursor en `${1:...}`; `Tab` salta entre huecos; `${0}` es el final.

---

## 6. Parametrizar un include completo (lo que hace Eclipse)

Caso típico: tienes un include con todo su código y quieres reutilizarlo en otro,
cambiando automáticamente **todos los nombres necesarios** (no solo el del objeto).

Al **guardar** una plantilla, además de generalizar el nombre del objeto a `$OBJECT`,
puedes indicar **otros identificadores** (grupo de funciones, tabla, prefijo…) en el
prompt *"Otros nombres a parametrizar (coma)"*. Cada uno se convierte en un **tab-stop
numerado y espejado**: al reusar, escribes el nuevo valor **una vez** y cambia en todas
sus apariciones.

**Ejemplo.** Include `LZFG_CARSTOP` del grupo `ZFG_CARS` que usa la tabla `ZCARS`:

```abap
FUNCTION-POOL ZFG_CARS.
DATA gt_cars TYPE TABLE OF zcars.
* lógica de ZFG_CARS sobre zcars ...
```

Guardar → *Otros nombres a parametrizar:* `ZFG_CARS, zcars` → generalizar objeto: **Sí**.
La plantilla queda:

```abap
FUNCTION-POOL ${1:ZFG_CARS}.
DATA gt_cars TYPE TABLE OF ${2:zcars}.
* lógica de $1 sobre $2 ...
INCLUDE $OBJECT.
```

Al insertarla en otro include: `$OBJECT` se rellena solo; `Tab` → nuevo grupo (cambia en
todos los `$1`); `Tab` → nueva tabla (cambia en todos los `$2`).

---

## 7. Plantillas de ejemplo incluidas

En el store se crean/dejan algunas de muestra: `cabecera`, `cabecera_metodo`,
`clase_test` (test AUnit con `$OBJECT`), `select_loop`, `alv_sencillo`. Edítalas o
bórralas a tu gusto (`<leader>aPe`).

---

## 8. Snippets con variables dinámicas

Los snippets de `core/snippets.lua` también admiten variables dinámicas. Ejemplo: el
trigger `hdr` inserta una cabecera con `$OBJECT/$SHORTTEXT/$AUTHOR/$DATE/$PACKAGE/$SYSTEM`
ya rellenados.
