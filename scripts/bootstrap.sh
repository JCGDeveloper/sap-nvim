#!/usr/bin/env bash
#===============================================================================
# sap-nvim Bootstrap
# Instalación completa del entorno Neovim para desarrollo ABAP
# Inspirado en Gentlemen Programming — one script, zero friction
#
# Uso: curl -fsSL https://raw.githubusercontent.com/.../bootstrap.sh | bash
#      O local: bash scripts/bootstrap.sh
#
# Soporte: macOS (Apple Silicon / Intel)
#===============================================================================

set -euo pipefail

# ─── Configuración ──────────────────────────────────────────────────────────

SAP_NVIM_DIR="$HOME/Desktop/sap-nvim"
NVIM_CONFIG_DIR="$HOME/.config/nvim"
SAPCLI_CONFIG_DIR="$HOME/.sapcli"
REPO_URL="https://github.com/JoaquinCarrasco/sap-nvim.git"
NVIM_VERSION_MIN="0.10"

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Funciones utilitarias ─────────────────────────────────────────────────

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✘${NC} $1"; }
header(){ echo -e "\n${BOLD}$1${NC}\n$(printf '═%.0s' $(seq 1 ${#1}))"; }
check() { if [ $? -eq 0 ]; then ok "$1"; else err "$1"; fi; }

cmd_exists() { command -v "$1" &>/dev/null; }

# ─── Banner ─────────────────────────────────────────────────────────────────

clear
echo -e "${CYAN}${BOLD}"
echo '  ╔══════════════════════════════════════════════════════════╗'
echo '  ║              sap-nvim Bootstrap v1.0                    ║'
echo '  ║    ABAP Development Environment for Neovim              ║'
echo '  ╚══════════════════════════════════════════════════════════╝'
echo -e "${NC}"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "  Sistema: $(uname -srm)"
echo ""

# ─── 1. Homebrew ────────────────────────────────────────────────────────────

header "[1/8] Package Manager (Homebrew)"

if cmd_exists brew; then
  ok "Homebrew $(brew --version | head -1 | awk '{print $2}')"
else
  info "Instalando Homebrew..."
  /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
  check "Homebrew instalado"
fi

# ─── 2. Neovim ──────────────────────────────────────────────────────────────

header "[2/8] Neovim"

if cmd_exists nvim; then
  NVIM_VER=$(nvim --version | head -1 | grep -oE '[0-9]+\.[0-9]+')
  ok "Neovim v$NVIM_VER"
else
  info "Instalando Neovim..."
  brew install neovim
  check "Neovim instalado"
fi

# ─── 3. Dependencias del sistema ────────────────────────────────────────────

header "[3/8] Dependencias del sistema"

BREW_PKGS=(
  git lazygit fd ripgrep tree-sitter efm-langserver
)
BREW_TO_INSTALL=()

for pkg in "${BREW_PKGS[@]}"; do
  if brew list "$pkg" &>/dev/null; then
    ok "$pkg ya instalado"
  else
    warn "$pkg pendiente"
    BREW_TO_INSTALL+=("$pkg")
  fi
done

