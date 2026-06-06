#!/bin/bash
# setup-lsp.sh
# Instalación de servidores LSP para ABAP

set -e

# Resolve repo root from this script's own location (scripts/ is one level down).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_DIR="$(dirname "$SCRIPT_DIR")"

echo "📦 Instalando servidores LSP para ABAP..."

# Verificar Node.js
if ! command -v node &>/dev/null; then
  echo "❌ Node.js no encontrado. Instálalo primero:"
  echo "   brew install node"
  exit 1
fi

# abaplint
echo "🔧 Instalando abaplint..."
npm install -g abaplint
echo "   ✅ abaplint $(abaplint --version 2>/dev/null || echo 'instalado')"

# CDS LSP
echo "🔧 Instalando CDS LSP..."
npm install -g @sap/cds-lsp
echo "   ✅ CDS LSP instalado"

# Verificar instalaciones
echo ""
echo "✅ LSPs instalados. Verifica:"
echo "   abaplint --version"
echo "   cds-lsp --version"
echo ""
echo "📝 Configura tu abaplint.json:"
echo '{
  "global": {
    "files": "/**/*.abap"
  },
  "dependencies": [
    {
      "url": "https://raw.githubusercontent.com/SAP/styleguides/main/clean-abap/CleanABAP.json"
    }
  ]
}' > "$REPO_DIR/config/abaplint.json"
echo "   → Creado en $REPO_DIR/config/abaplint.json"
