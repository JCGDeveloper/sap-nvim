# nvim-sap — Manual de usuario

IDE de SAP/ABAP dentro de Neovim, con paridad de VSCode (`abap-remote-fs`) / Eclipse ADT:
completado inteligente, hover, navegación, CDS/RAP, depurador, transportes, ejecución y una
capa opcional de **agentes de IA** que programan en SAP. Funciona en Linux, macOS y **WSL2**.

> Este manual unifica todo. Para detalles concretos: [INSTALACION.md](INSTALACION.md),
> [CONFIGURACION.md](CONFIGURACION.md), [ARQUITECTURA.md](ARQUITECTURA.md),
> [MCP-SETUP.md](MCP-SETUP.md) (capa IA), [KNOWN-ISSUES.md](KNOWN-ISSUES.md).

---

## 1. Instalación (resumen)

Requisitos: **Neovim ≥ 0.10**, **Node.js**, **Python 3**, y las herramientas ABAP
**`sapcli`** (escrituras/lock) + **`abaplint`** (lint local). Detalle en [INSTALACION.md](INSTALACION.md).

```sh
# 1) Clona el plugin (tu copia de trabajo)
git clone https://github.com/JCGDeveloper/sap-nvim ~/sap-nvim

# 2) Herramientas ABAP (a nivel usuario)
pipx install sap-cli            # o pip install --user sap-cli
npm install -g @abaplint/cli

# 3) IDE aislado nvim-sap (no toca tu Neovim personal)
cp -r ~/sap-nvim/extras/nvim-sap/{init.lua,lua} ~/.config/nvim-sap/
echo "alias nvim-sap='NVIM_APPNAME=nvim-sap nvim'" >> ~/.zshrc && source ~/.zshrc
nvim-sap                        # primer arranque: instala plugins (lazy) y reinicia
```

`nvim-sap` es un Neovim **independiente** (sesión, plugins y colores propios) montado como IDE
SAP. Tu Neovim normal no se ve afectado. El plugin se carga desde `~/sap-nvim` con `sap_mode=true`.

---

## 2. Conectar a un sistema SAP

La conexión vive en `~/.sapcli/config.yml` (formato tipo kubeconfig: conexiones + usuarios +
contextos). **La contraseña no se guarda en disco** salvo que tú la pongas; el plugin la mantiene
en memoria por sesión.

- **`:SapSetup`** — asistente para crear/editar conexiones (host, puerto HTTPS del ICM —p.ej.
  44300—, cliente, usuario, SSL).
- **`:SapDoctor`** — diagnóstico solo-lectura: comprueba sapcli, abaplint, red, login.
- **`:SapStatus`** — info de la conexión activa. **`:SapLogin` / `:SapRelogin`** — (re)autenticar.
- **`<leader>L`** en el dashboard / **`:SapSetup`** — cambiar de máquina.

---

## 3. Dashboard y navegación

Al arrancar sin argumentos se abre el **dashboard** (pantalla de inicio). Teclas:
`n` nuevo objeto · `o` abrir/buscar · `C` abrir CDS/RAP · `x` ejecutar transacción (WebGUI) ·
`g` SAP GUI nativo · `R` ejecutar programa · `t`/`c` transportes · `b`/`r` buffers/recientes ·
`S` configurar conexión (`:SapSetup`) · `L` cambiar de conexión · `q` salir.

- **`<leader>aS`** (`:SapSearchLive`) / dashboard `o` — **búsqueda global en vivo**: picker
  Telescope que resuelve contra ADT a cada tecla. Dos filtros dentro del picker:
  - **`<C-f>`** (Ctrl+F) — por **tipo** de objeto (Database Table, Program, Class, CDS, Data
    Element…), igual que el filtro de VSCode (`&objectType`).
  - **`<C-d>`** (Ctrl+D) — por **descripción**, con comodín `*` (p. ej. `*factura*`; sin `*` =
    «contiene»). El servidor solo busca por nombre técnico, así que el plugin refina la
    descripción en cliente. Combina bien con el nombre: `JCG*` + descripción `*factura*`.

  Para CDS, `<leader>cc` / dashboard `C` (ver §5).

- **`␣␣`** (espacio-espacio) — saltar entre objetos SAP abiertos (estilo VSCode).
- **`-`** (guion) — *volver*: recorre hacia atrás la navegación (gd/búsqueda/include) y, al
  agotarse, cae al **dashboard**. Dentro de un include creado, vuelve al programa de origen.
- La sesión recuerda **solo objetos SAP** (se restauran al reabrir).

---

## 4. Editar ABAP — inteligencia ADT (como Eclipse/VSCode)

- **Completado automático** mientras escribes (blink): clases/métodos del sistema, parámetros al
  abrir `(`, **campos de estructura** tras `wa-`, **tipos/tablas DDIC** tras `TYPE `/`LIKE `,
  **`@` anotaciones** y **campos CDS** tras `alias.`. Manual: **`<C-Space>`** o **`:SapComplete`**.
