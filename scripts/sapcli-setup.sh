#!/usr/bin/env bash
#===============================================================================
# sapcli-setup.sh — Configuración interactiva de sapcli
# Parte del proyecto sap-nvim (https://github.com/JCGDeveloper/sap-nvim)
#
# Uso: ./scripts/sapcli-setup.sh
#   Crea/edita ~/.sapcli/config.yml con asistente interactivo.
#   Soporta múltiples contextos (conexiones a distintos sistemas SAP).
#
# ¿Nueva máquina? Copia este script, ejecútalo y configura en 2 minutos.
#===============================================================================

set -euo pipefail

SAPCLI_DIR="$HOME/.sapcli"
CONFIG_FILE="$SAPCLI_DIR/config.yml"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PROJECT_DIR="$(cd "$SCRIPT_DIR/.." && pwd)"
NVIM_SAPCONN_FILE="$PROJECT_DIR/config/sap-connections.json"

# ─── Colores ──────────────────────────────────────────────────────────────────
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'
CYAN='\033[0;36m'; BOLD='\033[1m'; NC='\033[0m'

# ─── Utilidades ───────────────────────────────────────────────────────────────

info()  { echo -e "${CYAN}ℹ${NC} $1"; }
ok()    { echo -e "${GREEN}✔${NC} $1"; }
warn()  { echo -e "${YELLOW}⚠${NC} $1"; }
err()   { echo -e "${RED}✘${NC} $1"; }
header(){ echo -e "\n${BOLD}$1${NC}\n$(printf '─%.0s' $(seq 1 ${#1}))"; }

prompt() {
  local var_name="$1" prompt_text="$2" default="${3:-}"
  local value
  if [ -n "$default" ]; then
    read -rp "$(echo -e "${CYAN}?${NC} $prompt_text [${default}]: ")" value
    value="${value:-$default}"
  else
    read -rp "$(echo -e "${CYAN}?${NC} $prompt_text: ")" value
  fi
  eval "$var_name=\"$value\""
}

prompt_password() {
  local var_name="$1" prompt_text="$2"
  local value
  read -rsp "$(echo -e "${CYAN}?${NC} $prompt_text: ")" value
  echo
  eval "$var_name=\"$value\""
}

confirm() {
  local prompt_text="$1" default="${2:-n}"
  local yn
  if [ "$default" = "y" ]; then
    read -rp "$(echo -e "${YELLOW}?${NC} $prompt_text [Y/n]: ")" yn
    yn="${yn:-y}"
  else
    read -rp "$(echo -e "${YELLOW}?${NC} $prompt_text [y/N]: ")" yn
    yn="${yn:-n}"
  fi
  [ "$yn" = "y" ] || [ "$yn" = "Y" ]
}

# ─── Pantalla de bienvenida ──────────────────────────────────────────────────

clear
echo -e "${BOLD}${CYAN}"
echo '  ╔══════════════════════════════════════════════════╗'
echo '  ║           sap-nvim — sapcli Setup               ║'
echo '  ║    Configuración interactiva de conexiones SAP   ║'
echo '  ╚══════════════════════════════════════════════════╝'
echo -e "${NC}"
info "Proyecto: $PROJECT_DIR"
info "Fichero destino: $CONFIG_FILE"
echo ""

# ─── Verificar instalación de sapcli ─────────────────────────────────────────

if ! command -v sapcli &>/dev/null; then
  warn "sapcli no está instalado."
  if confirm "¿Quieres instalarlo ahora?"; then
    pip3 install sapcli
    if command -v sapcli &>/dev/null; then
      ok "sapcli instalado correctamente"
    else
      err "No se pudo instalar. Hazlo manualmente: pip3 install sapcli"
      exit 1
    fi
  else
    err "sapcli es necesario para continuar."
    exit 1
  fi
else
  ok "sapcli detectado: $(command -v sapcli)"
fi

# ─── Crear directorio si no existe ────────────────────────────────────────────

mkdir -p "$SAPCLI_DIR"

# ─── Cargar config existente si la hay ────────────────────────────────────────

declare -A EXISTING_CONTEXTS
CURRENT_CONTEXT=""

