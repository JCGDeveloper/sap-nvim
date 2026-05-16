# Reporte de Validación LSP — sap-nvim

**Fecha:** 2026-05-16  
**Proyecto:** `/Users/jcgomez/Desktop/sap-nvim/`  
**Neovim:** v0.12.2  
**Node:** v24.15.0  

---

## 1. ✅ abaplint — Instalación

| Aspecto | Estado | Detalle |
|---------|--------|---------|
| Binario | ✅ | `/opt/homebrew/bin/abaplint` v2.119.19 |
| Origen | ✅ | `@abaplint/cli` npm package |
| Ruta en PATH | ✅ | `/opt/homebrew/bin/abaplint` |

---

## 2. ❌ abaplint — Configuración LSP (PROBLEMA CRÍTICO)

### Config actual (`sap-nvim.lua`):

```lua
vim.lsp.config('abaplint', {
  cmd = { 'abaplint', '--format', 'json' },
  filetypes = { 'abap' },
  root_markers = { 'abaplint.json', '.git' },
})
```

### Problema:

**`abaplint --format json` NO es un servidor LSP.**  
El comando ejecuta el linter, imprime JSON a stdout y **termina el proceso inmediatamente**. No implementa el protocolo LSP (no maneja `initialize`, `textDocument/didOpen`, etc.).

Esto significa que Neovim lanza abaplint, éste emite el JSON con los errores (o error de glob), y sale. El cliente LSP de Neovim se queda esperando mensajes JSON-RPC que nunca llegan.

### Diagnóstico:

```
$ abaplint --format json
→ Outputs JSON con issues y EXIT inmediatamente (código 1 o 2)
→ No hay un socket/stdio persistente con protocolo LSP
```

### Recomendación:

Hay 3 opciones viables:

**Opción A (recomendada): Usar `efm-langserver` o `diagnostic-languageserver` como wrapper LSP**

```lua
vim.lsp.config('abaplint', {
  cmd = { 'efm-langserver', '-c', vim.fn.expand('~/efm-abaplint.yaml') },
  filetypes = { 'abap' },
  root_markers = { 'abaplint.json', '.git' },
})
```

Con archivo de config `efm-abaplint.yaml`:
```yaml
tools:
  abaplint: &abaplint
    format: json
    lint-command: 'abaplint -c abaplint.json --format json'
    lint-format: 'abaplint'
    lint-stdin: true
```

**Opción B: Usar `@abaplint/core` programáticamente como LSP server**

Crear un wrapper Node.js:
```javascript
const { LanguageServer } = require('@abaplint/core');
// Inicializar servidor LSP sobre stdio
```

**Opción C (más simple): `vim.diagnostic` con `vim.fn.system`**

Ejecutar abaplint mediante `vim.fn.system()` tras guardar y parsear el JSON manualmente para poblarlo como diagnósticos inline.

---

## 3. ✅ abaplint — Config (root_markers, filetypes) y keymaps

| Aspecto | Estado | Detalle |
|---------|--------|---------|
| `root_markers` | ✅ | `{ 'abaplint.json', '.git' }` — correcto |
| `filetypes` | ✅ | `{ 'abap' }` — correcto |
| `settings` | ✅ | `{}` — correcto (config desde abaplint.json) |
| Keymaps LSP | ✅ | `gd` (def), `K` (hover), `gr` (refs), `<leader>rn` (rename), `<leader>f` (format), `[d`/`]d`/`<leader>e` (diagnósticos) |

Todos los keymaps tienen sentido para ABAP. No hay cambios recomendados.

---

## 4. ✅ abaplint.json — Archivos de Configuración

Se encontraron **3 archivos**:

| Archivo | files | Notas |
|---------|-------|-------|
| `test/abaplint.json` | `./*.abap` | ❌ No encuentra archivos fuera del directorio actual |
| `test/src/abaplint.json` | `./*.abap` | ✅ Coincide con ABAPs en `src/` |
| `config/abaplint.json` | `/**/*.abap` | ❌ Ruta absoluta no coincide con estructura del proyecto |

### Issues detectados:

- **`test/abaplint.json`**: El patrón `./*.abap` busca archivos en `test/` pero los ABAPs están en `test/src/`
- **`config/abaplint.json`**: El patrón `/**/*.abap` es una ruta absoluta que no funciona
- **Bug en abaplint 2.119.19**: El flag `--file` antepone incorrectamente el path del config, resultando en rutas inválidas (ej: `config../test/src/*.abap`)

