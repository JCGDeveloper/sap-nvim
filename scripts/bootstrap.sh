#!/usr/bin/env bash
#===============================================================================
# nvim-abap-config — Bootstrap
# Instalación completa del entorno Neovim para desarrollo ABAP
# Inspirado en Gentlemen Programming — one script, zero friction
#
# Uso: curl -fsSL https://raw.githubusercontent.com/JCGDeveloper/sap-nvim/main/scripts/bootstrap.sh | bash
#      O: git clone https://github.com/JCGDeveloper/sap-nvim.git && cd sap-nvim && bash scripts/bootstrap.sh
#
# Soporte:
#   - macOS (Apple Silicon / Intel)    → Homebrew
#   - Linux (Debian/Ubuntu)            → apt
#   - Linux (Fedora/RHEL)              → dnf
#   - Linux (Arch/Manjaro)             → pacman
#   - WSL2                             → detectado como Linux
#===============================================================================

set -euo pipefail

# ─── Configuración ──────────────────────────────────────────────────────────

# Optional dev clone location; override with SAP_NVIM_DIR=... if you want it elsewhere.
# Not required for the lazy.nvim install — lazy pulls the plugin from GitHub directly.
SAP_NVIM_DIR="${SAP_NVIM_DIR:-$HOME/sap-nvim}"
NVIM_CONFIG_DIR="$HOME/.config/nvim"
SAPCLI_CONFIG_DIR="$HOME/.sapcli"
REPO_URL="https://github.com/JCGDeveloper/sap-nvim.git"
NVIM_VERSION_MIN="0.10"

# Colores
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Detectar SO ───────────────────────────────────────────────────────────

detect_os() {
  case "$(uname -s)" in
    Darwin*)  echo "macos" ;;
    Linux*)   echo "linux" ;;
    *)        echo "unknown" ;;
  esac
}

detect_distro() {
  if [ -f /etc/os-release ]; then
    . /etc/os-release
    echo "$ID"
  elif [ -f /etc/debian_version ]; then
    echo "debian"
  elif [ -f /etc/fedora-release ]; then
    echo "fedora"
  elif [ -f /etc/arch-release ]; then
    echo "arch"
  else
    echo "unknown"
  fi
}

OS=$(detect_os)
DISTRO=$(detect_distro)
ARCH=$(uname -m)

# ─── Funciones utilitarias ─────────────────────────────────────────────────

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✘${NC} $1"; }
header(){ echo -e "\n${BOLD}$1${NC}\n$(printf '═%.0s' $(seq 1 ${#1}))"; }

cmd_exists() { command -v "$1" &>/dev/null; }

# ─── Gestor de paquetes ────────────────────────────────────────────────────

PKG_MANAGER=""
PKG_INSTALL=""
PKG_UPDATE=""

setup_pkg_manager() {
  case "$OS" in
    macos)
      if cmd_exists brew; then
        PKG_MANAGER="brew"
        PKG_INSTALL="brew install"
        PKG_UPDATE="brew update"
        ok "Homebrew detectado"
      else
        info "Instalando Homebrew..."
        /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)"
        if [ "$ARCH" = "arm64" ]; then
          eval "$(/opt/homebrew/bin/brew shellenv)"
        fi
        PKG_MANAGER="brew"
        PKG_INSTALL="brew install"
        PKG_UPDATE="brew update"
        ok "Homebrew instalado"
      fi
      ;;
    linux)
      case "$DISTRO" in
        ubuntu|debian|linuxmint|pop)
          PKG_MANAGER="apt"
          PKG_INSTALL="sudo apt-get install -y"
          PKG_UPDATE="sudo apt-get update"
          ;;
        fedora|rhel|centos)
          PKG_MANAGER="dnf"
          PKG_INSTALL="sudo dnf install -y"
          PKG_UPDATE="sudo dnf check-update || true"
          ;;
        arch|manjaro|endeavouros)
          PKG_MANAGER="pacman"
          PKG_INSTALL="sudo pacman -S --noconfirm"
          PKG_UPDATE="sudo pacman -Sy"
          ;;
        *)
          err "Distribución Linux no detectada: $DISTRO"
          echo "  Instala manualmente: neovim, git, nodejs, npm, python3, pip"
          echo "  Luego ejecuta de nuevo este script con --skip-packages"
          exit 1
          ;;
      esac
      ok "Gestor de paquetes: $PKG_MANAGER ($DISTRO)"
      ;;
    *)
      err "SO no soportado: $OS"
      echo "  Soporte: macOS, Linux (Debian/Ubuntu, Fedora, Arch)"
      exit 1
      ;;
  esac
}

pkg_install() {
  local pkg_name="$1"
  if [ "$PKG_MANAGER" = "brew" ]; then
    if brew list "$pkg_name" &>/dev/null; then
      return 0
    fi
  fi
  $PKG_INSTALL "$pkg_name"
}

