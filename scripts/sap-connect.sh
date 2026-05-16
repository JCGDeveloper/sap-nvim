#!/bin/bash
# sap-connect.sh
# Script de conexión y prueba de SAP ADT

CONFIG_FILE="$HOME/Desktop/sap-nvim/config/sap-connections.json"

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

# Verificar conexiones configuradas
echo ""
echo "📋 Conexiones SAP:"
if [ -f "$CONFIG_FILE" ]; then
  echo -e "${GREEN}✅${NC} Archivo de conexiones encontrado: $CONFIG_FILE"
  cat "$CONFIG_FILE" | python3 -m json.tool 2>/dev/null || cat "$CONFIG_FILE"
else
  echo -e "${YELLOW}⚠️ ${NC} No hay archivo de conexiones."
  echo "   Crea uno en: $CONFIG_FILE"
  echo "   Ejemplo:"
  echo '{
    "desarrollo": {
      "system_id": "D01",
      "host": "sap.example.com",
      "client": "100",
      "username": "$USER"
    }
  }'
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
echo "  1. nvim ~/Desktop/sap-nvim/"
echo "  2. Abre un archivo .abap"
echo "  3. Usa <leader>aa para activar en SAP"
echo "  4. Usa <leader>ac para ejecutar ATC"
