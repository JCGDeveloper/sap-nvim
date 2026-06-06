#!/bin/bash
# sap-connect.sh
# Script de conexión y prueba de SAP ADT

# Single source of truth for SAP connections is sapcli's own config.
SAPCLI_CONFIG="$HOME/.sapcli/config.yml"

# Colores
GREEN='\033[0;32m'
RED='\033[0;31m'
YELLOW='\033[1;33m'
NC='\033[0m'

echo "🔌 sap-nvim: Verificación de conexión SAP ADT"
echo "============================================"

# Verificar herramientas
check_tool() {
  if command -v "$1" &>/dev/null; then
    echo -e "${GREEN}✅${NC} $1: $(command -v $1)"
  else
    echo -e "${RED}❌${NC} $1: NO INSTALADO"
    MISSING="$MISSING $1"
  fi
}

echo ""
echo "📋 Herramientas instaladas:"
check_tool abaplint
check_tool sapcli
check_tool node

# Verificar parsers tree-sitter
echo ""
echo "📋 Parsers Tree-sitter:"
if [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter/abap/parser.so" ]; then
  echo -e "${GREEN}✅${NC} tree-sitter-abap: Instalado"
else
  echo -e "${RED}❌${NC} tree-sitter-abap: No instalado (ejecuta setup-treesitter.sh)"
fi

if [ -f "${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter/cds/parser.so" ]; then
  echo -e "${GREEN}✅${NC} tree-sitter-cds: Instalado"
else
  echo -e "${YELLOW}⚠️ ${NC} tree-sitter-cds: No instalado"
fi

# Verificar conexiones configuradas (fuente de verdad: sapcli config.yml)
echo ""
echo "📋 Conexiones SAP:"
if [ -f "$SAPCLI_CONFIG" ]; then
  echo -e "${GREEN}✅${NC} sapcli config encontrado: $SAPCLI_CONFIG"
  sapcli config get-contexts 2>/dev/null || true
else
  echo -e "${YELLOW}⚠️ ${NC} No hay conexión configurada."
  echo "   Configurala con sapcli (estilo kubeconfig):"
  echo "     sapcli config set-connection dev --ashost HOST --port 44300 --client 100 --ssl"
  echo "     sapcli config set-user me --user SAPUSER --password ****"
  echo "     sapcli config set-context dev --connection dev --user me"
  echo "     sapcli config use-context dev"
fi

# Probar abaplint
echo ""
echo "📋 Prueba de abaplint:"
echo "REPORT ztest." | abaplint --format json 2>/dev/null && \
  echo -e "${GREEN}✅${NC} abaplint funciona correctamente" || \
  echo -e "${RED}❌${NC} Error en abaplint"

echo ""
echo "============================================"
echo "Para empezar a desarrollar:"
echo "  1. :checkhealth sap-nvim   → verificar dependencias y conexión"
echo "  2. Abre un archivo .abap"
echo "  3. <leader>aa para activar en SAP"
echo "  4. <leader>aK para ejecutar ATC"
