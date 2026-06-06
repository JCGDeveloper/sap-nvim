# Guía de Instalación — sap-nvim

Esta guía amplía la sección **Instalación** del [README](../README.md) con el detalle
completo. Hay dos caminos: el **script automático** (Opción A) o la **instalación manual**
(Opción B). Ambos respetan tu configuración de Neovim existente: **no sobrescriben tu `init.lua`**.

---

## Prerrequisitos

| Herramienta | Versión mínima | Para qué |
|-------------|----------------|----------|
| Neovim | ≥ 0.9 | Host del plugin |
| Node.js + npm | ≥ 18 | abaplint |
| Python 3 + pip | ≥ 3.8 | sapcli |
| Compilador C (gcc/clang) | — | parsers de tree-sitter |

Verificá lo que ya tenés:

```bash
nvim --version
node --version
python3 --version
gcc --version || clang --version
```

---

## Opción A — Script automático

Para **WSL2**, Linux y macOS. Instala todo y añade el plugin **sin tocar tu config**.

```bash
git clone https://github.com/JCGDeveloper/sap-nvim.git ~/sap-nvim
bash ~/sap-nvim/scripts/bootstrap.sh
```

El script es **idempotente** (podés repetirlo sin romper nada) y **no destructivo**: si ya
tenés `~/.config/nvim/init.lua`, solo añade `~/.config/nvim/lua/plugins/sap-nvim.lua` y deja
el resto intacto. Si no tenés ninguna config, genera una mínima con lazy.nvim.

Flags:

```bash
bash ~/sap-nvim/scripts/bootstrap.sh --skip-packages   # no instala paquetes de sistema
bash ~/sap-nvim/scripts/bootstrap.sh --help
```

Lo que hace, en orden: gestor de paquetes → Neovim → deps de sistema (git, ripgrep, fd,
tree-sitter, efm-langserver) → Node.js → Python → sapcli + abaplint → spec del plugin
(no destructivo) → parsers tree-sitter (abap, cds) → validación final.

---

## Opción B — Manual, paso a paso

### Paso 1: Herramientas externas

```bash
# Linux / WSL2 (Ubuntu/Debian)
sudo apt update && sudo apt install -y neovim build-essential nodejs npm pipx

# macOS
brew install neovim node python pipx
```

```bash
# herramientas ABAP (nivel usuario, en cualquier SO)
pipx install sapcli                # cliente ADT (Python, vía pipx — PEP 668 safe)
npm install -g @abaplint/cli       # linter
```

Verificar:

```bash
sapcli --version
abaplint --version
```

### Paso 2: Añadir el plugin (lazy.nvim)

Creá `~/.config/nvim/lua/plugins/sap-nvim.lua` — **no toques tu `init.lua`**:

```lua
return {
  "JCGDeveloper/sap-nvim",
  dependencies = {
    "nvim-treesitter/nvim-treesitter",
    "neovim/nvim-lspconfig",
  },
  config = function()
    require("sap-nvim").setup()
  end,
}
```

lazy.nvim carga automáticamente cualquier archivo dentro de `lua/plugins/`. Reiniciá Neovim.

### Paso 3: Parsers tree-sitter

Dentro de Neovim:

```vim
:TSInstall abap cds
```

### Paso 4: Verificación

```vim
:checkhealth sap-nvim
```

Reporta cada dependencia con el comando exacto para arreglar lo que falte.

---

## Asistencia con IA (opcional)

Apagada por defecto. Usa **GitHub Copilot** (mismo backend y licencia que la extensión de
VSCode). Ver la sección [Asistencia con IA](../README.md#asistencia-con-ia-github-copilot)
del README. **No** se recomienda la integración directa con APIs externas (avante) en
entornos SAP corporativos: enviaría código ABAP fuera del canal aprobado por tu empresa.

---

## Siguiente paso

Con todo en verde, conectá a tu sistema SAP: `:SapSetup` → `:SapDoctor`.
Ver [Primeros pasos](../README.md#primeros-pasos--conectar-a-un-sistema-sap) y, en Windows,
[instalar bajo WSL2](../README.md#windows-instalar-bajo-wsl2).
