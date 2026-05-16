# Test Report: Tree-sitter & Parsers (sap-nvim)

**Date:** 2026-05-16  
**Tester:** JoseLuis (subagent)  
**Scope:** Validación de parsers Tree-sitter ABAP y CDS, resaltado de sintaxis, y arquitectura de registros

---

## 1. Archivos ABAP de prueba ✅

| Archivo | Ruta | Contenido |
|---------|------|-----------|
| `test.abap` | `/test/src/test.abap` | REPORT básico con DATA, WRITE |
| `test-bugs.abap` | `/test/src/test-bugs.abap` | REPORT con IF/ELSE, variable no usada (lv_unused) |
| `abaplint.json` | `/test/src/abaplint.json` | Config abaplint para tests |

**Veredicto:** ✅ Los archivos ABAP de prueba existen y son válidos sintácticamente.  
`test-bugs.abap` incluye intencionadamente una variable no usada para probar reglas abaplint.

**⚠️ Falta:** No hay archivos `.cds` de prueba para validar el parser tree-sitter-cds.

---

## 2. Registro de Parsers en Neovim Config

### 2.1 Config directa (`.config/nvim/lua/plugins/sap-nvim.lua`)

```lua
-- tree-sitter-abap
parser_config.abap = {
  install_info = {
    url = "https://github.com/kennyhml/tree-sitter-abap",
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
  },
  filetype = "abap",
}

-- tree-sitter-cds
parser_config.cds = {
  install_info = {
    url = "https://github.com/cap-js-community/tree-sitter-cds",
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
  },
  filetype = "cds",
}
```

**✅ URL correcta: tree-sitter-abap:** `https://github.com/kennyhml/tree-sitter-abap`  
**✅ URL correcta: tree-sitter-cds:** `https://github.com/cap-js-community/tree-sitter-cds`  
**✅ Branch correcto:** `main`  
**✅ Archivos parser:** incluye `src/parser.c` y `src/scanner.c` (ambos parsers C)

### 2.2 Config modular (proyecto `lua/sap-nvim/core/treesitter.lua`)

```lua
parser_config.abap = {
  install_info = {
    url = opts.abap_url or "https://github.com/kennyhml/tree-sitter-abap",
    files = { "src/parser.c", "src/scanner.c" },
    branch = opts.abap_branch or "main",
  },
  filetype = "abap",
}

parser_config.cds = {
  install_info = {
    url = opts.cds_url or "https://github.com/cap-js-community/tree-sitter-cds",
    files = { "src/parser.c", "src/scanner.c" },
    branch = opts.cds_branch or "main",
  },
  filetype = "cds",
}
```

**✅ URLs correctas** (configurables via opts)  
**✅ Valores por defecto correctos** (kennyhml/tree-sitter-abap, cap-js-community/tree-sitter-cds)

---

## 3. Autocomando FileType "abap" para instalación automática

### En `.config/nvim/lua/plugins/sap-nvim.lua`:
```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "abap",
  callback = function()
    local has_parser = pcall(vim.treesitter.get_parser, 0, "abap")
    if not has_parser then
      vim.schedule(function()
        vim.cmd("TSInstallSync abap")
      end)
    end
  end,
  once = true,
})
```

**✅ Correcto:** Verifica si el parser existe antes de instalar  
**✅ Correcto:** Usa `vim.schedule` para diferir la instalación  
**✅ Correcto:** `once = true` evita ejecución repetida  
**✅ `TSInstallSync`** es el comando correcto de nvim-treesitter para instalación síncrona

### En proyecto `lua/sap-nvim/core/treesitter.lua`:
```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "abap",
  callback = function()
    local has_parser = pcall(vim.treesitter.get_parser, 0, "abap")
    if not has_parser then
      vim.cmd("TSInstallSync abap")
    end
  end,
  once = true,
})
```

**✅ Misma lógica correcta** — aunque sin `vim.schedule()` (menos crítico, pero consistente)

---

## 4. Estructura de `lua/sap-nvim/core/treesitter.lua` ✅

- **Exists:** ✅ `/Users/jcgomez/Desktop/sap-nvim/lua/sap-nvim/core/treesitter.lua`
- **Module pattern:** ✅ `local M = {}` / `function M.setup(opts)` / `return M`
- **Parser registration:** ✅ ABAP y CDS
- **Text objects:** ✅ Configura `nvim-treesitter-textobjects` con select y move
  - `af/if` → function outer/inner
  - `ac/ic` → class outer/inner  
  - `am/im` → method outer/inner
  - `]m/[m` → navigate next/prev method
  - `]f/[f` → navigate next/prev function