# ─── Banner ─────────────────────────────────────────────────────────────────

clear
echo -e "${CYAN}${BOLD}"
echo '  ╔══════════════════════════════════════════════════════════╗'
echo '  ║           nvim-abap-config Bootstrap v1.0               ║'
echo '  ║    ABAP Development Environment for Neovim              ║'
echo '  ╚══════════════════════════════════════════════════════════╝'
echo -e "${NC}"
echo "  $(date '+%Y-%m-%d %H:%M')"
echo "  Sistema: $(uname -srm) | $DISTRO"
echo ""

# ─── Parsear flags ──────────────────────────────────────────────────────────

SKIP_PACKAGES=false
for arg in "$@"; do
  case "$arg" in
    --skip-packages) SKIP_PACKAGES=true ;;
    --help|-h)
      echo "Uso: bash bootstrap.sh [--skip-packages]"
      echo "  --skip-packages  Saltar instalación de paquetes del sistema"
      exit 0
      ;;
  esac
done

# ─── 1. Gestor de paquetes ──────────────────────────────────────────────────

header "[1/8] Gestor de paquetes"

if [ "$SKIP_PACKAGES" = false ]; then
  setup_pkg_manager
  info "Actualizando repositorios..."
  $PKG_UPDATE 2>/dev/null || true
else
  info "Modo --skip-packages: saltando instalación de paquetes"
fi

# ─── 2. Neovim ──────────────────────────────────────────────────────────────

header "[2/8] Neovim"

if cmd_exists nvim; then
  NVIM_VER=$(nvim --version | head -1 | grep -oE '[0-9]+\.[0-9]+')
  ok "Neovim v$NVIM_VER"
else
  info "Instalando Neovim..."
  case "$PKG_MANAGER" in
    brew) brew install neovim ;;
    apt)  sudo apt-get install -y neovim ;;
    dnf)  sudo dnf install -y neovim ;;
    pacman) sudo pacman -S --noconfirm neovim ;;
  esac
  ok "Neovim instalado"
fi

# ─── 3. Dependencias del sistema ────────────────────────────────────────────

header "[3/8] Dependencias del sistema"

install_pkg() {
  local pkg="$1"
  local brew_name="${2:-$pkg}"
  local apt_name="${3:-$pkg}"
  local dnf_name="${4:-$pkg}"
  local pacman_name="${5:-$pkg}"

  if cmd_exists "$pkg"; then
    ok "$pkg ya instalado"
    return 0
  fi

  info "Instalando $pkg..."
  case "$PKG_MANAGER" in
    brew) brew install "$brew_name" ;;
    apt)  sudo apt-get install -y "$apt_name" ;;
    dnf)  sudo dnf install -y "$dnf_name" ;;
    pacman) sudo pacman -S --noconfirm "$pacman_name" ;;
  esac
  ok "$pkg instalado"
}

if [ "$SKIP_PACKAGES" = false ]; then
  install_pkg "git"       "git"       "git"       "git"       "git"
  install_pkg "lazygit"   "lazygit"   "lazygit"   "lazygit"   "lazygit"
  install_pkg "fd"        "fd"        "fd-find"   "fd-find"   "fd"
  install_pkg "rg"        "ripgrep"   "ripgrep"   "ripgrep"   "ripgrep"

  # Compilador C: nvim-treesitter compila los parsers (abap, cds) desde fuente.
  # NO se necesita el CLI `tree-sitter` (no está en apt/dnf y solo sirve para
  # gramáticas custom). Lo que de verdad hace falta es un compilador C.
  if cmd_exists cc || cmd_exists gcc || cmd_exists clang; then
    ok "compilador C ya disponible"
  else
    info "Instalando compilador C (para compilar parsers tree-sitter)..."
    case "$PKG_MANAGER" in
      brew)   xcode-select --install 2>/dev/null || true ;;
      apt)    sudo apt-get install -y build-essential ;;
      dnf)    sudo dnf install -y gcc make ;;
      pacman) sudo pacman -S --noconfirm base-devel ;;
    esac
    ok "compilador C instalado"
  fi

  # efm-langserver es OPCIONAL: solo habilita el bridge de formato vía LSP.
  # No está en apt/dnf; si no se puede instalar, seguimos sin problema porque
  # el plugin ya formatea con su formatter nativo (<leader>aF).
  if cmd_exists efm-langserver; then
    ok "efm-langserver ya instalado (opcional)"
  else
    case "$PKG_MANAGER" in
      brew)   brew install efm-langserver || warn "efm-langserver no instalado (opcional)" ;;
      pacman) sudo pacman -S --noconfirm efm-langserver || warn "efm-langserver no instalado (opcional)" ;;
      *)      warn "efm-langserver es opcional y no está en $PKG_MANAGER — se omite (instalalo con 'go install github.com/mattn/efm-langserver@latest' si querés el bridge LSP de formato)" ;;
    esac
  fi