if [ -f "$CONFIG_FILE" ]; then
  info "Configuración existente detectada."
  echo ""
  
  # Extraer contextos del YAML (parseo básico)
  while IFS= read -r line; do
    if [[ "$line" =~ ^current-context:\ (.*) ]]; then
      CURRENT_CONTEXT="${BASH_REMATCH[1]}"
    fi
    if [[ "$line" =~ ^([a-zA-Z0-9_-]+):$ ]]; then
      EXISTING_CONTEXTS["${BASH_REMATCH[1]}"]="exists"
    fi
  done < "$CONFIG_FILE"
  
  if [ ${#EXISTING_CONTEXTS[@]} -gt 0 ]; then
    info "Contextos encontrados: ${!EXISTING_CONTEXTS[*]}"
    if [ -n "$CURRENT_CONTEXT" ]; then
      info "Contexto activo: $CURRENT_CONTEXT"
    fi
  fi

  if ! confirm "¿Quieres editar la configuración existente?" "y"; then
    ok "Configuración no modificada."
    exit 0
  fi
  echo ""
fi

# ─── Menú principal ──────────────────────────────────────────────────────────

header "MENÚ PRINCIPAL"
echo "  1) Configurar conexión nueva"
echo "  2) Editar conexión existente"
echo "  3) Ver configuración actual"
echo "  4) Probar conexión"
echo "  5) Eliminar configuración"
echo "  0) Salir"
echo ""

prompt option "Selecciona una opción" "1"

case "$option" in
  1) 
    # ─── Configurar nueva conexión ──────────────────────────────────────────
    header "NUEVA CONEXIÓN SAP"
    echo "Introduce los datos de conexión al sistema SAP."
    echo "Los campos marcados con * son obligatorios."
    echo ""

    prompt ctx_name      "Nombre del contexto (ej: desarrollo, calidad, prod)" "desarrollo"
    prompt ashost        "* Servidor (ashost/IP)"
    prompt sysnr         "* Nº de instancia (sysnr)" "00"
    prompt client        "* Cliente (MANDT)" "100"
    prompt port          "Puerto ADT" "443"
    prompt user          "* Usuario"
    prompt_password pass "* Contraseña"
    
    if confirm "¿Usar SSL?" "y"; then
      ssl="true"
    else
      ssl="false"
    fi

    if confirm "¿Este contexto será el activo por defecto?" "y"; then
      CURRENT_CONTEXT="$ctx_name"
    fi

    # ─── Escribir configuración ─────────────────────────────────────────────
    # Preservar contextos existentes si los hay
    if [ -f "$CONFIG_FILE" ]; then
      cp "$CONFIG_FILE" "${CONFIG_FILE}.bak"
      ok "Backup creado: ${CONFIG_FILE}.bak"
    fi

    # Construir nuevo config
    cat > "$CONFIG_FILE" << YAMLEOF
# sapcli configuration
# Generado por sap-nvim/sapcli-setup.sh
# Editado: $(date '+%Y-%m-%d %H:%M')

current-context: ${CURRENT_CONTEXT:-$ctx_name}

YAMLEOF

    # Añadir este contexto
    cat >> "$CONFIG_FILE" << YAMLEOF
$ctx_name:
  ashost: $ashost
  sysnr: $sysnr
  client: $client
  port: $port
  user: $user
  password: $pass
  ssl: $ssl
YAMLEOF

    ok "Contexto '$ctx_name' guardado en $CONFIG_FILE"
    ;;

  2)
    # ─── Editar conexión existente ─────────────────────────────────────────
    if [ ! -f "$CONFIG_FILE" ]; then
      err "No hay configuración existente. Selecciona opción 1 primero."
      exit 1
    fi
    
    info "Editando configuración directamente..."
    if command -v nano &>/dev/null; then
      nano "$CONFIG_FILE"
    elif command -v vim &>/dev/null; then
      vim "$CONFIG_FILE"
    elif command -v vi &>/dev/null; then
      vi "$CONFIG_FILE"
    else
      err "No se encontró un editor. Abre manualmente: $CONFIG_FILE"
    fi
    ;;

  3)
    # ─── Ver configuración ──────────────────────────────────────────────────
    if [ ! -f "$CONFIG_FILE" ]; then
      err "No hay configuración."
      exit 1
    fi
    echo ""
    header "CONFIGURACIÓN ACTUAL"
    cat "$CONFIG_FILE"
    echo ""
    ;;

  4)
    # ─── Probar conexión ───────────────────────────────────────────────────
    if [ ! -f "$CONFIG_FILE" ]; then
      err "No hay configuración. Selecciona opción 1 primero."
      exit 1
    fi

    header "PRUEBA DE CONEXIÓN"
    
    if [ -n "$CURRENT_CONTEXT" ]; then
      info "Probando contexto activo: $CURRENT_CONTEXT"
    fi

    set +e
    echo "→ sapcli --version"
    sapcli --version 2>&1
    echo ""
    
    echo "→ Buscando programa Z* (prueba de conexión de solo lectura)..."
    timeout 15 sapcli program list --search "Z*" 2>&1 || timeout 15 sapcli abap search "Z*" 2>&1 || warn "La conexión falló o no hay resultados."
    set -e
    ;;

  5)
    # ─── Eliminar configuración ────────────────────────────────────────────
    if confirm "¿Eliminar toda la configuración de sapcli?" "n"; then
      rm -f "$CONFIG_FILE"
      ok "Configuración eliminada."
    fi
    ;;

  0|*)
    ok "Saliendo sin cambios."
    exit 0
    ;;
