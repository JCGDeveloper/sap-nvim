# Arquitectura sap-nvim

## Fundamentos Técnicos

El ecosistema SAP ha evolucionado desde el ABAP Workbench (SE80) hacia interfaces abiertas. SAP TechEd 2025 y SAP Sapphire 2026 oficializan el soporte de VS Code para ABAP Cloud. Esto confirma que la API REST de ADT es el estándar definitivo para el desarrollo ABAP moderno.

### Tabla Comparativa de Entornos

| Característica | SAP GUI | Eclipse ADT | VS Code | sap-nvim (Neovim) |
|---|---|---|---|---|
| Protocolo | Diag (prop.) | REST ADT | REST ADT | REST ADT (sapcli/Node.js) |
| File System | Directo DB | Proyectos | Virtual Workspace | Buffers + Adaptadores |
| Parsing | Kernel | Java Optimizer | TextMate / LSP | Tree-sitter |
| Validación | Compilador | ADT Backend | ABAP LSP Oficial | abaplint LSP |
| Debug | Depurador Diag | ADT Debugger | DAP (próximo) | Pendiente (DAP) |
| IA | Inexistente | Joule | Copilot / MCP | MCP nativo |

## 1. Análisis Sintáctico con Tree-sitter

### tree-sitter-abap

El parser ABAP comunitario maneja la complejidad de las **sentencias encadenadas**:

```abap
DATA: v_texto TYPE string,
      v_numero TYPE i.
```

Los dos puntos (`:`) distribuyen el comando inicial (`DATA`) a múltiples expresiones separadas por comas, fragmentando el contexto léxico.

**Configuración en Neovim:**

```lua
local parser_config = require("nvim-treesitter.parsers").get_parser_configs()
parser_config.abap = {
  install_info = {
    url = "https://github.com/kennyhml/tree-sitter-abap",
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
  },
  filetype = "abap",
}
```

**Requisitos:**
- Neovim ≥ 0.12
- Compilador C en PATH (para compilar el parser)
- nvim-treesitter plugin

### tree-sitter-cds

Para archivos `.cds` (Core Data Services):

```lua
parser_config.cds = {
  install_info = {
    url = "https://github.com/cap-js-community/tree-sitter-cds",
    files = { "src/parser.c", "src/scanner.c" },
    branch = "main",
  },
  filetype = "cds",
}
```

## 2. Language Server Protocol

### abaplint

Servidor de lenguaje ABAP open-source escrito en TypeScript. Proporciona:
- Validación sintáctica
- Reglas "Clean ABAP"
- Formateo automático
- Diagnósticos en tiempo real

**Instalación:**
```bash
npm install -g abaplint
```

**Configuración nativa LSP (Neovim ≥ 0.11):**
```lua
vim.lsp.config('abaplint', {
  cmd = { 'abaplint', '--format', 'json' },
  filetypes = { 'abap' },
  root_markers = { 'abaplint.json', 'package.json', '.git' },
})
vim.lsp.enable('abaplint')
```

### CDS Language Server

Para archivos CDS (SAP CAP):

```bash
npm install -g @sap/cds-lsp
```

```lua
local configs = require("lspconfig.configs")
configs.cds_lsp = {
  default_config = {
    cmd = { "cds-lsp", "--stdio" },
    filetypes = { "cds" },
    root_dir = lspconfig.util.root_pattern(".git", "package.json"),
  },
}
```

## 3. API REST de ADT

### Protocolo de Ciclo de Vida

El flujo completo para modificar código en SAP:

```
1. BÚSQUEDA:      GET  /sap/bc/adt/repository/informationsystem/search
2. LECTURA:       GET  /sap/bc/adt/oo/classes/zcl_ejemplo/source/main
3. BLOQUEO:       POST ?_action=LOCK&accessMode=MODIFY → LOCK_HANDLE
4. ESCRITURA:     PUT  (con LOCK_HANDLE en headers)
5. ACTIVACIÓN:    POST /sap/bc/adt/activation
```

### sapcli

CLI en Python que encapsula todo el ciclo ADT:

```bash
# Activar objeto
sapcli activate ZCL_EJEMPLO

# Ejecutar pruebas unitarias
sapcli aunit run class ZCL_EJEMPLO --output junit4

# Ejecutar ATC
sapcli atc run object ZCL_EJEMPLO

# Buscar objetos
sapcli search ZCL_EJEMPLO
```

### Flujo de Trabajo en Neovim

```lua
vim.api.nvim_create_autocmd("FileType", {
  pattern = "abap",
  callback = function()
    vim.bo.makeprg = "sapcli activate %:t:r"

    -- Guardar y activar
    vim.keymap.set("n", "<leader>aa", function()
      vim.cmd("write")
      vim.cmd("make")
    end, { buffer = true })

    -- Ejecutar ATC
    vim.keymap.set("n", "<leader>ac", function()
      vim.cmd("!sapcli atc run object %:t:r")
    end, { buffer = true })
  end,
})
```

## 4. Model Context Protocol (MCP)

### Servidores MCP para SAP

**ARC-1** (marianfoo):
- Servidor MCP seguro para SAP ADT
- Política "default deny" para operaciones de escritura
- Soporta propagación de identidad (Principal Propagation)
- Límites por paquetes ($TMP, Z*) y listas de acceso

**mcp-abap-adt-api** (mario-andreschak):
- Encapsula abap-adt-api como servidor MCP
- Herramientas: GetProgram, GetClass, GetInterface, GetTable, etc.
- Ligero, ideal para desarrollo rápido

### Integración con Neovim

```lua
-- mcphub.nvim
{
  "ravitemer/mcphub.nvim",
  dependencies = { "nvim-lua/plenary.nvim" },
  config = function()
    require("mcphub").setup({
      servers = {
        -- ARC-1 para producción
        {
          name = "arc-1",
          cmd = { "node", "path/to/arc-1/server.js" },
        },
        -- mcp-abap-adt para desarrollo rápido
        {
          name = "abap-adt",
          cmd = { "node", "path/to/mcp-abap-adt-api/dist/index.js" },
        },
      },
    })
  end,
}
```

## 5. Debugging (DAP) — Estado Actual

El Debug Adapter Protocol para ABAP aún no tiene una implementación pública. La comunidad está trabajando en ello tras el anuncio de SAP en TechEd 2025.

**Alternativas mientras tanto:**
- TDD con pruebas unitarias remotas (`sapcli aunit run`)
- Logs de transporte
- ABAP Test Cockpit

## Mapa de Integración Completo

```
                    ┌──────────────────┐
                    │     Neovim       │
                    └────────┬─────────┘
                             │
              ┌──────────────┼──────────────┐
              │              │              │
              ▼              ▼              ▼
     ┌────────────┐  ┌────────────┐  ┌────────────┐
     │ Tree-sitter │  │ LSP Client │  │ MCP Client │
     │  ABAP/CDS   │  │ abaplint   │  │ mcphub     │
     └────────────┘  └────────────┘  └────────────┘
                           │                │
                           ▼                ▼
                    ┌────────────┐  ┌────────────┐
                    │ abaplint   │  │ MCP Server │
                    │ (Node.js)  │  │ ARC-1      │
                    └────────────┘  └──────┬─────┘
                                           │
                                           ▼
                                    ┌────────────┐
                                    │  SAP ADT   │
                                    │  REST API  │
                                    └──────┬─────┘
                                           │
                                           ▼
                                    ┌────────────┐
                                    │   SAP SAP   │
                                    │  NetWeaver  │
                                    └────────────┘
```
