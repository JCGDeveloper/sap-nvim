# sap-nvim — Arquitectura Avanzada para Desarrollo ABAP en Neovim

> Integración de ADT, LSP, Tree-sitter y Protocolo de Contexto de Modelos (MCP)
> en Entornos Corporativos Remotos

## 🎯 Visión General

Transformar Neovim en el entorno de desarrollo ABAP más potente del ecosistema SAP, superando las limitaciones de conectividad corporativa mediante una arquitectura basada en componentes desacoplados, protocolos abiertos y capacidades de IA agéntica.

```
┌─────────────────────────────────────────────────────────────────┐
│                         sap-nvim                                │
├─────────────────────────────────────────────────────────────────┤
│                                                                  │
│  ┌──────────┐  ┌──────────┐  ┌──────────┐  ┌────────────────┐  │
│  │Tree-sitter│  │   LSP    │  │   ADT    │  │   MCP / IA     │  │
│  │  ABAP    │  │ abaplint │  │  Remote  │  │   Agentic      │  │
│  │  CDS     │  │  CDS LSP │  │  Filesys │  │   ARC-1        │  │
│  └──────────┘  └──────────┘  └──────────┘  └────────────────┘  │
│       │              │              │               │           │
│       ▼              ▼              ▼               ▼           │
│  ┌─────────────────────────────────────────────────────────┐    │
│  │              Neovim Core (LazyVim + Lua)                │    │
│  └─────────────────────────────────────────────────────────┘    │
│                                                                  │
└─────────────────────────────────────────────────────────────────┘
```

## 📋 Componentes Principales

### 1. Análisis Sintáctico — Tree-sitter
- **tree-sitter-abap**: Parser de ABAP (kennyhml, mkoval1)
- **tree-sitter-cds**: Parser de Core Data Services (CAP community)
- Soporte para sentencias encadenadas ABAP
- Text objects para bloques lógicos (METHOD...ENDMETHOD, FORM...ENDFORM)

### 2. Inteligencia de Código — LSP
- **abaplint**: Servidor de lenguaje ABAP (TypeScript, open-source)
- **@sap/cds-lsp**: Servidor de lenguaje CDS (npm global)
- Validación "Clean ABAP", autocompletado, formateo
- Navegación a definiciones, referencias, diagnosticos en tiempo real

### 3. Gestión Remota — ADT API
- **sapcli**: CLI Python para operaciones ADT
- **abap-adt-api**: Biblioteca Node.js para sistema de archivos virtual
- **oil.nvim**: Adaptador personalizado para navegación remota
- Flujo: Lock → Read → Modify → Unlock → Activate

### 4. IA Agéntica — MCP
- **ARC-1**: Servidor MCP seguro para SAP ADT (marianfoo)
- **mcp-abap-adt-api**: Servidor MCP basado en abap-adt-api (mario-andreschak)
- **mcphub.nvim** / **avante.nvim**: Clientes MCP para Neovim
- Operaciones autónomas: exploración, recuperación, mutación, activación

## 🏗️ Arquitectura del Proyecto

```
~/Desktop/sap-nvim/
├── README.md                    ← Este archivo
├── docs/
│   ├── ARQUITECTURA.md          ← Documento completo de arquitectura
│   ├── INSTALACION.md           ← Guía de instalación paso a paso
│   ├── CONFIGURACION.md         ← Configuración detallada
│   ├── FLUJOS.md                ← Flujos de trabajo
│   └── MCP-SETUP.md             ← Configuración de servidores MCP
├── lua/
│   └── sap-nvim/
│       ├── init.lua             ← Entry point del plugin
│       ├── core/
│       │   ├── treesitter.lua   ← Configuración Tree-sitter ABAP/CDS
│       │   ├── lsp.lua          ← Configuración LSP (abaplint, cds)
│       │   ├── adt.lua          ← Cliente ADT API
│       │   └── keymaps.lua      ← Atajos de teclado
│       ├── adapters/
│       │   ├── oil.lua          ← Adaptador oil.nvim para SAP
│       │   └── terminal.lua     ← Integración con sapcli
│       └── integrations/
│           ├── mcphub.lua       ← Integración MCP Hub
│           └── avante.lua       ← Integración Avante
├── scripts/
│   ├── setup-treesitter.sh      ← Script de instalación de parsers
│   ├── setup-lsp.sh             ← Script de instalación de LSPs
│   ├── setup-mcp.sh             ← Script de instalación de MCP servers
│   └── sap-connect.sh           ← Script de conexión SAP
└── config/
    ├── abaplint.json            ← Configuración de abaplint
    └── sap-connections.json     ← Conexiones a sistemas SAP
```