esac

# ─── Sincronizar con sap-nvim ────────────────────────────────────────────────

echo ""
header "SINCRONIZAR CON SAP-NVIM"

if confirm "¿Quieres sincronizar esta conexión con sap-nvim (Neovim)?" "y"; then
  if [ -f "$CONFIG_FILE" ]; then
    # Extraer contextos del YAML y generar sap-connections.json
    python3 -c "
import yaml, json, os

config_path = os.path.expanduser('$CONFIG_FILE')
nvim_path = os.path.expanduser('$NVIM_SAPCONN_FILE')

try:
    with open(config_path) as f:
        config = yaml.safe_load(f)
except:
    config = {}

contexts = {}
current = config.get('current-context', '')
for key, val in config.items():
    if isinstance(val, dict) and 'ashost' in val:
        contexts[key] = {
            'ashost': val.get('ashost', ''),
            'sysnr': val.get('sysnr', '00'),
            'client': val.get('client', '100'),
            'port': val.get('port', 443),
            'user': val.get('user', ''),
            'ssl': val.get('ssl', True),
            'system_id': val.get('sysid', key.upper()[:3]),
            'description': val.get('description', f'Conexión {key}'),
        }

output = {
    'current': current,
    'connections': contexts,
}

os.makedirs(os.path.dirname(nvim_path), exist_ok=True)
with open(nvim_path, 'w') as f:
    json.dump(output, f, indent=2, ensure_ascii=False)
print(f'OK: {len(contexts)} conexiones sincronizadas')
"
    if [ -f "$NVIM_SAPCONN_FILE" ]; then
      ok "Neovim actualizado: $NVIM_SAPCONN_FILE"
      info "Desde Neovim usa <leader>a1..<leader>a5 para seleccionar conexión"
    fi
  fi
fi

# ─── Resumen final ────────────────────────────────────────────────────────────

echo ""
header "RESUMEN"
echo -e "  ${GREEN}✔${NC} sapcli:            $(command -v sapcli)"
echo -e "  ${GREEN}✔${NC} Configuración:     $CONFIG_FILE"
echo -e "  ${GREEN}✔${NC} Conexiones Neovim: $NVIM_SAPCONN_FILE"
echo ""
echo -e "  ${BOLD}Próximos pasos:${NC}"
echo "  1. Abre Neovim y prueba <leader>asg (abrir SAP GUI)"
echo "  2. En un archivo .abap, prueba <leader>aa (activar)"
echo "  3. Para más ayuda: <leader>ah"
echo "  4. Si cambias de máquina, solo copia este script y ejecútalo"
echo ""

# ─── Pregunta por múltiples contextos ────────────────────────────────────────

if confirm "¿Quieres configurar otra conexión (ej: calidad, producción)?" "n"; then
  echo ""
  exec "$0"  # Reiniciar el script
fi

ok "¡Todo listo! Disfruta de sap-nvim 🚀"
