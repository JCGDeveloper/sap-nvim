#!/bin/bash
# setup-mcp.sh
# Instalación de servidores MCP para SAP

set -e

echo "📦 Instalando servidores MCP para SAP ADT..."
MCP_DIR="$HOME/sap-mcp-servers"
mkdir -p "$MCP_DIR"

# Verificar Node.js
if ! command -v node &>/dev/null; then
  echo "❌ Node.js no encontrado."
  exit 1
fi

# --- ARC-1 ---
echo ""
echo "🔧 Instalando ARC-1 (servidor MCP seguro)..."
if [ -d "$MCP_DIR/arc-1" ]; then
  echo "   ARC-1 ya existe, actualizando..."
  cd "$MCP_DIR/arc-1" && git pull
else
  git clone https://github.com/marianfoo/arc-1.git "$MCP_DIR/arc-1"
  cd "$MCP_DIR/arc-1"
fi
npm install

# Copiar .env.example si no existe
if [ ! -f "$MCP_DIR/arc-1/.env" ]; then
  cp "$MCP_DIR/arc-1/.env.example" "$MCP_DIR/arc-1/.env" 2>/dev/null || true
  echo "   ⚠️  Configura tu conexión SAP en: $MCP_DIR/arc-1/.env"
fi

# --- mcp-abap-adt-api ---
echo ""
echo "🔧 Instalando mcp-abap-adt-api..."
if [ -d "$MCP_DIR/mcp-abap-adt-api" ]; then
  echo "   mcp-abap-adt-api ya existe, actualizando..."
  cd "$MCP_DIR/mcp-abap-adt-api" && git pull
else
  git clone https://github.com/mario-andreschak/mcp-abap-abap-adt-api.git "$MCP_DIR/mcp-abap-adt-api"
  cd "$MCP_DIR/mcp-abap-adt-api"
fi
npm install

echo ""
echo "✅ Servidores MCP instalados en: $MCP_DIR"
echo ""
echo "📋 Para configurar tus conexiones SAP:"
echo "   ARC-1:   $MCP_DIR/arc-1/.env"
echo "   abap-adt: Configurar variables de entorno"
echo ""
echo "🔌 Para conectar desde Neovim, añade a tu configuración:"
echo '   {
     name = "arc-1",
     cmd = { "node", "'"$MCP_DIR"'/arc-1/server.js" },
   }'
