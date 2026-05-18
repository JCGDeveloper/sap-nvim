---
name: creator-skill
description: Full project context for sap-nvim subagents. Inject into any agent that needs to read or modify this codebase. Covers architecture, module structure, code patterns, known bugs, and fix prescriptions.
---

# sap-nvim — Project Context for Subagents

## What is sap-nvim?

A Neovim plugin for SAP ABAP development. Connects Neovim to SAP systems via:
- **Tree-sitter**: ABAP/CDS syntax highlighting
- **abaplint LSP**: ABAP diagnostics + formatting (currently broken)
- **sapcli CLI**: activate objects, run ATC/AUNIT, search SAP objects
- **SAP GUI integration**: open objects in SAP GUI desktop app
- **MCP integration**: AI assistance via mcphub.nvim
- **Avante**: AI editor integration

## File Structure

```
lua/sap-nvim/
  init.lua                  — Entry point; loads modules via pcall
  core/
    treesitter.lua          — Registers ABAP + CDS tree-sitter parsers
    lsp.lua                 — abaplint LSP config (Neovim 0.11 native API)
    keymaps.lua             — Key mappings: <leader>aF, <leader>asg, <leader>aso, <leader>ah
    adt.lua                 — ADT client: activate, ATC, AUNIT, search, open_gui
    setup.lua               — :SapSetup wizard (SAP connection management UI)
    new.lua                 — :SapNew wizard (create ABAP objects from templates)
  adapters/
    terminal.lua            — :SapConnectionsHelp user command
    oil.lua                 — oil.nvim adapter for sap:// protocol (optional)
  integrations/
    avante.lua              — Avante AI integration (optional, guarded)
    mcphub.lua              — MCP hub integration (optional, guarded)
config/
  abaplint.json             — abaplint lint rules
  efm-langserver.yaml       — EFM langserver bridge (defines format-command for abaplint)
  sap-connections.json      — SAP connection definitions
skill/
  creator-skill.md          — This file: project context for subagents
  ARCHITECTURE.md           — Architecture reference
  sap-nvim-setup/SKILL.md   — Bootstrap/setup skill
```

## Code Patterns (follow these exactly)

- Every module: `local M = {}` with `M.setup(opts)`, returns `M`
- Error protection: all modules loaded via `pcall(function() require(mod).setup(opts) end)` in init.lua
- Notifications: `vim.notify(msg, vim.log.levels.{INFO|WARN|ERROR})`
- Neovim 0.11+ API: `vim.lsp.config('name', {...})` then `vim.lsp.enable('name')`
- Optional integrations are always guarded: `local ok, lib = pcall(require, "lib-name"); if not ok then return end`
- No heavy optional dependencies in core (no telescope in core paths)
- Keymaps use `vim.keymap.set("n", "<leader>a...", fn, { desc = "ABAP: ..." })`

## Known Bugs and Required Fixes

### BUG 1 — Formatting Broken (critical)
**Files**: `lua/sap-nvim/core/keymaps.lua:28-32`, `lua/sap-nvim/core/lsp.lua`

**Root cause**: `<leader>aF` calls `vim.lsp.buf.format({ async = true })`. abaplint is
configured as `cmd = { 'abaplint', '--format', 'json' }` which is diagnostic-only LSP mode.
It does NOT implement `textDocument/formatting`. The keymap silently does nothing.

**Prescribed fix for keymaps.lua** — replace the `<leader>aF` keymap body:
```lua
vim.keymap.set("n", "<leader>aF", function()
  if vim.bo.filetype ~= "abap" then return end
  local filepath = vim.api.nvim_buf_get_name(0)
  if filepath == "" then
    vim.notify("sap-nvim: Save the file first", vim.log.levels.WARN)
    return
  end
  vim.cmd("write")
  vim.fn.jobstart({ "abaplint", "--fix", filepath }, {
    on_exit = function(_, code)
      vim.schedule(function()
        vim.cmd("checktime")
        if code == 0 then
          vim.notify("sap-nvim: Format applied", vim.log.levels.INFO)
        else
          vim.notify("sap-nvim: abaplint --fix failed (code " .. code .. ")", vim.log.levels.WARN)
        end
      end)
    end,
  })
end, { desc = "ABAP: Formatear" })
```