- **Carga desde init.lua:** ✅ `require("sap-nvim.core.treesitter").setup(opts.treesitter)`

---

## 5. Posibles Errores Encontrados

### ❌ DUPLICACIÓN CRÍTICA: Dos implementaciones separadas

**Problema:** El archivo `.config/nvim/lua/plugins/sap-nvim.lua` contiene toda la lógica inline (treesitter + LSP + keymaps + SapSetup), **sin usar los módulos del proyecto** (`lua/sap-nvim/init.lua`).

Esto significa:
1. Los parsers se registran **dos veces** (una en el config inline, otra si se carga el proyecto modular)
2. Hay **dos autocommands FileType abap** para TSInstallSync
3. Hay **dos conjuntos de keymaps LSP** para ABAP
4. El LSP (abaplint + CDS) se configura **dos veces**
5. El comando `:SapSetup` se crea **dos veces** (potencial error si ambos se cargan)

**Recomendación:** Unificar. El plugin config (`.config/nvim/lua/plugins/sap-nvim.lua`) debería ser simplemente:
```lua
return {
  dir = "~/Desktop/sap-nvim",
  opts = { ... }
}
```
O, alternativamente, eliminar la versión modular y mantener solo el config inline.

### ❌ No hay archivos `.cds` de prueba

**Problema:** El parser tree-sitter-cds está registrado pero no hay test CDS files.

**Recomendación:** Agregar `test/src/test.cds` o similar.

### ❌ `config/sap-connections.json` tiene formato incompatible

**Problema:** El formato actual usa `system_id`, `host`, `username`, `auth`:
```json
{
  "desarrollo": {
    "system_id": "D01",
    "host": "sap.desarrollo.empresa.com",
    "port": 443,
    "client": "100",
    "username": "$USER",
    "auth": "basic"
  }
}
```

Pero `setup.lua` espera sincronizar desde `sapcli config.yml` con formato `ashost`, `sysnr`, `user`, `password`, `ssl`, etc. Hay **incompatibilidad de formato**.

**Recomendación:** Alinear formatos o documentar claramente que este archivo es legacy.

### ❌ `setup-treesitter.sh` compila parsers manualmente

**Problema:** El script `scripts/setup-treesitter.sh` hace compilación manual vía gcc/clang y copia a `$XDG_DATA_HOME/nvim/treesitter/`. En Neovim moderno con LazyVim, los parsers se instalan mejor con `:TSInstall`. La ruta de instalación manual podría no coincidir con la esperada por nvim-treesitter (que usa hashes en nombres de archivo).

**Recomendación:** El script debería usar `nvim --headless "+TSInstallSync abap" +qa` en lugar de compilación manual.

### ✅ Sin errores en archivos del proyecto

No se encontraron:
- Rutas mal escritas
- Archivos faltantes (todos los módulos Lua existen)
- Dependencias incorrectas en el código Lua
- Errores de sintaxis en los archivos revisados

---

## 6. Resumen

| Componente | Estado | Notas |
|------------|--------|-------|
| Parser tree-sitter-abap registro | ✅ | URL correcta: kennyhml/tree-sitter-abap |
| Parser tree-sitter-cds registro | ✅ | URL correcta: cap-js-community/tree-sitter-cds |
| Autocommand TSInstallSync | ✅ | Con guard `has_parser` y `once = true` |
| Text objects (nvim-treesitter-textobjects) | ✅ | function, class, method |
| Test ABAP files | ✅ | 2 archivos con config abaplint |
| Test CDS files | ❌ | No existen |
| `lua/sap-nvim/core/treesitter.lua` estructura | ✅ | Modular, configurable, bien cargado |
| Duplicación config vs proyecto | ❌ | **CRÍTICO** — dos implementaciones separadas |
| `sap-connections.json` formato | ⚠️ | Incompatible con setup.lua |
| `setup-treesitter.sh` | ⚠️ | Usa compilación manual obsoleta |

## 7. Recomendaciones Prioritarias

1. **Unificar implementaciones** — Decidir si usar el plugin config inline o el proyecto modular. La duplicación actual causará errores en caliente.
2. **Agregar tests CDS** — Crear `test/src/test.cds` para validar el parser.
3. **Estandarizar formato de conexiones** — Alinear `sap-connections.json` con lo que espera `setup.lua`.
4. **Actualizar setup-treesitter.sh** — Usar `nvim --headless` en vez de compilación manual.
5. **Verificar nvim-treesitter dependencia** — El plugin requiere `nvim-treesitter` y `nvim-treesitter-textobjects` como dependencias; asegurar que estén declaradas.
