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

# Contador de errores acumulado durante TODO el script (no solo en la validación final),
# para que cosas como "Neovim demasiado viejo" cuenten como fallo real.
ERRORS=0

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

# Compara dos versiones "mayor.menor": ¿$1 >= $2?
version_ge() {
  [ "$(printf '%s\n%s\n' "$2" "$1" | sort -t. -k1,1n -k2,2n | head -1)" = "$2" ]
}

check_nvim_version() {
  local ver
  ver=$(nvim --version | head -1 | grep -oE '[0-9]+\.[0-9]+' | head -1)
  if [ -z "$ver" ]; then
    warn "No pude leer la versión de Neovim."
    return 0
  fi
  if version_ge "$ver" "$NVIM_VERSION_MIN"; then
    ok "Neovim v$ver (>= $NVIM_VERSION_MIN requerido)"
  else
    err "Neovim v$ver es DEMASIADO VIEJA — sap-nvim necesita >= $NVIM_VERSION_MIN."
    warn "Tu gestor ($PKG_MANAGER) trae una versión antigua. Instala una reciente:"
    case "$PKG_MANAGER" in
      apt)    warn "  sudo add-apt-repository ppa:neovim-ppa/unstable && sudo apt update && sudo apt install neovim";;
      dnf)    warn "  sudo dnf install -y neovim   (o el COPR de neovim si sigue vieja)";;
      pacman) warn "  sudo pacman -S neovim   (Arch suele estar al día)";;
      brew)   warn "  brew install neovim   (suele estar al día)";;
      *)      warn "  Descarga el AppImage oficial: https://github.com/neovim/neovim/releases";;
    esac
    warn "  Alternativa universal (AppImage): https://github.com/neovim/neovim/releases/latest"
    ERRORS=$((ERRORS + 1))
  fi
}

if cmd_exists nvim; then
  check_nvim_version
else
  info "Instalando Neovim..."
  case "$PKG_MANAGER" in
    brew) brew install neovim ;;
    apt)  sudo apt-get install -y neovim ;;
    dnf)  sudo dnf install -y neovim ;;
    pacman) sudo pacman -S --noconfirm neovim ;;
  esac
  check_nvim_version
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

# pipx: forma correcta de instalar apps CLI de Python en entornos
# "externally-managed" (PEP 668). Aísla sapcli en su propio venv; un `pip3
# install` directo está bloqueado a propósito en Python moderno (Homebrew,
# Ubuntu/Debian recientes).
ensure_pipx() {
  if cmd_exists pipx; then
    ok "pipx ya instalado"
  else
    info "Instalando pipx..."
    case "$PKG_MANAGER" in
      brew)   brew install pipx ;;
      apt)    sudo apt-get install -y pipx ;;
      dnf)    sudo dnf install -y pipx ;;
      pacman) sudo pacman -S --noconfirm python-pipx ;;
    esac
  fi
  pipx ensurepath >/dev/null 2>&1 || true
  export PATH="$HOME/.local/bin:$PATH"   # disponible en ESTA sesión, hasta reabrir shell
}

# 6.1 sapcli — NO está en PyPI; se instala desde el repo git (vía pipx, PEP 668 safe)
if cmd_exists sapcli; then
  ok "sapcli $(sapcli --version 2>&1 | head -1)"
else
  ensure_pipx
  info "Instalando sapcli desde git (no está publicado en PyPI)..."
  pipx install git+https://github.com/jfilak/sapcli.git
  ok "sapcli instalado"
fi

# 6.2 abaplint (paquete @abaplint/cli — provee el binario `abaplint`)
if cmd_exists abaplint; then
  ok "abaplint $(abaplint --version)"
else
  info "Instalando abaplint..."
  npm install -g @abaplint/cli
  ok "abaplint instalado"
fi

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

# ─── IDE SAP aislado (config curado nvim-sap) ──────────────────────────────
#
# Instala el IDE COMPLETO como una config de Neovim APARTE (NVIM_APPNAME=nvim-sap):
# completado ADT, pickers, debugger, dashboard, tema… sin tocar tu nvim normal. Se
# lanza con el alias `nvim-sap`. Es lo que hace que "todo funcione" de una. Si ya
# existe ~/.config/nvim-sap, NO se sobrescribe.