if [ ${#BREW_TO_INSTALL[@]} -gt 0 ]; then
  info "Instalando: ${BREW_TO_INSTALL[*]}..."
  brew install "${BREW_TO_INSTALL[@]}"
  ok "Dependencias instaladas"
fi

# ─── 4. Node.js y npm ───────────────────────────────────────────────────────

header "[4/8] Node.js y npm"

if cmd_exists node; then
  ok "Node.js $(node --version)"
else
  info "Instalando Node.js..."
  brew install node
  check "Node.js instalado"
fi

if cmd_exists npm; then
  ok "npm $(npm --version)"
fi

# ─── 5. Python y pip ──────────────────────────────────────────────────────────

header "[5/8] Python y pip"

if cmd_exists python3; then
  ok "Python $(python3 --version | awk '{print $2}')"
fi

if cmd_exists pip3; then
  ok "pip $(pip3 --version | awk '{print $2}' | cut -d. -f1-3)"
fi

# ─── 6. Herramientas ABAP ──────────────────────────────────────────────────

header "[6/8] Herramientas ABAP"

# 6.1 sapcli
if cmd_exists sapcli; then
  ok "sapcli $(sapcli --version 2>&1 | head -1)"
else
  info "Instalando sapcli..."
  pip3 install sapcli
  check "sapcli instalado"
fi

# 6.2 abaplint
if cmd_exists abaplint; then
  ok "abaplint $(abaplint --version)"
else
  info "Instalando abaplint..."
  npm install -g abaplint
  check "abaplint instalado"
fi

# 6.3 efm-langserver (ya debería estar de brew)
if cmd_exists efm-langserver; then
  ok "efm-langserver $(efm-langserver -v 2>&1 | head -1)"
fi

# ─── 7. sap-nvim ────────────────────────────────────────────────────────────

header "[7/8] sap-nvim (proyecto)"

if [ -d "$SAP_NVIM_DIR" ]; then
  ok "Proyecto ya existe en $SAP_NVIM_DIR"
  if [ -d "$SAP_NVIM_DIR/.git" ]; then
    info "Actualizando..."
    cd "$SAP_NVIM_DIR" && git pull
    check "Actualización"
  fi
else
  info "Clonando proyecto..."
  if cmd_exists git; then
    git clone "$REPO_URL" "$SAP_NVIM_DIR" 2>/dev/null || {
      warn "No se pudo clonar. Creando directorio manual..."
      mkdir -p "$SAP_NVIM_DIR"
    }
  fi
fi

# ─── 8. Configuración Neovim ────────────────────────────────────────────────

header "[8/8] Configuración Neovim"

# Crear directorio si no existe
mkdir -p "$NVIM_CONFIG_DIR/lua/plugins"

# init.lua (solo si no existe)
if [ ! -f "$NVIM_CONFIG_DIR/init.lua" ]; then
  info "Creando init.lua..."
  cat > "$NVIM_CONFIG_DIR/init.lua" << 'LUAEOF'
-- bootstrap lazy.nvim
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not vim.loop.fs_stat(lazypath) then
  vim.fn.system({
    "git",
    "clone",
    "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable",
    lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

require("config.nodejs").setup({ silent = true })

require("lazy").setup("plugins", {
  defaults = { lazy = true },
  install = { colorscheme = { "catppuccin" } },
  change_detection = { notify = false },
})

vim.opt.timeoutlen = 1000
vim.opt.ttimeoutlen = 0
LUAEOF
  ok "init.lua creado"
else
  ok "init.lua ya existe"
fi

# nodejs config helper
mkdir -p "$NVIM_CONFIG_DIR/lua/config"
if [ ! -f "$NVIM_CONFIG_DIR/lua/config/nodejs.lua" ]; then
  cat > "$NVIM_CONFIG_DIR/lua/config/nodejs.lua" << 'LUAEOF'
local M = {}
function M.setup(opts)
  opts = opts or {}
  if opts.silent ~= true then
    local ok, err = pcall(function()
      local node = vim.fn.system("which node 2>/dev/null"):gsub("%s+", "")
      if node ~= "" then
        vim.g.node_host_prog = node
      end
    end)
    if not ok then
      vim.notify("node not found", vim.log.levels.WARN)
    end
  end
end
return M
LUAEOF
  ok "config/nodejs.lua creado"
fi

# lazyvim.json
if [ ! -f "$NVIM_CONFIG_DIR/lazyvim.json" ]; then
  cat > "$NVIM_CONFIG_DIR/lazyvim.json" << 'JSONEOF'
{
  "version": 2,
  "colorscheme": "catppuccin"
}
JSONEOF
  ok "lazyvim.json creado"
fi

# Plugin: sap-nvim
if [ ! -f "$NVIM_CONFIG_DIR/lua/plugins/sap-nvim.lua" ]; then
  cat > "$NVIM_CONFIG_DIR/lua/plugins/sap-nvim.lua" << 'LUAEOF'
-- sap-nvim — Plugin para desarrollo ABAP en Neovim
return {
  dir = vim.fn.expand("~/Desktop/sap-nvim"),
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "nvim-treesitter/nvim-treesitter-textobjects",
    "neovim/nvim-lspconfig",
  },
  opts = {},
}
LUAEOF
  ok "Plugin sap-nvim configurado"
else
  ok "Plugin sap-nvim ya configurado"
fi

# ─── Tree-sitter parsers ──────────────────────────────────────────────────

header "[Extra] Tree-sitter ABAP + CDS"

info "Instalando parsers (vía Neovim headless)..."
nvim --headless "+TSInstallSync abap" "+TSInstallSync cds" +qa 2>/dev/null && \
  ok "Parsers instalados" || warn "Ejecuta manualmente: nvim +TSInstallSync abap"

# ─── efm-langserver config ────────────────────────────────────────────────

header "[Extra] efm-langserver"

if [ -f "$SAP_NVIM_DIR/config/efm-langserver.yaml" ]; then
  ok "Config efm-langserver encontrada"
else
  warn "No se encontró config/efm-langserver.yaml"
fi

# ─── Validación final ─────────────────────────────────────────────────────

header "📋 VALIDACIÓN FINAL"

ERRORS=0

echo ""
echo "  ${BOLD}Neovim:${NC}"
if cmd_exists nvim; then
  echo -e "    ${GREEN}✔${NC} nvim $(nvim --version | head -1 | awk '{print $1" "$2}')"
else
  echo -e "    ${RED}✘${NC} nvim NO INSTALADO"
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "  ${BOLD}Dependencias:${NC}"
for cmd in git lazygit fd rg tree-sitter efm-langserver node npm python3; do
  if cmd_exists "$cmd"; then
    echo -e "    ${GREEN}✔${NC} $cmd"
  else
    echo -e "    ${RED}✘${NC} $cmd NO INSTALADO"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "  ${BOLD}Herramientas ABAP:${NC}"
for cmd in sapcli abaplint; do
  if cmd_exists "$cmd"; then
    echo -e "    ${GREEN}✔${NC} $cmd"
  else
    echo -e "    ${RED}✘${NC} $cmd NO INSTALADO"
    ERRORS=$((ERRORS + 1))
  fi
done

echo ""
echo "  ${BOLD}Proyecto:${NC}"
if [ -d "$SAP_NVIM_DIR" ]; then
  echo -e "    ${GREEN}✔${NC} sap-nvim: $SAP_NVIM_DIR"
  if [ -f "$SAP_NVIM_DIR/lua/sap-nvim/init.lua" ]; then
    echo -e "    ${GREEN}✔${NC} init.lua del proyecto"
  else
    echo -e "    ${RED}✘${NC} init.lua del proyecto FALTA"
    ERRORS=$((ERRORS + 1))
  fi
else
  echo -e "    ${RED}✘${NC} sap-nvim NO ENCONTRADO"
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "  ${BOLD}Config Neovim:${NC}"
if [ -f "$NVIM_CONFIG_DIR/init.lua" ]; then
  echo -e "    ${GREEN}✔${NC} init.lua"
else
  echo -e "    ${RED}✘${NC} init.lua FALTA"
  ERRORS=$((ERRORS + 1))
fi
if [ -f "$NVIM_CONFIG_DIR/lua/plugins/sap-nvim.lua" ]; then
  echo -e "    ${GREEN}✔${NC} Plugin sap-nvim"
else
  echo -e "    ${RED}✘${NC} Plugin sap-nvim FALTA"
  ERRORS=$((ERRORS + 1))
fi

echo ""
echo "  ${BOLD}Tree-sitter parsers:${NC}"
TS_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter"
if [ -f "$TS_DIR/abap/parser.so" ]; then
  echo -e "    ${GREEN}✔${NC} tree-sitter-abap"
else
  echo -e "    ${YELLOW}⚠${NC} tree-sitter-abap: pendiente (nvim +TSInstallSync abap)"
fi
if [ -f "$TS_DIR/cds/parser.so" ]; then
  echo -e "    ${GREEN}✔${NC} tree-sitter-cds"
else
  echo -e "    ${YELLOW}⚠${NC} tree-sitter-cds: pendiente (nvim +TSInstallSync cds)"
fi

echo ""
echo "  ${BOLD}Conexión SAP:${NC}"
if [ -f "$SAPCLI_CONFIG_DIR/config.yml" ]; then
  echo -e "    ${GREEN}✔${NC} ~/.sapcli/config.yml"
else
  echo -e "    ${YELLOW}⚠${NC} No configurado (nvim +SapSetup)"
fi

# ─── Resultado ─────────────────────────────────────────────────────────────

echo ""
echo "────────────────────────────────────────────────────"
if [ $ERRORS -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}✅ Todo listo!${NC} $ERRORS errores"
  echo ""
  echo "  Próximos pasos:"
  echo "  1. nvim +SapSetup     → Configurar conexión SAP"
  echo "  2. nvim               → Abrir Neovim y probar"
  echo "  3. <leader>an         → Crear nuevo objeto ABAP"
  echo "  4. <leader>asc        → Configurar conexiones"
  echo "  5. <leader>ah         → Ayuda de comandos"
  echo ""
  echo "  En un archivo .abap:"
  echo "    gd  → ir a definición"
  echo "    K   → hover"
  echo "    gr  → referencias"
  echo "    <leader>f → formatear"
  echo ""
else
  echo -e "  ${RED}${BOLD}❌ $ERRORS error(es) detectados${NC}"
  echo "  Revisa los mensajes de arriba e instala lo faltante."
fi
echo "────────────────────────────────────────────────────"
