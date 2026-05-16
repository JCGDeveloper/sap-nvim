#!/bin/bash
# setup-treesitter.sh
# Instalación de parsers Tree-sitter para ABAP y CDS

set -e

echo "📦 Instalando parsers Tree-sitter para ABAP..."

# Verificar Neovim
if ! command -v nvim &>/dev/null; then
  echo "❌ Neovim no encontrado. Instálalo primero."
  exit 1
fi

# Verificar compilador C
if ! command -v gcc &>/dev/null && ! command -v clang &>/dev/null; then
  echo "❌ Compilador C no encontrado. Instala Xcode Command Line Tools:"
  echo "   xcode-select --install"
  exit 1
fi

# Instalar tree-sitter-abap
echo "🔧 Instalando tree-sitter-abap..."
git clone https://github.com/kennyhml/tree-sitter-abap.git /tmp/tree-sitter-abap 2>/dev/null || true
cd /tmp/tree-sitter-abap

# Compilar parser
gcc -shared -fPIC -o parser.so src/parser.c src/scanner.c 2>/dev/null || \
  clang -shared -fPIC -o parser.so src/parser.c src/scanner.c 2>/dev/null

# Copiar a la ubicación de Neovim
NVIM_PARSER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter/abap"
mkdir -p "$NVIM_PARSER_DIR"
cp parser.so "$NVIM_PARSER_DIR/" 2>/dev/null || echo "⚠️  Compilación manual necesaria. Ejecuta :TSInstall abap en Neovim"

# tree-sitter-cds
echo "🔧 Instalando tree-sitter-cds..."
git clone https://github.com/cap-js-community/tree-sitter-cds.git /tmp/tree-sitter-cds 2>/dev/null || true
cd /tmp/tree-sitter-cds

gcc -shared -fPIC -o parser.so src/parser.c src/scanner.c 2>/dev/null || \
  clang -shared -fPIC -o parser.so src/parser.c src/scanner.c 2>/dev/null

NVIM_PARSER_DIR="${XDG_DATA_HOME:-$HOME/.local/share}/nvim/treesitter/cds"
mkdir -p "$NVIM_PARSER_DIR"
cp parser.so "$NVIM_PARSER_DIR/" 2>/dev/null || echo "⚠️  Compilación manual necesaria. Ejecuta :TSInstall cds en Neovim"

echo ""
echo "✅ Parsers instalados. Abre Neovim y verifica con:"
echo "   :TSModuleInfo abap"
echo "   :TSModuleInfo cds"