- **`K`** — hover: firma + documentación (2ª `K` entra al popup, `hjkl` hace scroll). `:SapHover`.
- **`gd`** — ir a definición (incluye clases/métodos del sistema). **`gy`** tipo del dato ·
  **`gr`** referencias (`<leader>aw` where-used → quickfix).
- **`<leader>ao`** — outline del objeto (saltar a método/form/type/include).
- **Syntax check en vivo** de SAP (diagnósticos al escribir/guardar) · **`:SapCheck`**.
- **`<leader>aF`** — formatear con el Pretty Printer de SAP (objetos remotos) / por llaves (CDS).
- **`:SapCompleteDebug`** — diagnóstico del completado (qué pide y qué responde el servidor).

### Subir y activar
- **`<leader>au`** (`:SapPush`) — subir sin activar · **`<leader>aa`** (`:SapActivate`) — activar
  (sube antes si es remoto; errores/warnings → quickfix con salto a línea).
- **`<leader>aX`** (`:SapDelete`) — borrar el objeto (confirmación; §seguridad).
- **`<leader>aD`** (`:SapDiff`) — diff local vs sistema.

### Plantillas (`<leader>aP…`)
`<leader>aPi` insertar (picker con preview) · `aPs` guardar como plantilla · `aPe` editar carpeta.

---

## 5. CDS / RAP

- **Completado**: campos tras `alias.`, fuentes tras `from`/`join`, anotaciones tras `@`, y
  valores (enums) tras `:` (vía `ddicrepositoryaccess`, como VSCode).
- **`<leader>cp`** (`:SapCdsPreview`) — datos de la vista · **`<leader>cs`** SQL nativo ·
  **`<leader>co`** generar OData · **`<leader>cg`** grafo RAP.
- **`<leader>cc`** (`:SapSearchCds`) — **buscar/abrir CDS en vivo**: picker Telescope que
  resuelve contra ADT a cada tecla, ya filtrado a DDLS. Dentro, **`<C-f>`** (Ctrl+F) cambia el
  grupo CDS/RAP (DDLS/DDLX/DCL/BDEF/SRVD/SRVB). Para abrir por nombre exacto sigue estando
  `:SapCdsOpen [ddls|ddlx|bdef|dcl|srvd] <NOMBRE>`.
- **`<leader>ct`/`cl`/`cL`/`cx`** — órdenes de transporte desde CDS.

---

## 6. Crear objetos en SAP

- **`<leader>an`** (`:SapNew`) — crea programa, clase, interface, include, FM, **transacción**,
  message class, paquete… **en el sistema** y lo abre. El campo **paquete autocompleta en vivo**
  (picker que busca en el sistema según escribes, estilo VSCode).
- **`<leader>aci`** — crear el include bajo el cursor (Ctrl+1 de Eclipse) y abrirlo.
- **Transacciones**: si tu sistema no expone el endpoint ADT de creación (IAM), el plugin ofrece
  crearla en **SE93** vía SAP GUI (la vía soportada). Ver §8.

---

## 7. Ejecutar transacciones y programas — **3 visores**

Al ejecutar una transacción (`<leader>ax`, dashboard `x`) o un programa (`<leader>aR`, dashboard
`R`), el plugin **pregunta dónde abrirlo**:

1. **Navegador (Windows)** — abre la WebGUI en tu navegador real.
2. **Terminal (dentro de Neovim)** — abre la WebGUI con **carbonyl** (Chromium en terminal) en un
   split, sin salir de nvim. Requiere `carbonyl` (`npm i -g carbonyl` + libs de Chromium).

> Salta la pregunta con `vim.g.sap_gui_viewer = "browser" | "terminal"`.

### SAP GUI nativo (escritorio)
- **`<leader>asG`** (`:SapGuiObject`) — abre **el objeto actual** en el SAP GUI de escritorio
  (Workbench). Dashboard **`g`** o **`:SapGuiTransaction <tcode>`** / **`:SapGuiLogon`**.
- En **WSL2** genera un shortcut `.sap` y lo lanza con Windows; lee tu **SAP Logon**
  (`SAPUILandscape.xml`) para resolver router + host/sysnr automáticamente. Login sin contraseña
  vía reentrance ticket si el sistema lo permite (si no, el GUI la pide).

---

## 8. Transportes (CTS)

- **`<leader>atl`** (`:SapTransports`) listar mías · **`<leader>atc`** (`:SapTransportCreate`)
  crear (no exige estar dentro de un objeto: usa el paquete) · **`<leader>atr`** liberar.
- `:SapTransportContents` · `:SapTransportRelease` · `:SapTransportReassign`.

---

## 9. Datos, tablas y OpenSQL

- **`<leader>avt`** (`:SapTable`) — definición DDIC de una tabla.
- **`<leader>avd`** (`:SapTableData`) — datos de la tabla bajo el cursor (SE16, split; `q`/`-` cierra).
- **`<leader>avq`** (`:SapData`) — ejecutar **OpenSQL** y ver resultados.
- ALV preview: `:SapAlvPreview` · `:SapAlvPreviewMine`.