NVIM_SAP_CONFIG="$HOME/.config/nvim-sap"
SAP_IDE_SRC="$SAP_NVIM_DIR/extras/nvim-sap"

detect_shell_rc() {
  case "$(basename "${SHELL:-bash}")" in
    zsh)  echo "$HOME/.zshrc" ;;
    *)    echo "$HOME/.bashrc" ;;
  esac
}

add_sap_alias() {
  local rc; rc="$(detect_shell_rc)"
  touch "$rc"
  if grep -qF "NVIM_APPNAME=nvim-sap" "$rc" 2>/dev/null; then
    ok "Alias 'nvim-sap' ya presente en $(basename "$rc")"
  else
    printf "\n# sap-nvim — IDE SAP aislado\nalias nvim-sap='NVIM_APPNAME=nvim-sap nvim'\n" >> "$rc"
    ok "Alias 'nvim-sap' añadido a $(basename "$rc") (reabre la shell o 'source $rc')"
  fi
}

install_sap_ide() {
  if [ ! -d "$SAP_IDE_SRC" ]; then
    warn "No encuentro el config curado en $SAP_IDE_SRC (¿falló el clon del proyecto?). Salto el IDE."
    return 0
  fi
  if [ -d "$NVIM_SAP_CONFIG" ]; then
    ok "IDE SAP ya instalado en $NVIM_SAP_CONFIG — no se sobrescribe"
  else
    info "Instalando el IDE SAP aislado en $NVIM_SAP_CONFIG (config separada, no toca tu nvim)..."
    mkdir -p "$NVIM_SAP_CONFIG"
    cp -r "$SAP_IDE_SRC/init.lua" "$SAP_IDE_SRC/lua" "$NVIM_SAP_CONFIG/"
    ok "IDE SAP copiado. Primer arranque: 'nvim-sap' (lazy instala todo; espera y reinicia)."
  fi
  add_sap_alias
}

header "[Extra] IDE SAP aislado (nvim-sap)"
install_sap_ide

# ─── Tree-sitter parsers ──────────────────────────────────────────────────

header "[Extra] Tree-sitter ABAP + CDS"

# NOTA: arrancar nvim --headless con una config grande (LazyVim) dispara la
# instalación de TODOS los plugins en headless y puede COLGARSE. Por eso este
# paso es best-effort, con timeout, y NUNCA bloquea el script. Lo fiable es
# abrir Neovim normal una vez y correr `:TSInstall abap cds`.
TS_HINT="Abrí Neovim y corré:  :TSInstall abap cds"

if ! cmd_exists nvim; then
  warn "Neovim no instalado, no se pueden instalar parsers"
elif cmd_exists timeout; then
  info "Intentando instalar parsers vía Neovim headless (best-effort, máx 180s)..."
  if timeout 180 nvim --headless "+TSInstallSync abap" "+TSInstallSync cds" +qa >/dev/null 2>&1; then
    ok "Parsers tree-sitter instalados"
  else
    warn "No se pudieron instalar en headless (timeout o config interactiva). $TS_HINT"
  fi
else
  warn "Salteo la instalación headless (sin 'timeout' para evitar cuelgues). $TS_HINT"
fi

# ─── pbzip (validación) ─────────────────────────────────────────────────────

header "📋 VALIDACIÓN FINAL"

# ERRORS NO se reinicia aquí: ya viene acumulando desde arriba (p.ej. Neovim viejo).

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
  echo "  1. source ~/.zshrc (o reabre la terminal)  → activa el alias 'nvim-sap'"
  echo "  2. nvim-sap           → IDE SAP completo (1ª vez: lazy instala todo, espera y reinicia)"
  echo "  3. :SapSetup          → Configurar conexión SAP (dentro de nvim-sap)"
  echo "  4. <leader>an         → Crear nuevo objeto ABAP"
  echo "  5. <leader>ah         → Ayuda de comandos"
  echo ""
  echo "  (El IDE 'nvim-sap' es una config aislada y NO toca tu Neovim normal.)"
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