**Prescribed fix for lsp.lua** — after the existing abaplint LSP setup, add efm-langserver
as an optional LSP formatter (only if the binary is available):
```lua
-- efm-langserver: bridges abaplint --fix into LSP textDocument/formatting
if vim.fn.executable("efm-langserver") == 1 then
  local efm_config = vim.fn.stdpath("data") .. "/../../../Desktop/sap-nvim/config/efm-langserver.yaml"
  -- Use the config relative to the plugin repo; fall back to XDG path
  local config_candidates = {
    vim.fn.expand("~/Desktop/sap-nvim/config/efm-langserver.yaml"),
    vim.fn.stdpath("config") .. "/efm-langserver.yaml",
  }
  local efm_config_path = nil
  for _, p in ipairs(config_candidates) do
    if vim.fn.filereadable(p) == 1 then
      efm_config_path = p
      break
    end
  end
  if efm_config_path then
    pcall(function()
      vim.lsp.config('efm', {
        cmd = { 'efm-langserver', '-c', efm_config_path },
        filetypes = { 'abap' },
        root_markers = { 'abaplint.json', '.git' },
      })
      vim.lsp.enable('efm')
    end)
  end
end
```

### BUG 2 — Missing Module Loading (important)
**File**: `lua/sap-nvim/init.lua:9-14`

Only 4 of 10 modules are loaded. The following modules exist but are NEVER initialized,
so their user commands and keymaps are never registered:
- `sap-nvim.core.adt` → M.activate_current, M.run_atc, M.run_aunit, M.search, M.open_gui
- `sap-nvim.core.setup` → :SapSetup command, <leader>asc
- `sap-nvim.core.new` → :SapNew command, <leader>an
- `sap-nvim.adapters.oil` → oil.nvim SAP adapter (guarded internally — safe to add)
- `sap-nvim.integrations.avante` → Avante AI (guarded internally — safe to add)
- `sap-nvim.integrations.mcphub` → MCP hub (guarded internally — safe to add)

**Prescribed fix**: update the `modules` table in init.lua:
```lua
local modules = {
  "sap-nvim.core.treesitter",
  "sap-nvim.core.lsp",
  "sap-nvim.core.keymaps",
  "sap-nvim.core.adt",
  "sap-nvim.core.setup",
  "sap-nvim.core.new",
  "sap-nvim.adapters.terminal",
  "sap-nvim.adapters.oil",
  "sap-nvim.integrations.avante",
  "sap-nvim.integrations.mcphub",
}
```
The existing pcall wrapper handles modules that fail gracefully — safe to add all.

### BUG 3 — Lua Scope Error in new.lua (crash on :SapNew)
**File**: `lua/sap-nvim/core/new.lua`

**Issue A** (line 299): `create_file()` calls `add_package_header()` before that local
function is defined (defined at line 326). In Lua, local functions must be defined before
their call site in the same scope. This causes a nil call crash.

**Issue B** (line 303): `local f = io.open(filename, "w")` shadows the `local f` defined
at line 285 (existence check). Rename the write handle to `local fw`.

**Prescribed fix**: Move the entire `add_package_header` function body to BEFORE
`create_file`. The corrected order should be:
1. `add_package_header(name, pkg, trans_req)` — defined first
2. `create_file(obj_type, obj_name, extra, pkg, trans_req)` — defined second, calls add_package_header

Also rename the shadowed variable inside create_file:
```lua
-- line ~303: change
local f = io.open(filename, "w")   -- WRONG: shadows the earlier local f
-- to:
local fw = io.open(filename, "w")
if not fw then ...
fw:write(content)
fw:close()
```

## Constraints

- Do NOT add heavy optional dependencies (telescope, etc.) to core
- Keep pcall guards on all optional integrations
- Neovim >= 0.11 required (native vim.lsp.config API)
- `abaplint` binary: install via `npm install -g @abaplint/cli`
- `efm-langserver` binary: install via `brew install efm-langserver` (in bootstrap)
- `sapcli` Python CLI: install via `pip3 install sapcli`
- Notifications use `vim.notify`, never `print` or `io.write`
- Keymaps are all under `<leader>a` prefix for ABAP namespace