---

## 10. Tests y calidad

- **`<leader>aT`** (`:SapAUnit`) — pruebas unitarias (AUnit) del objeto.
- **`<leader>aK`** (`:SapATC` / `:SapCheck`) — chequeo de calidad ATC / Clean ABAP.
- **`<leader>ai`** (`:SapInactive`) — objetos inactivos.

---

## 11. Depurador

- **`<leader>ad`** — iniciar sesión de depuración ABAP (vsp). Stepping estándar con `nvim-dap`:
  `<leader>db/dB/dc/di/do/dO/dr/dt/du/de` y `F5/F10/F11/F12`. Breakpoints visibles en el margen (`●`).
- `:SapDap` · `:SapDebugKillAll` · `<leader>dX` cerrar todas las sesiones.

---

## 12. Diagnóstico

`:SapDoctor` (chequeo general) · `:SapStatus` (conexión) · `:SapDiscovery [filtro]` (endpoints ADT
que SÍ existen en tu sistema) · `:SapDaemonTest` (conexión persistente) · `:SapCompleteDebug`
(por qué no completa) · `<leader>ah` (ayuda de atajos dentro del editor).

---

## 13. Capa de IA — agentes que programan en SAP (opcional)

Un servidor **MCP de ADT** expone SAP como herramientas (CRUD, activar, ejecutar, testear,
depurar) para que **agentes de IA** programen en tu sistema. Setup completo en
**[MCP-SETUP.md](MCP-SETUP.md)**. En resumen:

- **Servidor MCP** (`@mcp-abap-adt/core`) conectado a tu sistema (auth en un `.env` modo 600,
  fuera del repo) y registrado en Claude Code.
- **Agentes** `abap-orchestrator / implementer / tester / reviewer / debugger` (`~/.claude/agents/`).
  El **debugger** lee dumps (ST22), reproduce, perfila (SAT) y diagnostica la causa raíz.
- **Convenciones/restricciones** del proyecto en `~/.claude/sap/conventions.md` (nomenclatura,
  prohibiciones, sintaxis) — los agentes lo leen y lo obedecen.
- **Chat en nvim**: `coder/claudecode.nvim` (**`<leader>ii`** abre el panel) — habla en lenguaje
  natural; usa tu suscripción de Claude (sin API key) con el MCP + agentes.
- **Seguridad**: un hook deja **solo lectura en objetos estándar** (no-Z); escritura solo `Z*/Y*`.
- Panel de inspección del MCP en nvim: **`<leader>aM`** (`:MCPHub`, requiere `mcphub.nvim`).

---

## 14. Seguridad

- ADT directo = **solo lectura** (completado/hover/navegación/checks/format). Las **escrituras**
  van por `sapcli` (con lock/unlock gestionado).
- Confirmación en operaciones **destructivas**; nada masivo; transporte gestionado.
- **Credenciales**: nunca en el repo. La conexión vive en `~/.sapcli/config.yml`; la contraseña en
  memoria (o `.env` modo 600 para el MCP, fuera del repo). Las URLs a curl no exponen `-u user:pass`.
- Agentes IA: limitados a `Z*/Y*` por hook + autorizaciones de SAP. Trabaja en cliente sandbox.

---

## 15. Cheat-sheet rápido

| Acción | Atajo / comando |
|---|---|
| Ayuda de atajos | `<leader>ah` |
| Completar (manual) | `<C-Space>` · `:SapComplete` |
| Hover / Ir a definición / Referencias | `K` · `gd` · `gr` |
| Outline / Where-used | `<leader>ao` · `<leader>aw` |
| Buscar objeto / CDS en vivo (`<C-f>` tipo · `<C-d>` descripción) | `<leader>aS` · `<leader>cc` |
| Formatear / Activar / Subir | `<leader>aF` · `<leader>aa` · `<leader>au` |
| Nuevo objeto / Crear include | `<leader>an` · `<leader>aci` |
| Ejecutar transacción / programa | `<leader>ax` · `<leader>aR` (pregunta navegador/terminal) |
| Abrir objeto en SAP GUI nativo | `<leader>asG` |
| CDS: preview / SQL / OData / grafo | `<leader>cp` · `cs` · `co` · `cg` |
| Tabla DDIC / datos / OpenSQL | `<leader>avt` · `avd` · `avq` |
| AUnit / ATC / inactivos | `<leader>aT` · `<leader>aK` · `<leader>ai` |
| Transportes (listar/crear/liberar) | `<leader>atl` · `atc` · `atr` |
| Depurar | `<leader>ad` + `F5/F10/F11/F12` |
| Volver / saltar entre objetos | `-` · `␣␣` |
| Chat IA / panel MCP | `<leader>ii` · `<leader>aM` |
| Diagnóstico | `:SapDoctor` · `:SapStatus` · `:SapDiscovery` |
