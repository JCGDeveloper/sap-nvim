# Test de Integración: sap-nvim

**Fecha:** 2026-05-16
**Proyecto:** `/Users/jcgomez/Desktop/sap-nvim`
**NVim Config:** `/Users/jcgomez/.config/nvim/lua/plugins/sap-nvim.lua`

---

## 1. Árbol de Dependencias

```
init.lua
├── core/treesitter.lua       ← requires: nvim-treesitter (ext)
├── core/lsp.lua              ← requires: lspconfig (ext)
├── core/adt.lua              ← sin requires internos
├── core/keymaps.lua          ← requires: sap-nvim.core.adt
├── adapters/oil.lua          ← requires: oil (ext, pcall)
├── adapters/terminal.lua     ← requires: sap-nvim.core.adt
├── integrations/mcphub.lua   ← requires: mcphub (ext, pcall)
├── integrations/avante.lua   ← requires: avante (ext, pcall)
└── core/setup.lua            ← sin requires internos
```

**Dependencias externas (no incluidas en el plugin):**
- `nvim-treesitter`
- `lspconfig`
- `oil.nvim`
- `mcphub.nvim`
- `avante.nvim`

**No hay dependencias circulares.** El grafo es un DAG:
- `keymaps → adt` (adt no requiere keymaps → ✅ sin ciclo)
- `terminal → adt` (adt no requiere terminal → ✅ sin ciclo)

---

## 2. Verificación de Módulos

| Módulo requerido por init.lua | Archivo físico | Existe |
|---|---|---|
| `sap-nvim.core.treesitter` | `core/treesitter.lua` | ✅ |
| `sap-nvim.core.lsp` | `core/lsp.lua` | ✅ |
| `sap-nvim.core.adt` | `core/adt.lua` | ✅ |
| `sap-nvim.core.keymaps` | `core/keymaps.lua` | ✅ |
| `sap-nvim.adapters.oil` | `adapters/oil.lua` | ✅ |
| `sap-nvim.adapters.terminal` | `adapters/terminal.lua` | ✅ |
| `sap-nvim.integrations.mcphub` | `integrations/mcphub.lua` | ✅ |
| `sap-nvim.integrations.avante` | `integrations/avante.lua` | ✅ |
| `sap-nvim.core.setup` | `core/setup.lua` | ✅ |

**Todos los requires resuelven a archivos existentes.** ✅

---

## 3. Consistencia de setup()

| Módulo | Firma `setup()` | Llamada desde init.lua | Coincide |
|---|---|---|---|
| `core/treesitter` | `setup(opts)` | `setup(opts.treesitter)` | ✅ |
| `core/lsp` | `setup(opts)` | `setup(opts.lsp)` | ✅ |
| `core/adt` | `setup(opts)` | `setup({ connections = connections })` | ✅ |
| `core/keymaps` | `setup(opts)` | `setup(opts.keymaps)` | ✅ |
| `adapters/oil` | `setup(opts)` | `setup(opts.oil)` | ✅ |
| `adapters/terminal` | `setup(opts)` | `setup(opts.terminal)` | ✅ |
| `integrations/mcphub` | `setup(opts)` | `setup(opts.mcphub)` | ✅ |
| `integrations/avante` | `setup(opts)` | `setup(opts.avante)` | ✅ |
| `core/setup` | `setup()` (sin args) | `setup()` (sin args) | ✅ |

Todos los módulos usan `opts = opts or {}` como primera línea. ✅

**Nota:** `core/setup.lua` es el único que no recibe opts (es interactivo, no configurable). Coincide con la llamada sin argumentos en init.lua.

---

## 4. Verificación de Sintaxis Lua

Todos los archivos pasan `luac -p` sin errores:

| Archivo | Resultado |
|---|---|
| `init.lua` | ✅ |
| `core/treesitter.lua` | ✅ |
| `core/lsp.lua` | ✅ |
| `core/adt.lua` | ✅ |
| `core/keymaps.lua` | ✅ |
| `core/setup.lua` | ✅ |
| `adapters/oil.lua` | ✅ |
| `adapters/terminal.lua` | ✅ |
| `integrations/mcphub.lua` | ✅ |
| `integrations/avante.lua` | ✅ |
| Neovim config (`sap-nvim.lua`) | ✅ |

---

## 5. Análisis del Config de Neovim

**Archivo:** `/Users/jcgomez/.config/nvim/lua/plugins/sap-nvim.lua`

⚠️ **El config NO requiere ni usa el plugin modular.**

El archivo `sap-nvim.lua` en `~/.config/nvim/lua/plugins/` implementa **TODO inline**:
- Tree-sitter parsers (ABAP + CDS)
- LSP (abaplint + CDS LSP)
- Keymaps LSP
- Comandos ADT (`SapConnectionsHelp`)
- SAP GUI integration
- Comando `:SapSetup` con menú interactivo completo

Esto significa que el plugin modular en `~/Desktop/sap-nvim/lua/sap-nvim/` es una **refactorización/modernización** que aún no está conectada al config real de Neovim.

**Path de conexiones SAP:** El config apunta a `~/Desktop/sap-nvim/config/sap-connections.json` ✅ (archivo existe con 3 conexiones de ejemplo: desarrollo, calidad, produccion).

---

## 6. Observaciones y Recomendaciones

### ✅ Aciertos
- Arquitectura modular limpia con separación core/adapters/integrations
- `pcall(require, ...)` en adapters e integrations para dependencias opcionales
- `opts = opts or {}` consistente en todos los módulos
- Sin dependencias circulares
- Sintaxis Lua correcta en todos los archivos

### ⚠️ Recomendaciones

1. **Conectar el plugin modular al config de Neovim.** Actualmente hay dos implementaciones paralelas. Opciones:
   - **Opción A:** Simplificar `sap-nvim.lua` en Neovim para que solo haga `require("sap-nvim").setup({...})` y delegue todo al plugin.
   - **Opción B:** Mantener ambos pero documentar que el plugin es la versión refactorizada y el config inline es legacy.

2. **Duplicación de keymaps.** Tanto `core/keymaps.lua` como `core/lsp.lua` definen keymaps LSP para ABAP. Configurar keymaps LSP en un solo lugar (probablemente `core/lsp.lua`).

3. **core/setup.lua y sap-nvim.lua duplican el comando :SapSetup.** El config inline define `:SapSetup` con lógica propia, y `core/setup.lua` también lo registra. Si ambos se cargan, habrá conflicto (el último gana).

4. **Dependencia externa explícita.** El plugin depende de `nvim-treesitter`, `lspconfig`, `oil.nvim`, `mcphub.nvim`, y `avante.nvim`. Considerar agregar un `README.md` o `dependencies.md` listando estas dependencias.

5. **Config/init migration.** El config inline tiene 460+ líneas. Refactorizarlo para que delegue en el plugin modular reduciría drásticamente la duplicación y facilitaría el mantenimiento.

---

## Resumen

| Verificación | Resultado |
|---|---|
| Entry point init.lua — todos los requires válidos | ✅ |
| Todos los módulos existen físicamente | ✅ |
| setup() signatures consistentes | ✅ |
| Sin dependencias circulares | ✅ |
| Sintaxis Lua (todos los archivos) | ✅ |
| Plugin modular conectado al config de Neovim | ❌ (no conectado) |

**Veredicto:** La arquitectura del plugin es sólida y consistente. El principal issue es que el config activo de Neovim no utiliza el plugin modular — hay dos implementaciones paralelas que pueden causar conflictos si se activan ambas.
