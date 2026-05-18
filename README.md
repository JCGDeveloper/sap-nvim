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
  config = function()
    require("sap-nvim").setup()
  end,
}
```

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

`<leader>aa` saves the file and runs `sapcli activate`. On success it clears the quickfix list.
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

`<leader>aK` runs ABAP Test Cockpit via `sapcli atc run object <name>`.

---

### Where-used list

`<leader>aw` asks SAP for all usages of the current object and loads them into the quickfix
list. Entries marked `[local]` if the file exists locally, `[system]` otherwise.

---

### Inactive objects

`<leader>ai` (`:SapInactive`) fetches the inactive objects queue from the system. Picker options:

- **Activate ALL** — runs `sapcli activation activate inactiveobjects`
- **Select one** → second picker: Open local file / Activate in system / Open + Activate

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

`:SapSetup` / `<leader>asc` — interactive assistant for configuring sapcli connections.

`:SapStatus` / `<leader>asi` — shows the active connection: system, client, user.

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
| `<leader>asc` | `:SapSetup` | Connection setup assistant |
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
│   │   ├── formatter.lua     ABAP + CDS native formatter
│   │   ├── inactive.lua      Inactive objects picker + activation
│   │   ├── keymaps.lua       All keymap definitions
│   │   ├── lsp.lua           Real-time abaplint diagnostics via vim.diagnostic
│   │   ├── new.lua           New object wizard with system pickers
│   │   ├── setup.lua         Connection setup assistant
│   │   ├── statusline.lua    Lualine component + native statusline
│   │   ├── transport.lua     Transport order management
│   │   └── whereused.lua     Where-used list → quickfix
│   └── integrations/
│       └── completion.lua    ABAP snippet and keyword completion
└── abaplint.json             Linting and naming convention config
```

---

## License

MIT