## 🚀 Estado del Proyecto

| Componente | Estado | Prioridad |
|---|---|---|
| Tree-sitter ABAP | ✅ Investigado | Alta |
| Tree-sitter CDS | ✅ Investigado | Alta |
| abaplint LSP | ✅ Investigado | Alta |
| CDS LSP | ✅ Investigado | Alta |
| ADT API / sapcli | ✅ Investigado | Alta |
| oil.nvim adapter | 🔬 En desarrollo | Media |
| MCP (ARC-1) | ✅ Investigado | Alta |
| MCP (mcp-abap-adt) | ✅ Investigado | Alta |
| DAP (debugging) | ⏳ Pendiente | Baja |

## 📚 Recursos Clave

- [ARC-1: SAP ADT MCP Server](https://github.com/marianfoo/arc-1)
- [mcp-abap-adt-api](https://github.com/mario-andreschak/mcp-abap-abap-adt-api)
- [sapcli](https://github.com/jfilak/sapcli)
- [abap-adt-api (NPM)](https://www.npmjs.com/package/abap-adt-api)
- [tree-sitter-abap](https://github.com/kennyhml/tree-sitter-abap)
- [abaplint](https://github.com/analysis-tools-dev/static-analysis)
- [SAP ADT for VS Code (Oficial)](https://community.sap.com/t5/technology-blog-posts-by-sap/abap-development-tools-for-vs-code-everything-you-need-to-know/ba-p/14258129)

---

## ⌨️ Keymaps

| Keymap | Comando | Descripción |
|--------|---------|-------------|
| `<leader>aa` | — | Activar objeto ABAP → errores van al quickfix con jump automático |
| `<leader>an` | `:SapNew` | Nuevo objeto ABAP con pickers de paquete y transporte desde el sistema |
| `<leader>aw` | `:SapWhereUsed` | Where-used list del objeto actual → quickfix |
| `<leader>aD` | `:SapDiff` | Diff buffer local vs versión activa en el sistema |
| `<leader>aF` | — | Formatear ABAP (uppercase + indentación) |
| `<leader>aT` | — | Ejecutar tests AUnit |
| `<leader>aK` | — | Ejecutar ATC (quality check) |
| `<leader>afs` | `:SapSearch` | Buscar objetos en el sistema SAP |
| `<leader>afb` | `:SapBrowse` | Explorar contenido de un paquete |
| `<leader>ack` | `:SapCheckout` | Descargar paquete SAP completo al filesystem local |
| `<leader>atl` | `:SapTransports` | Listar órdenes de transporte abiertas |
| `<leader>atc` | `:SapTransportCreate` | Crear orden de transporte |
| `<leader>atr` | `:SapTransportRelease` | Liberar orden de transporte |
| `<leader>asi` | `:SapStatus` | Info de la conexión activa |
| `<leader>asc` | `:SapSetup` | Asistente de configuración de conexiones SAP |
| `<leader>ah` | — | Ayuda completa |

## 📊 Statusline — Integración con lualine

El plugin expone un componente lualine listo para usar. Muestra la conexión SAP activa
(`SID · cliente · usuario`) solo cuando el buffer activo es un archivo ABAP.

### Configuración

```lua
require('lualine').setup({
  sections = {
    lualine_x = {
      -- Agrega el componente SAP antes del filetype
      require('sap-nvim.core.statusline').component,
      'encoding',
      'fileformat',
      'filetype',
    },
  },
})
```

El componente ya incluye:
- **Condición**: solo visible en archivos `.abap`, `.cls`, `.intf`, etc.
- **Color**: naranja (`#e8a87c`) en negrita para distinguirlo del resto
- **Cache**: relee `~/.sapcli/config.yml` cada 30 segundos, no en cada redraw

### Sin lualine

Si no usás lualine, el plugin setea automáticamente `vim.opt_local.statusline` en
cada buffer ABAP con el formato:

```
nombre.abap [modified]       ABAP  [SAP: DEV/100/JCGOMEZ]  42:8
```

También podés consultar `vim.g.sap_nvim_status` desde cualquier plugin de statusline
que soporte expresiones Lua:

```lua
-- En cualquier statusline personalizada:
local sap = vim.g.sap_nvim_status or ""
```

### Comando

```
:SapStatus   →  [sap-nvim] Sistema: DEV  Cliente: 100  Usuario: JCGOMEZ  Contexto: desarrollo
```

---

> **Nota:** Este proyecto es el resultado de una investigación exhaustiva sobre la viabilidad de desarrollar ABAP en Neovim, analizando los protocolos ADT REST, LSP, MCP y las herramientas open-source disponibles en la comunidad.