fi

# ─── 4. Node.js ─────────────────────────────────────────────────────────────

header "[4/8] Node.js y npm"

if cmd_exists node; then
  ok "Node.js $(node --version)"
else
  info "Instalando Node.js..."
  case "$PKG_MANAGER" in
    brew) brew install node ;;
    apt)  sudo apt-get install -y nodejs npm ;;
    dnf)  sudo dnf install -y nodejs ;;
    pacman) sudo pacman -S --noconfirm nodejs npm ;;
  esac
  ok "Node.js instalado"
fi

# ─── 5. Python ──────────────────────────────────────────────────────────────

header "[5/8] Python 3"

if cmd_exists python3; then
  ok "Python $(python3 --version | awk '{print $2}')"
else
  info "Instalando Python..."
  case "$PKG_MANAGER" in
    brew) brew install python ;;
    apt)  sudo apt-get install -y python3 python3-pip ;;
    dnf)  sudo dnf install -y python3 python3-pip ;;
    pacman) sudo pacman -S --noconfirm python python-pip ;;
  esac
  ok "Python instalado"
fi

# ─── 6. Herramientas ABAP ──────────────────────────────────────────────────

header "[6/8] Herramientas ABAP"

# 6.1 sapcli
if cmd_exists sapcli; then
  ok "sapcli $(sapcli --version 2>&1 | head -1)"
else
  info "Instalando sapcli..."
  pip3 install sapcli
  ok "sapcli instalado"
fi

# 6.2 abaplint
if cmd_exists abaplint; then
  ok "abaplint $(abaplint --version)"
else
  info "Instalando abaplint..."
  npm install -g abaplint
  ok "abaplint instalado"
fi

# 6.3 pyyaml (para sincronización)
python3 -c "import yaml" 2>/dev/null || pip3 install pyyaml

# ─── 7. sap-nvim ────────────────────────────────────────────────────────────

header "[7/8] sap-nvim (proyecto)"

if [ -d "$SAP_NVIM_DIR" ]; then
  ok "Proyecto ya existe en $SAP_NVIM_DIR"
  if [ -d "$SAP_NVIM_DIR/.git" ]; then
    info "Actualizando..."
    git -C "$SAP_NVIM_DIR" pull
    ok "Actualizado"
  fi
else
  info "Clonando proyecto..."
  git clone "$REPO_URL" "$SAP_NVIM_DIR" 2>/dev/null || {
    warn "No se pudo clonar. Crea el directorio manualmente."
    mkdir -p "$SAP_NVIM_DIR"
  }
fi

# ─── 8. Configuración Neovim (NO destructiva) ───────────────────────────────
#
# REGLA DE ORO: este paso NUNCA sobrescribe una configuración de Neovim
# existente. Si ya tenés LazyVim u otra config, solo se añade el spec del
# plugin en lua/plugins/sap-nvim.lua (lazy.nvim lo carga solo). Tu init.lua
# y el resto de tu configuración quedan intactos.

header "[8/8] Configuración Neovim"

PLUGIN_SPEC="$NVIM_CONFIG_DIR/lua/plugins/sap-nvim.lua"

write_plugin_spec() {
  mkdir -p "$NVIM_CONFIG_DIR/lua/plugins"
  cat > "$PLUGIN_SPEC" << 'PLUGINEOF'
return {
  "JCGDeveloper/sap-nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
  },
  -- The plugin module is "sap-nvim"; lazy's `opts` would resolve the wrong
  -- main name ("sap"), so call setup() explicitly.
  config = function()
    require("sap-nvim").setup()
  end,
}
PLUGINEOF
}

if [ -f "$NVIM_CONFIG_DIR/init.lua" ]; then
  # Config existente → NO se toca. Solo se añade el spec del plugin.
  ok "Config de Neovim existente detectada en $NVIM_CONFIG_DIR — tu init.lua NO se toca"
  if [ -f "$PLUGIN_SPEC" ]; then
    ok "El spec del plugin ya existe ($PLUGIN_SPEC) — sin cambios"
  else
    info "Añadiendo solo lua/plugins/sap-nvim.lua (lazy.nvim lo detecta automáticamente)..."
    write_plugin_spec
    ok "Creado $PLUGIN_SPEC — el resto de tu configuración quedó intacto"
  fi
  warn "Si NO usás lazy.nvim, añadí el plugin con tu gestor a mano (ver README)."
else
  # No hay ninguna config → es seguro generar una mínima desde cero.
  info "No hay config de Neovim. Creando una mínima con lazy.nvim..."
  mkdir -p "$NVIM_CONFIG_DIR/lua/plugins"

  cat > "$NVIM_CONFIG_DIR/init.lua" << 'LUAEOF'
