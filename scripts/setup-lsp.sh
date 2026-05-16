#!/bin/bash
# setup-lsp.sh
# Instalación de servidores LSP para ABAP

set -e

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
}' > ~/Desktop/sap-nvim/config/abaplint.json
echo "   → Creado en ~/Desktop/sap-nvim/config/abaplint.json"