### Config sintáctica:
- `syntax.version: "v740sp02"` ✅ (razonable para proyectos ABAP on-premise)
- Rules activas: `indentation`, `line_length: 120`, `naming.allow_underscore` ✅
- `config/abaplint.json` incluye dependencia externa: `CleanABAP.json` de SAP styleguides ✅

### Recomendación:

Crear un `abaplint.json` en la raíz del proyecto (`/Users/jcgomez/Desktop/sap-nvim/abaplint.json`):

```json
{
  "global": {
    "files": "/test/src/**/*.abap",
    "skip": "/node_modules/"
  },
  "dependencies": [
    {
      "url": "https://raw.githubusercontent.com/SAP/styleguides/main/clean-abap/CleanABAP.json"
    }
  ],
  "syntax": {
    "version": "v740sp02",
    "error": ["syntax_error"]
  },
  "rules": {
    "indentation": {
      "allow_chain_declaration": true
    },
    "line_length": {
      "maximum": 120
    },
    "naming": {
      "allow_underscore": true
    }
  }
}
```

---

## 5. ✅ CDS LSP — Instalación y Configuración

| Aspecto | Estado | Detalle |
|---------|--------|---------|
| Paquete npm | ✅ | `@sap/cds-lsp@9.9.0` en `/opt/homebrew/lib/node_modules/` |
| Binario | ✅ | `/opt/homebrew/bin/cds-lsp` → `../lib/node_modules/@sap/cds-lsp/dist/main.js` |
| Comando `--stdio` | ✅ | Responde correctamente a protocolo LSP sobre stdio |
| Config en `sap-nvim.lua` | ✅ | `cmd = { "cds-lsp", "--stdio" }` es correcto |
| `filetypes` | ✅ | `{ "cds" }` |
| `root_dir` | ✅ | `root_pattern(".git", "package.json")` |
| API usada | ✅ | `lspconfig.util.root_pattern` (compatible con Neovim 0.12) |

---

## 6. Validación de Keymaps LSP para ABAP

| Keymap | Función | Adecuado para ABAP |
|--------|---------|---------------------|
| `gd` | Go to Definition | ✅ Esencial para navegar jerarquías de clase/método |
| `K` | Hover | ✅ Ver tipos y documentación inline |
| `gr` | Go to References | ✅ Buscar referencias a métodos/variables |
| `<leader>rn` | Rename | ⚠️ Funciona si abaplint lo soporta como LSP. Con `efm-langserver` no tendrá rename. |
| `<leader>f` | Format | ✅ abaplint soporta formateo (vía `--fix`) |
| `[d` / `]d` | Diagnostic nav | ✅ Navegar errores |
| `<leader>e` | Diagnostic float | ✅ Ver detalle del error |

**Observación:** `<leader>rn` (rename) y `<leader>f` (format) son operaciones avanzadas que abaplint LSP puede soportar, pero requieren una integración LSP correcta (no el CLI directo).

---

## Resumen

| Componente | Estado | Acción requerida |
|------------|--------|------------------|
| abaplint CLI | ✅ Instalado | Ninguna |
| abaplint LSP server | ❌ No funciona | Corregir `cmd` en `sap-nvim.lua` — usar wrapper LSP |
| CDS LSP | ✅ Instalado y configurado | Ninguna |
| `abaplint.json` en test/ | ⚠️ Glob no coincide | Crear config raíz o ajustar globs |
| `abaplint.json` en config/ | ⚠️ Ruta absoluta rota | Cambiar a `/*.abap` o ajustar |
| Keymaps ABAP | ✅ Adecuados | Ninguna |

### Prioridades:

1. 🔴 **Crítico:** Reemplazar `cmd = { 'abaplint', '--format', 'json' }` por un wrapper LSP real (`efm-langserver`/`diagnostic-languageserver`) o implementar diagnóstico inline con `vim.diagnostic`
2. 🟡 **Media:** Estandarizar `abaplint.json` — crear uno en la raíz del proyecto con globs correctos
3. 🟢 **Baja:** Evaluar si se necesita rename/format avanzados (depende del wrapper LSP elegido)