-- sap-nvim — bootstrap lazy.nvim (config mínima generada porque no existía ninguna)
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
  vim.fn.system({
    "git", "clone", "--filter=blob:none",
    "https://github.com/folke/lazy.nvim.git",
    "--branch=stable", lazypath,
  })
end
vim.opt.rtp:prepend(lazypath)

vim.opt.timeoutlen = 1000
vim.opt.ttimeoutlen = 0

require("lazy").setup("plugins", {
  change_detection = { notify = false },
})
LUAEOF

  write_plugin_spec
  ok "Configuración mínima creada (no se sobrescribió nada: no existía)"
fi

# ─── Tree-sitter parsers ──────────────────────────────────────────────────

header "[Extra] Tree-sitter ABAP + CDS"

if cmd_exists nvim; then
  info "Instalando parsers vía Neovim headless..."
  nvim --headless "+TSInstallSync abap" "+TSInstallSync cds" +qa 2>/dev/null && \
    ok "Parsers tree-sitter instalados" || \
    warn "Pendiente: nvim +TSInstallSync abap (puede requerir interfaz gráfica)"
else
  warn "Neovim no instalado, no se pueden instalar parsers"
fi

# ─── pbzip (validación) ─────────────────────────────────────────────────────

header "📋 VALIDACIÓN FINAL"

ERRORS=0

validate_cmd() {
  local name="$1" label="${2:-$1}"
  if cmd_exists "$name"; then
    echo -e "    ${GREEN}✔${NC} $label"
  else
    echo -e "    ${RED}✘${NC} $label NO INSTALADO"
    ERRORS=$((ERRORS + 1))
  fi
}

echo ""
echo "  ${BOLD}Editor:${NC}"
validate_cmd nvim "Neovim"

validate_optional() {
  local name="$1" label="${2:-$1}"
  if cmd_exists "$name"; then
    echo -e "    ${GREEN}✔${NC} $label"
  else
    echo -e "    ${YELLOW}⚠${NC} $label: opcional, no instalado"
  fi
}

echo ""
echo "  ${BOLD}Dependencias:${NC}"
validate_cmd git; validate_cmd lazygit; validate_cmd rg "ripgrep"
if cmd_exists cc || cmd_exists gcc || cmd_exists clang; then
  echo -e "    ${GREEN}✔${NC} compilador C"
else
  echo -e "    ${RED}✘${NC} compilador C NO INSTALADO"; ERRORS=$((ERRORS + 1))
fi
validate_optional efm-langserver "efm-langserver"
validate_cmd node "Node.js"; validate_cmd npm; validate_cmd python3 "Python 3"

echo ""
echo "  ${BOLD}Herramientas ABAP:${NC}"
validate_cmd sapcli; validate_cmd abaplint

echo ""
echo "  ${BOLD}Proyecto sap-nvim:${NC}"
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
[ -f "$NVIM_CONFIG_DIR/init.lua" ] && echo -e "    ${GREEN}✔${NC} init.lua" || { echo -e "    ${RED}✘${NC} init.lua FALTA"; ERRORS=$((ERRORS + 1)); }
[ -f "$NVIM_CONFIG_DIR/lua/plugins/sap-nvim.lua" ] && echo -e "    ${GREEN}✔${NC} Plugin sap-nvim" || { echo -e "    ${RED}✘${NC} Plugin sap-nvim FALTA"; ERRORS=$((ERRORS + 1)); }

echo ""
echo "  ${BOLD}Tree-sitter parsers:${NC}"
TS_BASE="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter"
[ -f "$TS_BASE/abap/parser.so" ] && echo -e "    ${GREEN}✔${NC} tree-sitter-abap" || echo -e "    ${YELLOW}⚠${NC} tree-sitter-abap: pendiente"
[ -f "$TS_BASE/cds/parser.so" ] && echo -e "    ${GREEN}✔${NC} tree-sitter-cds" || echo -e "    ${YELLOW}⚠${NC} tree-sitter-cds: pendiente"

echo ""
echo "  ${BOLD}Conexión SAP:${NC}"
[ -f "$SAPCLI_CONFIG_DIR/config.yml" ] && echo -e "    ${GREEN}✔${NC} ~/.sapcli/config.yml" || echo -e "    ${YELLOW}⚠${NC} No configurado (nvim +SapSetup)"

# ─── Resultado ─────────────────────────────────────────────────────────────

echo ""
echo "═══════════════════════════════════════════════════════"
if [ $ERRORS -eq 0 ]; then
  echo -e "  ${GREEN}${BOLD}✅ Todo listo!${NC} ($OS/$ARCH)"
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
  echo "  Revisa los mensajes de arriba."
fi
echo "═══════════════════════════════════════════════════════"
