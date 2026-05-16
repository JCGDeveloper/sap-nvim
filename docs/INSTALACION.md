# Guía de Instalación — sap-nvim

## Prerrequisitos

```bash
# Neovim ≥ 0.12
nvim --version

# Node.js ≥ 18 (para abaplint, CDS LSP, MCP servers)
node --version

# Python ≥ 3.8 (para sapcli)
python3 --version

# Compilador C (para tree-sitter)
gcc --version || clang --version
```

## Paso 1: Parsers Tree-sitter

```bash
# Instalar parsers desde Neovim
# :TSInstall abap
# :TSInstall cds
```

O desde el script:
```bash
chmod +x ~/Desktop/sap-nvim/scripts/setup-treesitter.sh
./~/Desktop/sap-nvim/scripts/setup-treesitter.sh
```

## Paso 2: Servidores LSP

```bash
# abaplint (validación ABAP)
npm install -g abaplint

# CDS LSP (Core Data Services)
npm install -g @sap/cds-lsp
```

Verificar instalación:
```bash
abaplint --version
cds-lsp --version
```

## Paso 3: Cliente ADT

### sapcli (Python)
```bash
pip install sapcli
# o
pipx install sapcli
```

### abap-adt-api (Node.js)
```bash
npm install -g abap-adt-api
```

## Paso 4: Servidores MCP

### ARC-1
```bash
git clone https://github.com/marianfoo/arc-1.git
cd arc-1
npm install
# Configurar conexión SAP en .env
```

### mcp-abap-adt-api
```bash
git clone https://github.com/mario-andreschak/mcp-abap-abap-adt-api.git
cd mcp-abap-abap-adt-api
npm install
```

## Paso 5: Configuración de Neovim

### Con LazyVim (recomendado)

Añadir a `~/.config/nvim/lua/plugins/sap.lua`:

```lua
return {
  -- Este plugin
  dir = "~/Desktop/sap-nvim",

  -- Tree-sitter parsers
  {
    "nvim-treesitter/nvim-treesitter",
    opts = function(_, opts)
      vim.list_extend(opts.ensure_installed, {})
    end,
  },

  -- MCP Hub
  {
    "ravitemer/mcphub.nvim",
    dependencies = { "nvim-lua/plenary.nvim" },
    opts = {
      servers = {
        {
          name = "arc-1",
          cmd = { "node", "~/arc-1/server.js" },
        },
      },
    },
  },

  -- Avante (alternativa MCP)
  {
    "yetone/avante.nvim",
    opts = {
      provider = "claude",
      -- ... configuración existente
    },
  },
}
```

## Verificación

```bash
# Probar abaplint
echo "REPORT ztest." | abaplint --format json

# Probar sapcli
sapcli --help

# Probar MCP
node ~/arc-1/server.js --help
```
