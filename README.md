# sap-nvim

A Neovim plugin for SAP ABAP development. Integrates with `sapcli` and `abaplint` to bring
Eclipse/VSCode-level tooling into Neovim: real-time diagnostics, quickfix-driven activation,
test runner, transport management, object browser, CDS support, and more.

---

## Requirements

| Tool | Purpose | Install |
|------|---------|---------|
| [sapcli](https://github.com/jfilak/sapcli) | ADT operations (activate, checkout, AUnit, transports…) | `pip install sapcli` |
| [abaplint](https://github.com/abaplint/abaplint) | Real-time linting and naming checks | `npm install -g @abaplint/cli` |
| Neovim ≥ 0.9 | Plugin host | — |
| `vim.ui.select` provider | Pickers (Telescope, fzf-lua, or built-in) | optional |

---

## Installation

```lua
-- lazy.nvim
{
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

---

## Getting started — connect to a SAP system

The whole flow is two commands: **`:SapSetup`** (configure once) → **`:SapDoctor`** (validate).
Connections are stored in sapcli's own file `~/.sapcli/config.yml` (kubeconfig-style) — that
file is the single source of truth.

### 1. Install the external tools

```sh
pip install sapcli                 # ADT client (Python)
npm install -g @abaplint/cli       # linter (Node.js)
```

Then, inside Neovim:

```vim
:checkhealth sap-nvim
```

This reports every dependency (sapcli, abaplint, node, tree-sitter parsers) and your
connection status, each with the exact command to fix what's missing. Install the
tree-sitter parsers with `:TSInstall abap cds`.

### 2. Configure the connection — `:SapSetup`

`:SapSetup` (or `<leader>asc`) opens a menu:

```
1. Nueva conexión SAP      ← create connection + user + context
2. Ver configuración        ← dump ~/.sapcli/config.yml
3. Activar conexión         ← switch current-context
4. Probar conexión          ← read-only: sapcli abap systeminfo
5. Eliminar conexión
6. Instalar/verificar sapcli
```

Choose **1** and fill the fields (`:wq` to save, `:cq` to cancel):

| Field | Meaning | Example |
|-------|---------|---------|
| `name` | Context name | `dev` |
| `ashost` | Application server host | `sap-dev.company.local` |
| `port` | **HTTPS port of the ICM** (not the sysnr) | `44300` |
| `client` | SAP client / mandante | `100` |
| `user` | Your dialog user | `JCGOMEZ` |
| `password` | Your password | — |
| `ssl` | `true` for HTTPS | `true` |

> **`port` is the HTTPS ICM port** (typically `44300`, `8000`, or `443`) — **not** the
> 2-digit system number used by SAP GUI/RFC. If you don't know it, check your SAP GUI
> connection or ask Basis.

Under the hood this runs:

```sh
sapcli config set-connection dev --ashost HOST --port 44300 --client 100 --ssl
sapcli config set-user dev-user --user JCGOMEZ --password ****
sapcli config set-context dev --connection dev --user dev-user
sapcli config use-context dev
```

> **Security note:** the password is stored in plaintext in `~/.sapcli/config.yml`. Use a
> personal dev user on a non-production system. Lock the file down (`chmod 600 ~/.sapcli/config.yml`).

### 3. Validate everything — `:SapDoctor`

`:SapDoctor` (or `<leader>asd`) runs a **read-only** ladder and reports PASS/FAIL:

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

It never writes, activates, or locks anything. If a live check fails, the first error line
is shown inline. **The first failed login can lock your SAP user after a few attempts — if it
fails, stop and check credentials before retrying.**

---

## Windows: install under WSL2

The work laptop is Windows? Install Neovim and this plugin inside **WSL2 (Ubuntu)**, not
native Windows — sapcli/abaplint/node all run as Linux tools and the plugin shells out to them.

```sh
# inside WSL2 Ubuntu
sudo apt update && sudo apt install -y neovim python3-pip nodejs npm
pip install sapcli
npm install -g @abaplint/cli
```

### WSL networking — the connection gotcha

`sapcli` runs **inside WSL**, so the SAP host must be reachable **from WSL**, not just from
Windows. WSL2 uses a NAT network by default, which can break corporate access:

- **Corporate VPN on the Windows host often does NOT route WSL traffic.** If your SAP system
  is only reachable through the company VPN, test it first (see below).
- **Internal DNS names** (e.g. `sap-dev.company.local`) may not resolve inside WSL.

**Test reachability from inside WSL before `:SapDoctor`:**

```sh
# replace with your host/port
curl -kv https://sap-dev.company.local:44300/sap/bc/adt/core/discovery 2>&1 | head
# or just the TCP port:
nc -vz sap-dev.company.local 44300
```

If that hangs or fails but the same host works from Windows, it's a WSL routing/DNS issue. Fixes:

1. **Mirrored networking** (Windows 11 22H2+) — in `C:\Users\<you>\.wslconfig`:
   ```ini
   [wsl2]
   networkingMode=mirrored
   ```
   Then `wsl --shutdown` and reopen. This makes WSL share the Windows network stack (VPN included).
2. If DNS fails, use the SAP server's IP in `ashost`, or fix WSL DNS (`/etc/resolv.conf`).
3. If the VPN client blocks WSL entirely, ask IT — some corporate VPNs need a WSL-aware config.

Once `curl`/`nc` reaches the host, `:SapSetup` → `:SapDoctor` will work the same as on Linux.

---

## Features

### Real-time diagnostics

abaplint runs in the background while you type (600 ms debounce) and on every save.
Results appear as inline virtual text, gutter signs, and hover floats — no extra config needed.

Checks include:
- Syntax and parser errors
- Unused variables
- Naming convention violations (fully configurable in `abaplint.json`)
- Unreachable code, uncaught exceptions, missing ORDER BY
- Cyclomatic complexity, method length, line length
- Style: `prefer_inline`, `prefer_corresponding`, `prefer_is_not`, `use_line_exists`

Diagnostics are **editor-only** — they never block activation or interact with SAP.

---

### Activation with jump-to-error

`<leader>aa` saves the file and runs `sapcli <type> activate` (the object type is derived from
the file extension). On success it clears the quickfix list.
On error it parses the SAP output, loads all errors into the quickfix list, and jumps directly
to the first failing line.

Supports multiple SAP error formats: `Line N:`, `Row N:`, `(N,col):`, `error at line N`, and more.

After activation, the statusline shows `[OK]` or `[ERR]` for the current buffer.

---

### AUnit — test runner

`<leader>aT` runs `sapcli aunit run class <name> --output junit4`, parses the JUnit4 XML
response, and loads every failing test into the quickfix list with the exact line number.

Summary notification: `3 test(s) failed in ZCL_FOO. See quickfix.`

---

### ATC — quality check

`<leader>aK` runs ABAP Test Cockpit via `sapcli atc run <type> <name>` (type derived from the
file extension).

---

### Where-used list

`<leader>aw` asks SAP for all usages of the current object and loads them into the quickfix
list. Entries marked `[local]` if the file exists locally, `[system]` otherwise.

---

### Inactive objects

`<leader>ai` (`:SapInactive`) fetches the inactive objects queue from the system, then:

- **Select one** → Open local file / Activate in system / Open + Activate. Activation prompts
  for the object type and runs `sapcli <type> activate <name>`.

> sapcli has no bulk "activate all" command, so inactive objects are activated one at a time.

---

### Diff local vs system

`<leader>aD` (`:SapDiff`) reads the current object from SAP via `sapcli program/class/interface read`
and opens a vertical split vimdiff. The system buffer is read-only and auto-cleaned up on close.

---

### New ABAP object

`<leader>an` (`:SapNew`) guides you through creating a new ABAP object:

1. Choose type: Program, Class, Interface, Function Group, Include, Test Class
2. Enter name
3. Pick package from the system (live picker via `sapcli package list`) — or type manually
4. Pick transport order from your open orders (live picker via `sapcli cts list transport`)
   — skipped automatically for `$TMP` packages

Creates the local file with the correct header template and opens it for editing.

---

### Object browser and search

| Keymap | Command | Description |
|--------|---------|-------------|
| `<leader>afs` | `:SapSearch` | Search objects in SAP by name pattern |
| `<leader>afb` | `:SapBrowse` | Browse all objects in a package |

Selecting an object from either picker tries to open it locally; if not found, offers to check it out.

---

### Package checkout

`<leader>ack` (`:SapCheckout`) downloads a full SAP package to the local filesystem via
`sapcli checkout package`. Prompts for package name, target directory, and recursive flag.
Opens oil.nvim (if available) or the directory when done.

---

### Transport management

| Keymap | Command | Description |
|--------|---------|-------------|
| `<leader>atl` | `:SapTransports` | List open transport orders — Enter copies ID to clipboard |
| `<leader>atc` | `:SapTransportCreate` | Create a new transport order |
| `<leader>atr` | `:SapTransportRelease` | Release a transport order (with confirmation) |

---

### Formatter

`<leader>aF` formats the current file. Dispatches automatically by extension:

**ABAP (`.abap`, `.cls`, `.intf`, `.prog`):**
- Uppercase all keywords (`IF`, `DATA`, `SELECT`, …)
- Correct block indentation (`IF/ENDIF`, `METHOD/ENDMETHOD`, `CASE/WHEN/ENDCASE`, …)
- Autocomplete keywords by unique prefix (`sel` → `SELECT`)
- Fuzzy-correct typos via Levenshtein distance (`SELCT` → `SELECT`)
- String literals and inline comments are never modified

**CDS/DDL (`.ddls`, `.dcl`, `.bdef`, `.cds`):**
- Brace-based indentation (`{` / `}`)
- Annotations (`@AbapCatalog.…`) preserved as-is
- Comments (`//`, `/* */`) indented but not modified

---

### Statusline integration

The plugin exposes a lualine component that shows the active SAP connection and the last
activation result for the current buffer.

```lua
-- lualine config
require("lualine").setup({
  sections = {
    lualine_x = {
      require("sap-nvim.core.statusline").component,
      "filetype",
    },
  },
})
```

Display: ` DEV · 100 · JCGOMEZ [OK]`
Color: orange (`#e8a87c`, bold). Only visible on ABAP buffers.

Without lualine, the plugin sets `vim.opt_local.statusline` on ABAP buffers automatically.

`:SapStatus` / `<leader>asi` prints the full connection details.

---

### SAP GUI integration

| Keymap | Description |
|--------|-------------|
| `<leader>asg` | Open SAP GUI |
| `<leader>aso` | Open SAP GUI and show the relevant transaction for the current file |

---

### Connection setup

`:SapSetup` / `<leader>asc` — interactive assistant. Writes to sapcli's kubeconfig-style
`~/.sapcli/config.yml` via `sapcli config` (single source of truth). See
[Getting started](#getting-started--connect-to-a-sap-system).

`:SapDoctor` / `<leader>asd` — read-only validation ladder (connectivity, object search, transports).

`:SapStatus` / `<leader>asi` — shows the active connection: system, client, user.

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

## Keymaps — full reference

| Keymap | Command | Description |
|--------|---------|-------------|
| `<leader>aa` | — | Activate object → errors in quickfix, jump to line |
| `<leader>aT` | `:SapAUnit` | Run AUnit tests → failures in quickfix |
| `<leader>aK` | — | Run ATC quality check |
| `<leader>aF` | — | Format file (ABAP uppercase+indent / CDS braces) |
| `<leader>aw` | `:SapWhereUsed` | Where-used list → quickfix |
| `<leader>aD` | `:SapDiff` | Diff local buffer vs active system version |
| `<leader>ai` | `:SapInactive` | Inactive objects — open or activate individually |
| `<leader>an` | `:SapNew` | New ABAP object with system package/transport pickers |
| `<leader>afs` | `:SapSearch` | Search objects in SAP |
| `<leader>afb` | `:SapBrowse` | Browse package contents |
| `<leader>ack` | `:SapCheckout` | Checkout full package to local filesystem |
| `<leader>atl` | `:SapTransports` | List open transport orders |
| `<leader>atc` | `:SapTransportCreate` | Create transport order |
| `<leader>atr` | `:SapTransportRelease` | Release transport order |
| `<leader>asi` | `:SapStatus` | Show active SAP connection info |
| `<leader>asc` | `:SapSetup` | Connection setup assistant (sapcli kubeconfig) |
| `<leader>asd` | `:SapDoctor` | Read-only validation: connection, objects, transports |
| `<leader>asg` | — | Open SAP GUI |
| `<leader>aso` | — | Open current object in SAP GUI |
| `<leader>ah` | — | Help (all keymaps) |

---

## Naming conventions (abaplint.json)

`abaplint.json` in the project root configures real-time naming checks.
Edit any pattern and the change takes effect on the next keystroke — no restart needed.

### Variables inside methods and forms (local scope)

| Type | Prefix |
|------|--------|
| Variable | `WL_` |
| Internal table | `TL_` |
| Structure / Work area | `XL_` / `WAL_` |
| Constant | `CL_` |
| Type | `TYL_` |
| Type (table) | `TTL_` |
| Static | `STL_` |
| Range | `RL_` |
| Field symbol | `<FS_xxx>` |
| Importing parameter | `PI_` |
| Exporting parameter | `PO_` |
| Changing parameter | `PC_` |
| Tables parameter | `PT_` |

### Class attributes (global scope)

| Type | Prefix |
|------|--------|
| Instance / static variable | `WG_` |
| Internal table | `T_` |
| Structure / Work area | `X_` / `WA_` |
| Static | `ST_` |
| Type | `TY_` / `TT_` |
| Constant | `C_` |

### Object naming

| Object | Pattern | Example |
|--------|---------|---------|
| Program / Report | `Z` | `ZFIR_IVA_MENSUAL` |
| Class (normal) | `ZCLA###_` | `ZCLAMM_PEDIDO` |
| Class (abstract) | `ZCLN###_` | `ZCLN_BASE` |
| Interface | `ZIF###_` | `ZIFMM_MINILOAD` |
| Function group | `ZFG##_` | `ZFGFI_IVA` |
| DDIC Table | `ZT###_` | `ZTFI_CODIGOS` |
| DDIC Structure | `ZS###_` | `ZSFI_CODIGOS` |
| Data element | `ZE###_` | `ZELEM_DAT` |
| Domain | `ZD##_` | `ZD_STATUS` |
| View | `ZV###_` | `ZVFI_CODIGOS` |

---

## Architecture

```
sap-nvim/
├── lua/sap-nvim/
│   ├── init.lua              Entry point — loads all modules
│   ├── core/
│   │   ├── adt.lua           sapcli wrapper: activate, fetch packages/transports/objects
│   │   ├── aunit.lua         AUnit runner + JUnit4 XML parser → quickfix
│   │   ├── browser.lua       Object search and package browser
│   │   ├── checkout.lua      Package checkout to local filesystem
│   │   ├── debugger.lua      Interactive ABAP debugger (requires connection)
│   │   ├── diff.lua          Local vs system vimdiff
│   │   ├── doctor.lua        :SapDoctor read-only validation ladder
│   │   ├── formatter.lua     ABAP + CDS native formatter
│   │   ├── inactive.lua      Inactive objects picker + activation
│   │   ├── keymaps.lua       All keymap definitions
│   │   ├── lsp.lua           Real-time abaplint diagnostics via vim.diagnostic
│   │   ├── new.lua           New object wizard with system pickers
│   │   ├── objtype.lua       File extension → sapcli object group (single source)
│   │   ├── setup.lua         :SapSetup — sapcli kubeconfig connection wizard
│   │   ├── statusline.lua    Lualine component + native statusline
│   │   ├── transport.lua     Transport order management
│   │   └── whereused.lua     Where-used list → quickfix
│   └── integrations/
│       ├── completion.lua    ABAP snippet and keyword completion
│       ├── avante.lua        AI assistant (Avante) — opt-in, not loaded by default
│       └── mcphub.lua        MCP servers for SAP ADT — opt-in, not loaded by default
└── abaplint.json             Linting and naming convention config
```

---

## License

MIT
