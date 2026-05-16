---
name: sap-nvim-setup
description: Bootstrap and validate the sap-nvim ABAP development environment for Neovim. Use when setting up a new machine or reinstalling. Covers installation of Neovim, Homebrew, Node.js, Python, sapcli, abaplint, efm-langserver, tree-sitter ABAP parsers, lazy.nvim, and the sap-nvim plugin. Includes validation checklist. NOT for configuring SAP connections (use SapSetup command for that).
---

# sap-nvim-setup

Full environment bootstrap for ABAP development in Neovim.

## Quick Start

```bash
bash <script-dir>/bootstrap.sh
```

Or from the project root:

```bash
bash scripts/bootstrap.sh
```

## What It Installs

| Category | Tools |
|----------|-------|
| Package manager | Homebrew |
| Editor | Neovim 0.10+ (via Homebrew) |
| System utils | git, lazygit, fd, ripgrep, tree-sitter |
| LSP bridge | efm-langserver |
| Runtimes | Node.js, Python 3 |
| ABAP tools | sapcli (pip), abaplint (npm) |
| Neovim config | init.lua with lazy.nvim bootstrap, sap-nvim plugin config |
| Parsers | tree-sitter-abap, tree-sitter-cds |

## Bootstrap Script Behavior

The script is idempotent — safe to re-run on an already-configured machine.

1. **Detects** what's already installed (skips those)
2. **Installs** only what's missing
3. **Creates** Neovim config files only if they don't exist
4. **Validates** everything at the end with a checklist

## Post-Install

After bootstrap, run inside Neovim:

```vim
:TSInstallSync abap  " if tree-sitter parsers weren't installed
:TSInstallSync cds
:SapSetup            " configure SAP connection
```

## References

- Project: `~/Desktop/sap-nvim/`
- Config: `~/.config/nvim/`
- Sapcli: `~/.sapcli/config.yml`
- Keymaps: `<leader>asc` (setup), `<leader>an` (new object), `<leader>ah` (help)
