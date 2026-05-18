# sap-nvim — Skill de Instalación y Configuración
## Arquitectura Avanzada para Desarrollo ABAP en Neovim

Este skill describe cómo configurar el ecosistema completo de desarrollo ABAP en Neovim, 
tanto en modo offline (tree-sitter + abaplint) como con conexión remota SAP (sapcli + MCP).

## Fases de Implementación

### FASE 1 — Tree-sitter ABAP + CDS
**Estado:** OFFLINE (sin conexión SAP)

**Objetivo:** Resaltado de sintaxis, textobjects, plegado de código

**Archivos:**
- Parser: `tree-sitter-abap` (kennyhml)
- Parser CDS: `tree-sitter-cds` (cap-js-community)
- Config Neovim: `lua/sap-nvim/core/treesitter.lua`

**Comandos:**
```bash
# Instalar parsers desde Neovim
:TSInstallSync abap
:TSInstallSync cds

# Verificar
:TSModuleInfo abap
:TSModuleInfo cds
```

**Checkpoints de seguridad:**
✅ No requiere conexión SAP
✅ No modifica nada en remoto
✅ 100% local

### FASE 2 — LSP (abaplint + CDS LSP)
**Estado:** OFFLINE (sin conexión SAP)

**Objetivo:** Validación sintáctica, formateo, diagnósticos

**Herramientas:**
- `abaplint` — Servidor LSP ABAP (Node.js)
- `@sap/cds-lsp` — Servidor LSP CDS (Node.js)

**Config Neovim:** `lua/sap-nvim/core/lsp.lua`

**Checkpoints de seguridad:**
✅ No requiere conexión SAP
✅ abaplint valida contra reglas locales
✅ Sin acceso a DDIC remoto (limitación conocida)

### FASE 3 — Preparar Conexión ADT
**Estado:** INSTALADO pero DESACTIVADO

**Objetivo:** Tener sapcli y abap-adt-api instalados, sin configurar conexión real

**Herramientas:**
- `sapcli` — CLI Python para ADT
- `abap-adt-api` — Biblioteca Node.js

**Config Neovim:** `lua/sap-nvim/core/adt.lua`

**Seguridad:**
⚠️ NO configurar conexión real hasta FASE 6
⚠️ `sapcli` solo ejecuta `--help` para verificar instalación
⚠️ Modo READ-ONLY por defecto

### FASE 4 — Servidores MCP
**Estado:** INSTALADO pero DESACTIVADO

**Objetivo:** Tener ARC-1 y mcp-abap-adt-api instalados

**Checkpoints:**
⚠️ No cargar en Neovim hasta FASE 6
⚠️ No configurar .env con datos reales hasta conexión

### FASE 5 — Atajos y Comandos
**Estado:** ACTIVO (sin conexión)

**Objetivo:** Tener todos los keymaps y comandos listos, 
pero sin conexión real configurada

### FASE 6 — Conexión Controlada (MODO SEGURO)
**Estado:** READ-ONLY

**Reglas:**
1. Primera conexión: solo `sapcli search` (GET)
2. Segunda: `sapcli cat` (GET, leer código)
3. No escribir ni activar nada
4. Verificar que los datos devueltos son correctos
5. Si falla, todo el sistema sigue funcionando offline

### FASE 7 — Escritura Controlada
**Estado:** WRITE CON APROBACIÓN

**Reglas:**
1. Solo escribir en paquetes Z* locales ($TMP)
2. Cada write requiere confirmación explícita
3. No activar en producción
4. Rollback plan listo antes de cada operación

## Referencias

- sap-nvim: ~/Desktop/sap-nvim/
- Documentación: ~/Desktop/sap-nvim/docs/
- Instalación offline: ~/Desktop/sap-nvim/docs/INSTALACION.md
- Arquitectura: ~/Desktop/sap-nvim/docs/ARQUITECTURA.md
