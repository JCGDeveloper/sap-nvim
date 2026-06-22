# sap-nvim

Un plugin de Neovim para desarrollo ABAP en SAP. Se integra con `sapcli` y `abaplint` para
traer herramientas de nivel Eclipse/VSCode a Neovim: diagnósticos en tiempo real, activación
con quickfix, runner de tests, gestión de transportes, explorador de objetos, soporte CDS y más.

> 📖 **[Manual de usuario completo → `docs/MANUAL.md`](docs/MANUAL.md)** — instalación, todas las
> funciones, atajos y la capa de IA (agentes que programan en SAP).

---

## Requisitos

| Herramienta | Para qué | Instalación |
|-------------|----------|-------------|
| [sapcli](https://github.com/jfilak/sapcli) | Operaciones ADT (activar, checkout, AUnit, transportes…) | `pipx install git+https://github.com/jfilak/sapcli.git` |
| [abaplint](https://github.com/abaplint/abaplint) | Linting y chequeos de naming en tiempo real | `npm install -g @abaplint/cli` |
| Neovim ≥ 0.9 | Host del plugin | — |
| Proveedor de `vim.ui.select` | Pickers (Telescope, fzf-lua o el nativo) | opcional |

---

## Instalación

Hay dos caminos. Elegí **uno**. Si ya tenés una config de Neovim (LazyVim u otra) que
no querés tocar, los dos respetan tu `init.lua`: **ninguno lo sobrescribe**.

### Opción A — Script automático (se instala solo)

Para **WSL2**, Linux y macOS. Detecta tu SO/distro, instala las dependencias y **añade el
plugin sin tocar tu configuración existente**.

```sh
# 1) cloná el repo
git clone https://github.com/JCGDeveloper/sap-nvim.git ~/sap-nvim

# 2) corré el bootstrap
bash ~/sap-nvim/scripts/bootstrap.sh
```

**Qué hace** (paso a paso, en orden):

1. Detecta el gestor de paquetes (`apt`/`dnf`/`pacman` en Linux/WSL2, Homebrew en macOS).
2. Instala Neovim si falta.
3. Instala las deps del sistema: `git`, `ripgrep`, `fd` y un **compilador C** (para que
   nvim-treesitter compile los parsers `abap`/`cds`). `efm-langserver` es opcional y se
   omite si no está disponible en tu gestor.
4. Instala Node.js + npm si faltan.
5. Instala Python 3 + pip si faltan.
6. Instala las herramientas ABAP: `sapcli` (pip) y `abaplint` (npm).
7. **Config de Neovim — NO destructiva:**
   - Si **ya tenés** `~/.config/nvim/init.lua` → no lo toca. Solo crea
     `~/.config/nvim/lua/plugins/sap-nvim.lua` (lazy.nvim lo carga solo). Si ese archivo
     ya existe, no cambia nada.
   - Si **no tenés** ninguna config → genera una mínima con lazy.nvim desde cero.
8. **Instala el IDE SAP completo y aislado** (`~/.config/nvim-sap` + alias `nvim-sap`): la
   experiencia full (completado ADT, pickers, debugger, dashboard, tema) en una config de
   Neovim **separada** que NO toca tu `nvim` normal. Si ya existe, no lo sobrescribe. Es la vía
   recomendada para que "todo funcione" de una. Lánzalo con **`nvim-sap`** (la 1ª vez lazy
   instala todos los plugins: espera y reinicia).
9. Intenta instalar los parsers de tree-sitter (`abap`, `cds`) en modo headless
   (best-effort, con timeout). Si no lo logra, abrí Neovim y corré `:TSInstall abap cds`.
10. Corre una validación final y lista qué quedó OK y qué falta.

Es **idempotente**: podés correrlo las veces que quieras sin romper nada. Para deshacer,
borrá `~/.config/nvim/lua/plugins/sap-nvim.lua`, `~/.config/nvim-sap`, el alias `nvim-sap` de
tu shell rc, y desinstalá las herramientas.

> **Dos formas de usarlo**, ambas las deja listas el bootstrap: (a) **`nvim-sap`** → IDE SAP
> completo y aislado (recomendado para tu compañero); (b) tu **`nvim`** normal → el plugin
> añadido a tu config sin `sap_mode` (solo `:SapHome`, sin tocar tus keymaps). El completado
> ADT y los pickers requieren las dependencias del IDE; por eso la vía (a) es la que lo trae todo.

> **Sobre WSL2 y "no tocar el ordenador de empresa":** WSL2 es una VM Linux aislada del
> Windows host. `sudo apt` dentro de WSL **solo toca tu Ubuntu de WSL**, nunca Windows. El
> script no instala nada en el lado Windows. Ver [Windows: instalar bajo WSL2](#windows-instalar-bajo-wsl2)
> para el detalle de red/VPN, que es el único punto delicado real.

Flags útiles:

```sh
bash ~/sap-nvim/scripts/bootstrap.sh --skip-packages   # no instala paquetes de sistema (ya los tenés)
bash ~/sap-nvim/scripts/bootstrap.sh --help
```

### Opción B — Manual, paso a paso

Si preferís controlar cada paso (recomendado en máquinas de empresa para ver exactamente qué
se instala):

**1. Instalá las herramientas externas** (no requieren tocar tu config de nvim):

```sh
# Linux / WSL2 (Ubuntu/Debian)
sudo apt update && sudo apt install -y neovim git build-essential nodejs npm pipx

# herramientas ABAP (a nivel usuario)
pipx install git+https://github.com/jfilak/sapcli.git                # cliente ADT (Python, vía pipx — PEP 668 safe)
npm install -g @abaplint/cli       # linter (Node.js)
```

```sh
# macOS
brew install neovim node python pipx
pipx install git+https://github.com/jfilak/sapcli.git
npm install -g @abaplint/cli
```

**2. Añadí el plugin a tu config de lazy.nvim.** Creá un archivo nuevo
`~/.config/nvim/lua/plugins/sap-nvim.lua` (no toques tu `init.lua`):

```lua
return {
  "JCGDeveloper/sap-nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
  },
  config = function()
    require("sap-nvim").setup()
  end,
}
```

lazy.nvim detecta cualquier archivo dentro de `lua/plugins/` automáticamente — no hace falta
registrar nada más. Reiniciá Neovim y lazy instala el plugin solo.

**3. Instalá los parsers de tree-sitter** (dentro de Neovim):

```vim
:TSInstall abap cds
```

**4. Verificá la instalación:**

```vim
:checkhealth sap-nvim
```

Reporta cada dependencia (sapcli, abaplint, node, parsers) con el comando exacto para arreglar
lo que falte. Cuando todo esté en verde, seguí con [Primeros pasos](#primeros-pasos--conectar-a-un-sistema-sap).

---

## Primeros pasos — conectar a un sistema SAP

Todo el flujo son dos comandos: **`:SapSetup`** (configurás una vez) → **`:SapDoctor`** (validás).
Las conexiones se guardan en el propio archivo de sapcli `~/.sapcli/config.yml` (estilo
kubeconfig) — ese archivo es la única fuente de verdad.

### 1. Instalar las herramientas externas

```sh
pipx install git+https://github.com/jfilak/sapcli.git                # cliente ADT (Python, vía pipx — PEP 668 safe)
npm install -g @abaplint/cli       # linter (Node.js)
```

Después, dentro de Neovim:

```vim
:checkhealth sap-nvim
```

Esto reporta cada dependencia (sapcli, abaplint, node, parsers de tree-sitter) y el estado de
tu conexión, cada uno con el comando exacto para arreglar lo que falte. Instalá los parsers de
tree-sitter con `:TSInstall abap cds`.

### 2. Configurar la conexión — `:SapSetup`

`:SapSetup` (o `<leader>asc`) abre un menú:

```
1. Nueva conexión SAP      ← crea connection + user + context
2. Ver configuración        ← muestra ~/.sapcli/config.yml
3. Activar conexión         ← cambia el current-context
4. Probar conexión          ← solo lectura: sapcli abap systeminfo
5. Eliminar conexión
6. Instalar/verificar sapcli
```

Elegí la **1** y completá los campos (`:wq` para guardar, `:cq` para cancelar):

| Campo | Significado | Ejemplo |
|-------|-------------|---------|
| `name` | Nombre del contexto | `dev` |
| `ashost` | Host del servidor de aplicaciones | `sap-dev.company.local` |
| `port` | **Puerto HTTPS del ICM** (no el sysnr) | `44300` |
| `client` | Mandante SAP | `100` |
| `user` | Tu usuario de diálogo | `JCGOMEZ` |
| `password` | Tu contraseña | — |
| `ssl` | `true` para HTTPS | `true` |

> **El `port` es el puerto HTTPS del ICM** (típicamente `44300`, `8000` o `443`) — **no** el
> número de sistema de 2 dígitos que usa SAP GUI/RFC. Si no lo sabés, miralo en tu conexión de
> SAP GUI o preguntale a Basis.

Por debajo, esto ejecuta:

```sh
sapcli config set-connection dev --ashost HOST --port 44300 --client 100 --ssl
sapcli config set-user dev-user --user JCGOMEZ --password ****
sapcli config set-context dev --connection dev --user dev-user
sapcli config use-context dev
```

> **Nota de seguridad:** la contraseña se guarda en texto plano en `~/.sapcli/config.yml`. Usá
> un usuario de desarrollo personal en un sistema que no sea productivo. Restringí el archivo
> (`chmod 600 ~/.sapcli/config.yml`).

### 3. Validar todo — `:SapDoctor`

`:SapDoctor` (o `<leader>asd`) corre una escalera **de solo lectura** y reporta PASS/FAIL:

```
Local:
  ✅ sapcli instalado
  ✅ abaplint instalado
  ✅ current-context configurado

En vivo (contactan el sistema SAP — SOLO LECTURA):
  ✅ Conectividad + login (abap systeminfo)
  ✅ Búsqueda de objetos (abap find Z)
  ✅ Transportes (cts list transport)
```

Nunca escribe, activa ni bloquea nada. Si una prueba en vivo falla, se muestra la primera línea
del error. **El primer login fallido puede bloquear tu usuario SAP tras unos intentos — si
falla, pará y revisá las credenciales antes de reintentar.**

---

## Windows: instalar bajo WSL2

¿El portátil del trabajo es Windows? Instalá Neovim y este plugin dentro de **WSL2 (Ubuntu)**,
no en Windows nativo — sapcli/abaplint/node corren como herramientas Linux y el plugin las
invoca por consola.

```sh
# dentro de WSL2 Ubuntu
sudo apt update && sudo apt install -y neovim git build-essential nodejs npm pipx
pipx install git+https://github.com/jfilak/sapcli.git
npm install -g @abaplint/cli
```

### Red en WSL — el gotcha de la conexión

`sapcli` corre **dentro de WSL**, así que el host SAP tiene que ser alcanzable **desde WSL**, no
solo desde Windows. WSL2 usa una red NAT por defecto, que puede romper el acceso corporativo:

- **La VPN corporativa en el host Windows muchas veces NO enruta el tráfico de WSL.** Si tu
  sistema SAP solo es alcanzable a través de la VPN de la empresa, probalo primero (ver abajo).
- **Los nombres DNS internos** (ej. `sap-dev.company.local`) pueden no resolverse dentro de WSL.

**Probá el alcance desde dentro de WSL antes de `:SapDoctor`:**

```sh
# reemplazá con tu host/puerto
curl -kv https://sap-dev.company.local:44300/sap/bc/adt/core/discovery 2>&1 | head
# o solo el puerto TCP:
nc -vz sap-dev.company.local 44300
```

Si eso se cuelga o falla pero el mismo host anda desde Windows, es un problema de ruteo/DNS de
WSL. Soluciones:

1. **Red en modo mirrored** (Windows 11 22H2+) — en `C:\Users\<vos>\.wslconfig`:
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```
   Después `wsl --shutdown` y reabrí. Esto hace que WSL comparta el stack de red de Windows (VPN incluida).
2. Si falla el DNS, usá la IP del servidor SAP en `ashost`, o arreglá el DNS de WSL (`/etc/resolv.conf`).
3. Si el cliente de VPN bloquea WSL por completo, hablá con IT — algunas VPN corporativas
   necesitan una configuración consciente de WSL.

Una vez que `curl`/`nc` llegan al host, `:SapSetup` → `:SapDoctor` funcionan igual que en Linux.

---

## Seguridad (máquinas compartidas)

Pensado para entornos donde varias personas comparten el sistema SAP (o la máquina). El diseño
es **conservador por defecto**: no podés romper ni perder nada del sistema con este plugin.

### Lo que el plugin NO puede hacer (auditado en el código)

| Riesgo | Estado | Por qué |
|--------|--------|---------|
| Sobrescribir código de otro | **Imposible** | No existe ningún `sapcli write`/`checkin`. Editás archivos locales; el source remoto nunca se pisa. |
| Borrar objetos | **Imposible** | No hay ningún comando `delete` en el código. |
| Liberar transportes ajenos | **No** | La lista se filtra por `--owner` (solo los tuyos) y la liberación exige confirmar explícitamente. |
| Dejar el sistema roto tras un error | **No** | Cada operación es una llamada `sapcli` atómica. Si falla, el objeto queda inactivo (igual que Eclipse) — reversible y solo tuyo. |
| Locks colgados | **Riesgo mínimo** | sapcli toma y libera el lock dentro de la misma llamada; los locks ADT expiran por sesión. |

Lo peor que puede pasar es que una activación falle y tu objeto quede inactivo. Es reversible y
no afecta el trabajo de los demás.

### Protección de credenciales

La contraseña se guarda en **texto plano** en `~/.sapcli/config.yml`. En una máquina compartida,
si otra persona lee ese archivo puede hacerse pasar por vos. El plugin lo mitiga:

- **`:SapSetup` aplica `chmod 600`** al archivo al crear la conexión (solo el dueño lo lee).
- **`:SapDoctor` chequea los permisos** y marca ❌ si el grupo u otros tienen acceso de lectura.

Si tenés un `config.yml` previo, aseguralo a mano:

```sh
chmod 600 ~/.sapcli/config.yml
```

### Tu responsabilidad (no la cubre el código)

1. **Usá tu usuario SAP personal de diálogo**, no uno compartido — así cada acción queda a tu
   nombre y el daño potencial se acota a tus permisos.
2. **Conectate solo a sistemas de DEV/sandbox**, nunca a productivo.
3. **Si comparten la misma cuenta de SO** (Windows/WSL), el `chmod 600` no alcanza: mismo usuario
   = mismo acceso. Lo ideal es que cada persona tenga su cuenta de SO o, al menos, su propio
   `~/.sapcli`.
4. **El primer login fallido puede bloquear tu usuario SAP** tras unos intentos. Si `:SapDoctor`
   falla en la conexión, pará y revisá las credenciales antes de reintentar.

---

## Funcionalidades

### Diagnósticos en tiempo real

abaplint corre en segundo plano mientras escribís (debounce de 600 ms) y en cada guardado.
Los resultados aparecen como texto virtual inline, signos en el gutter y flotantes al hacer
hover — sin configuración extra.

Los chequeos incluyen:
- Errores de sintaxis y de parser
- Variables sin usar
- Violaciones de convención de naming (totalmente configurable en `abaplint.json`)
- Código inalcanzable, excepciones no capturadas, falta de ORDER BY
- Complejidad ciclomática, largo de método, largo de línea
- Estilo: `prefer_inline`, `prefer_corresponding`, `prefer_is_not`, `use_line_exists`

Los diagnósticos son **solo del editor** — nunca bloquean la activación ni interactúan con SAP.

---

### Activación con salto al error

`<leader>aa` guarda el archivo y ejecuta `sapcli <tipo> activate` (el tipo de objeto se deriva
de la extensión del archivo). Si tiene éxito, limpia la lista de quickfix.
Si hay error, parsea la salida de SAP, carga todos los errores en el quickfix y salta directo a
la primera línea que falla.

Soporta varios formatos de error de SAP: `Line N:`, `Row N:`, `(N,col):`, `error at line N`, y más.

Después de activar, la statusline muestra `[OK]` o `[ERR]` para el buffer actual.

---

### AUnit — runner de tests

`<leader>aT` ejecuta `sapcli aunit run class <name> --output junit4`, parsea la respuesta XML
JUnit4 y carga cada test fallido en el quickfix con el número de línea exacto.

Notificación resumen: `3 test(s) failed in ZCL_FOO. See quickfix.`

---

### ATC — chequeo de calidad

`<leader>aK` corre el ABAP Test Cockpit vía `sapcli atc run <tipo> <name>` (el tipo se deriva de
la extensión del archivo).

---

### Where-used (lista de usos)

`<leader>aw` le pide a SAP todos los usos del objeto actual y los carga en el quickfix. Las
entradas se marcan `[local]` si el archivo existe localmente, `[system]` si no.

---

### Objetos inactivos

`<leader>ai` (`:SapInactive`) trae la cola de objetos inactivos del sistema, y después:

- **Elegir uno** → Abrir archivo local / Activar en el sistema / Abrir + Activar. La activación
  pregunta el tipo de objeto y ejecuta `sapcli <tipo> activate <name>`.

> sapcli no tiene un comando de "activar todo" en bloque, así que los objetos inactivos se
> activan de a uno.

---

### Diff local vs sistema

`<leader>aD` (`:SapDiff`) lee el objeto actual desde SAP vía `sapcli program/class/interface read`
y abre un vimdiff en split vertical. El buffer del sistema es de solo lectura y se limpia solo al cerrar.

---

### Nuevo objeto ABAP

`<leader>an` (`:SapNew`) te guía para crear un objeto ABAP nuevo:

1. Elegí el tipo: Program, Class, Interface, Function Group, Include, Test Class
2. Ingresá el nombre
3. Elegí el paquete desde el sistema (picker en vivo vía `sapcli package list`) — o tipealo a mano
4. Elegí la orden de transporte de tus órdenes abiertas (picker en vivo vía `sapcli cts list transport`)
   — se omite automáticamente para paquetes `$TMP`

Crea el archivo local con el template de cabecera correcto y lo abre para editar.

---

### Explorador y búsqueda de objetos

| Atajo | Comando | Descripción |
|-------|---------|-------------|
| `<leader>aS` | `:SapSearchLive` | Búsqueda global **en vivo** (Telescope, ADT). `<C-f>` filtra por tipo |
| `<leader>cc` | `:SapSearchCds` | Búsqueda **en vivo de CDS / RAP** (arranca filtrada a DDLS) |
| `<leader>afs` | `:SapSearch` | Buscar objetos en SAP por patrón de nombre |
| `<leader>afb` | `:SapBrowse` | Explorar todos los objetos de un paquete |

El picker en vivo resuelve contra ADT a cada tecla (debounce 200 ms). Dentro del picker:

- **`<C-f>`** (Ctrl+F) — filtra por **tipo de objeto** (Database Table, Program, Class, CDS
  View, Data Element…), igual que el filtro de tipo de VSCode (`&objectType=<GRUPO>`). El picker
  de CDS solo ofrece grupos CDS/RAP (DDLS/DDLX/DCL/BDEF/SRVD/SRVB).
- **`<C-d>`** (Ctrl+D) — filtra por **descripción** con comodín `*` (p. ej. `*factura*`). El
  `quickSearch` de ADT solo busca por nombre técnico, así que el servidor trae los objetos por
  nombre y el plugin refina por descripción en cliente (sin `*` = «contiene»; `*` = comodín).
  Útil para combinar: nombre `JCG*` + descripción `*factura*`. Vacío quita el filtro.

Al elegir un objeto de cualquiera de los pickers, intenta abrirlo localmente; si no lo
encuentra, ofrece hacer checkout.

---

### Checkout de paquete

`<leader>ack` (`:SapCheckout`) descarga un paquete SAP completo al sistema de archivos local vía
`sapcli checkout package`. Pregunta el nombre del paquete, el directorio destino y el flag
recursivo. Abre oil.nvim (si está disponible) o el directorio al terminar.

---

### Gestión de transportes

| Atajo | Comando | Descripción |
|-------|---------|-------------|
| `<leader>atl` | `:SapTransports` | Listar órdenes de transporte abiertas — Enter copia el ID al portapapeles |
| `<leader>atc` | `:SapTransportCreate` | Crear una nueva orden de transporte |
| `<leader>atr` | `:SapTransportRelease` | Liberar una orden de transporte (con confirmación) |

---

### Formateador

`<leader>aF` formatea el archivo actual. Despacha automáticamente según la extensión:

**ABAP (`.abap`, `.cls`, `.intf`, `.prog`):**
- Pone en mayúsculas todas las palabras clave (`IF`, `DATA`, `SELECT`, …)
- Corrige la indentación de bloques (`IF/ENDIF`, `METHOD/ENDMETHOD`, `CASE/WHEN/ENDCASE`, …)
- Autocompleta palabras clave por prefijo único (`sel` → `SELECT`)
- Corrige typos por distancia de Levenshtein (`SELCT` → `SELECT`)
- Los literales de string y los comentarios inline nunca se modifican

**CDS/DDL (`.ddls`, `.dcl`, `.bdef`, `.cds`):**
- Indentación basada en llaves (`{` / `}`)
- Las anotaciones (`@AbapCatalog.…`) se preservan tal cual
- Los comentarios (`//`, `/* */`) se indentan pero no se modifican

`:SapFormat` (= `<leader>aF`) usa el Pretty Printer de SAP/ADT en objetos remotos; sin
conexión cae al formateador nativo (`:SapFormatNative`).

---

### Plantillas de código (estilo Eclipse/ADT)

Store de plantillas en disco (`~/.config/sap-nvim/templates/`) con picker, guardado desde la
UI y **variables dinámicas** (`$OBJECT`, `$PACKAGE`, `$SHORTTEXT`, `$METHOD`, `$AUTHOR`,
`$DATE`, …) con paridad Eclipse. Al guardar puedes parametrizar identificadores (grupo de
funciones, tabla…) como tab-stops espejados para reutilizar un include entero.

Grupo de teclado **`<leader>aP`**: `i` insertar · `s` guardar · `d` carpeta · `e` editar.

Guía completa: [`docs/PLANTILLAS.md`](docs/PLANTILLAS.md).

---

### Autocompletado contextual (ABAP)

El completado local es **consciente del contexto**: en una firma de método propone
`IMPORTING`/`EXPORTING`/`RETURNING VALUE()`/`CHANGING`; en la sección de una clase,
`METHODS`/`CLASS-METHODS`/`DATA`/… — priorizados sobre el resto de palabras clave.

---

### Integración con la statusline

El plugin expone un componente de lualine que muestra la conexión SAP activa y el último
resultado de activación del buffer actual.

```lua
-- config de lualine
require("lualine").setup({
  sections = {
    lualine_x = {
      require("sap-nvim.core.statusline").component,
      "filetype",
    },
  },
})
```

Muestra: ` DEV · 100 · JCGOMEZ [OK]`
Color: naranja (`#e8a87c`, bold). Solo visible en buffers ABAP.

Sin lualine, el plugin setea `vim.opt_local.statusline` en los buffers ABAP automáticamente.

`:SapStatus` / `<leader>asi` imprime los detalles completos de la conexión.

---

### Integración con SAP GUI

| Atajo | Descripción |
|-------|-------------|
| `<leader>asg` | Abrir SAP GUI |
| `<leader>aso` | Abrir SAP GUI y mostrar la transacción correspondiente al archivo actual |

---

### Configuración de conexión

`:SapSetup` / `<leader>asc` — asistente interactivo. Escribe en el `~/.sapcli/config.yml` estilo
kubeconfig de sapcli vía `sapcli config` (única fuente de verdad). Ver
[Primeros pasos](#primeros-pasos--conectar-a-un-sistema-sap).

`:SapDoctor` / `<leader>asd` — escalera de validación de solo lectura (conectividad, búsqueda de
objetos, transportes).

`:SapStatus` / `<leader>asi` — muestra la conexión activa: sistema, mandante, usuario.

---

## Asistencia con IA (GitHub Copilot)

IA con conocimiento de ABAP, **apagada por defecto**. Usa **GitHub Copilot** — el mismo backend
y la misma licencia que la extensión de Copilot en VSCode (incluyendo modelos Claude si tu
organización los habilita).

> **Por qué Copilot y no una API externa:** Copilot mantiene tu código fuente dentro del canal
> que tu empresa ya aprobó. Una integración directa con la API de Anthropic/OpenAI (como el
> `avante.lua` que viene incluido) enviaría código ABAP a un endpoint externo — normalmente una
> violación de la política de datos en entornos SAP corporativos. Usá Copilot salvo que IT
> apruebe explícitamente otra cosa.

### Cómo activarlo

```lua
{
  "JCGDeveloper/sap-nvim",
  dependencies = {
    "zbirenbaum/copilot.lua",
    "CopilotC-Nvim/CopilotChat.nvim",
  },
  config = function()
    require("sap-nvim").setup({
      ai = "copilot",
      -- opcional: fijar un modelo Claude que tu organización habilitó en Copilot
      -- copilot_model = "claude-sonnet-4",
    })
  end,
}
```

Después autenticá una sola vez: `:Copilot auth` (usa tu login de GitHub de la empresa).

### Flujo de trabajo

1. **Instalá las dos dependencias** (`copilot.lua` + `CopilotChat.nvim`) y poné `ai = "copilot"`.
2. **`:Copilot auth`** — autenticación única con tu cuenta de GitHub corporativa.
3. **Sugerencias inline**: aparecen mientras escribís en archivos ABAP/CDS; aceptás con `<Tab>`.
4. **Chat / agente**: seleccioná código en modo visual y usá los atajos de abajo. El chat ya
   viene cargado con un *system prompt* de ABAP/CDS/Clean ABAP, así que las respuestas salen en
   contexto SAP sin que tengas que explicárselo cada vez.

### Atajos

| Atajo | Acción |
|-------|--------|
| `<leader>agc` | Abrir/cerrar el chat de Copilot |
| `<leader>age` | Explicar el ABAP seleccionado |
| `<leader>agr` | Revisar el ABAP seleccionado (rendimiento, naming, tests) |
| `<leader>agt` | Generar tests AUnit |
| `<leader>agf` | Corregir el ABAP seleccionado |

> Hasta que pongas `ai = "copilot"` e instales los dos plugins, esta integración es un
> **no-op total**: no carga nada ni define atajos.

---

## Atajos — referencia completa

| Atajo | Comando | Descripción |
|-------|---------|-------------|
| `<leader>aa` | — | Activar objeto → errores en quickfix, salta a la línea |
| `<leader>aT` | `:SapAUnit` | Correr tests AUnit → fallos en quickfix |
| `<leader>aK` | — | Correr chequeo de calidad ATC |
| `<leader>aF` | — | Formatear archivo (ABAP mayúsculas+indent / CDS llaves) |
| `<leader>aw` | `:SapWhereUsed` | Lista de usos → quickfix |
| `<leader>aD` | `:SapDiff` | Diff del buffer local vs la versión activa del sistema |
| `<leader>ai` | `:SapInactive` | Objetos inactivos — abrir o activar de a uno |
| `<leader>an` | `:SapNew` | Nuevo objeto ABAP con pickers de paquete/transporte del sistema |
| `<leader>aS` | `:SapSearchLive` | Búsqueda global en vivo (Telescope); `<C-f>` filtra por tipo |
| `<leader>cc` | `:SapSearchCds` | Búsqueda en vivo de CDS / RAP |
| `<leader>afs` | `:SapSearch` | Buscar objetos en SAP |
| `<leader>afb` | `:SapBrowse` | Explorar contenido de un paquete |
| `<leader>ack` | `:SapCheckout` | Checkout de un paquete completo al sistema de archivos local |
| `<leader>atl` | `:SapTransports` | Listar órdenes de transporte abiertas |
| `<leader>atc` | `:SapTransportCreate` | Crear orden de transporte |
| `<leader>atr` | `:SapTransportRelease` | Liberar orden de transporte |
| `<leader>asi` | `:SapStatus` | Mostrar info de la conexión SAP activa |
| `<leader>asc` | `:SapSetup` | Asistente de configuración de conexión (kubeconfig de sapcli) |
| `<leader>asd` | `:SapDoctor` | Validación de solo lectura: conexión, objetos, transportes |
| `<leader>asg` | — | Abrir SAP GUI |
| `<leader>aso` | — | Abrir el objeto actual en SAP GUI |
| `<leader>ah` | — | Ayuda (todos los atajos) |

---

## Convenciones de naming (abaplint.json)

El `abaplint.json` en la raíz del proyecto configura los chequeos de naming en tiempo real.
Editá cualquier patrón y el cambio toma efecto en la siguiente tecla — sin reiniciar.

### Variables dentro de métodos y forms (ámbito local)

| Tipo | Prefijo |
|------|---------|
| Variable | `WL_` |
| Tabla interna | `TL_` |
| Estructura / Work area | `XL_` / `WAL_` |
| Constante | `CL_` |
| Tipo | `TYL_` |
| Tipo (tabla) | `TTL_` |
| Static | `STL_` |
| Range | `RL_` |
| Field symbol | `<FS_xxx>` |
| Parámetro importing | `PI_` |
| Parámetro exporting | `PO_` |
| Parámetro changing | `PC_` |
| Parámetro tables | `PT_` |

### Atributos de clase (ámbito global)

| Tipo | Prefijo |
|------|---------|
| Variable de instancia / estática | `WG_` |
| Tabla interna | `T_` |
| Estructura / Work area | `X_` / `WA_` |
| Static | `ST_` |
| Tipo | `TY_` / `TT_` |
| Constante | `C_` |

### Naming de objetos

| Objeto | Patrón | Ejemplo |
|--------|--------|---------|
| Programa / Report | `Z` | `ZFIR_IVA_MENSUAL` |
| Clase (normal) | `ZCLA###_` | `ZCLAMM_PEDIDO` |
| Clase (abstracta) | `ZCLN###_` | `ZCLN_BASE` |
| Interfaz | `ZIF###_` | `ZIFMM_MINILOAD` |
| Grupo de funciones | `ZFG##_` | `ZFGFI_IVA` |
| Tabla DDIC | `ZT###_` | `ZTFI_CODIGOS` |
| Estructura DDIC | `ZS###_` | `ZSFI_CODIGOS` |
| Elemento de datos | `ZE###_` | `ZELEM_DAT` |
| Dominio | `ZD##_` | `ZD_STATUS` |
| Vista | `ZV###_` | `ZVFI_CODIGOS` |

---

## Arquitectura

```
sap-nvim/
├── lua/sap-nvim/
│   ├── init.lua              Punto de entrada — carga todos los módulos
│   ├── core/
│   │   ├── adt.lua           Wrapper de sapcli: activar, traer paquetes/transportes/objetos
│   │   ├── aunit.lua         Runner de AUnit + parser de XML JUnit4 → quickfix
│   │   ├── browser.lua       Búsqueda de objetos y explorador de paquetes
│   │   ├── checkout.lua      Checkout de paquete al sistema de archivos local
│   │   ├── debugger.lua      Debugger ABAP interactivo (requiere conexión)
│   │   ├── diff.lua          vimdiff local vs sistema
│   │   ├── doctor.lua        :SapDoctor escalera de validación de solo lectura
│   │   ├── formatter.lua     Formateador nativo de ABAP + CDS
│   │   ├── inactive.lua      Picker de objetos inactivos + activación
│   │   ├── keymaps.lua       Todas las definiciones de atajos
│   │   ├── lsp.lua           Diagnósticos abaplint en tiempo real vía vim.diagnostic
│   │   ├── new.lua           Asistente de objeto nuevo con pickers del sistema
│   │   ├── objtype.lua       Extensión de archivo → grupo de objeto sapcli (fuente única)
│   │   ├── setup.lua         :SapSetup — asistente de conexión kubeconfig de sapcli
│   │   ├── statusline.lua    Componente de lualine + statusline nativa
│   │   ├── transport.lua     Gestión de órdenes de transporte
│   │   └── whereused.lua     Lista de usos → quickfix
│   └── integrations/
│       ├── completion.lua    Snippets ABAP y autocompletado de palabras clave
│       ├── copilot.lua       IA ABAP vía GitHub Copilot — opt-in, gateada por setup({ ai = "copilot" })
│       ├── avante.lua        Asistente IA (Avante) — opt-in, no se carga por defecto
│       └── mcphub.lua        Servidores MCP para SAP ADT — opt-in, no se carga por defecto
└── abaplint.json             Config de linting y convenciones de naming
```

---

## Licencia

MIT
