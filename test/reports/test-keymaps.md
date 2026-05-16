# 🛠️ Test Report: Keymaps & Comandos — sap-nvim

**Fecha:** 2026-05-16  
**Analista:** JoseLuis (subagente de testing)  
**Fuentes analizadas:**
- `lua/sap-nvim/core/keymaps.lua`
- `lua/sap-nvim/core/lsp.lua`
- `lua/sap-nvim/core/setup.lua`
- `lua/sap-nvim/integrations/mcphub.lua`
- `~/.config/nvim/lua/plugins/sap-nvim.lua`

---

## 1. Tabla completa de Keymaps

### 1.1 Globales (modo Normal)

| Keymap | Descripción | Archivo | Estado |
|--------|-------------|---------|--------|
| `<leader>aa` | ABAP: Guardar y Activar | `core/keymaps.lua` | ✅ |
| `<leader>ac` | ABAP: Ejecutar ATC | `core/keymaps.lua` | ✅ |
| `<leader>au` | ABAP: Ejecutar AUnit | `core/keymaps.lua` | ✅ |
| `<leader>as` | ABAP: Buscar objeto | `core/keymaps.lua` | ✅ |
| `<leader>a1` | ABAP: Conexión 1 | `core/keymaps.lua` | ✅ |
| `<leader>a2` | ABAP: Conexión 2 | `core/keymaps.lua` | ✅ |
| `<leader>a3` | ABAP: Conexión 3 | `core/keymaps.lua` | ✅ |
| `<leader>a4` | ABAP: Conexión 4 | `core/keymaps.lua` | ✅ |
| `<leader>a5` | ABAP: Conexión 5 | `core/keymaps.lua` | ✅ |
| `<leader>ai` | ABAP: Terminal | `core/keymaps.lua` | ✅ |
| `<leader>ah` | ABAP: Ayuda sap-nvim | `sap-nvim.lua` (config) | ✅ |
| `<leader>asc` | ABAP: Configurar SAP | `core/setup.lua` + `sap-nvim.lua` (config) | ⚠️ Duplicado |
| `<leader>asg` | ABAP: Abrir SAP GUI / Abrir SAP GUI | `core/keymaps.lua` + `sap-nvim.lua` (config) | ❌ **Conflicto** |
| `<leader>aso` | ABAP: Abrir objeto en SAP GUI / Abrir objeto en SAP GUI | `core/keymaps.lua` + `sap-nvim.lua` (config) | ❌ **Conflicto** |
| `<leader>am` | MCP: Mostrar servidores | `integrations/mcphub.lua` | ✅ |
| `<leader>at` | MCP: Mostrar herramientas | `integrations/mcphub.lua` | ✅ |

### 1.2 Buffer-Local (ABAP filetype)

| Keymap | Descripción | Archivo | Estado |
|--------|-------------|---------|--------|
| `gd` | LSP: Go to Definition | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `K` | LSP: Hover | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `gr` | LSP: References | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `gi` | LSP: Implementation | `core/lsp.lua` | ✅ |
| `<leader>e` | LSP: Diagnostic Float | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `[d` | LSP: Diagnostic Previous | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `]d` | LSP: Diagnostic Next | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `<leader>rn` | LSP: Rename | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |
| `<leader>ca` | LSP: Code Action | `core/lsp.lua` | ✅ |
| `<leader>f` | LSP: Format | `core/lsp.lua` + `sap-nvim.lua` | ⚠️ Duplicado |

---

## 2. Conflictos Detectados

### ❌ CONFLICTO 1: `<leader>asg` (SAP GUI)

**Definido en 2 lugares con implementaciones diferentes:**

| Archivo | Implementación |
|---------|---------------|
| `core/keymaps.lua:54` | `adt.open_gui()` → depende del adaptador ADT |
| `sap-nvim.lua` (config) | Verifica `/Applications/SAP GUI.app`, usa `jobstart({ "open", app_path })` |

**Impacto:** Al ser globales, el último en cargarse (el de `sap-nvim.lua` en la config) gana. La implementación de `core/keymaps.lua` queda inactiva. Si se deshabilita la sección SAP GUI de la config, el keymap se rompe silenciosamente.

**Recomendación:** Unificar en un solo lugar — idealmente en `core/keymaps.lua` o `core/adt.lua`, no en el archivo de configuración del usuario.

---

### ❌ CONFLICTO 2: `<leader>aso` (objeto en SAP GUI)

**Definido en 2 lugares:**

| Archivo | Implementación |
|---------|---------------|
| `core/keymaps.lua:59` | `adt.open_gui(nil)` → depende del adaptador |
| `sap-nvim.lua` (config) | Tiene la lógica `tx_map` completa |

**Impacto:** Mismo problema que `<leader>asg`. La versión de la config tiene el `tx_map` que mapea extensiones a transacciones, la de keymaps.lua es un stub que delega a ADT.

**Recomendación:** Mover la lógica `tx_map` de la config a `core/adt.lua` y que `core/keymaps.lua` la consuma desde ahí. Eliminar el duplicado de la config.

---

### ⚠️ CONFLICTO 3: `<leader>asc` (Setup)

**Definido en 2 lugares pero con misma funcionalidad:**

| Archivo | Implementación |
|---------|---------------|
| `core/setup.lua:548` | `show_main_menu()` directamente |
| `sap-nvim.lua` (config) | `:SapSetup<CR>` que también llama a `show_main_menu()` |

**Impacto:** Mínimo — ambos ejecutan `show_main_menu()`. Sin embargo, la existencia de `<leader>asc` en dos archivos separados es código duplicado.

**Recomendación:** Mantener solo el de `core/setup.lua` y eliminar el de la config, ya que `core/setup.lua` ya define el comando `:SapSetup` y su keymap.

---

### ⚠️ CONFLICTO 4: LSP keymaps duplicados para ABAP

Los siguientes keymaps están definidos **2 veces** para ABAP filetype:
- `gd`, `K`, `gr`, `<leader>e`, `[d`, `]d`, `<leader>rn`, `<leader>f`

**Definidos en:**
1. `core/lsp.lua` (autocmd `FileType` `abap`)
2. `sap-nvim.lua` (config) (autocmd `FileType` `abap`)

**Impacto:** Ambos autocmds se ejecutan al abrir un ABAP file. Al ser `{ buffer = true }`, el último en registrarse prevalece. Dependiendo del orden de carga del plugin vs config, los keymaps de la config podrían sobrescribir a los del plugin. Esto es frágil y confuso.

**Recomendación:** Eliminar los LSP keymaps del archivo de configuración (`sap-nvim.lua`) y dejarlos solo en `core/lsp.lua`. Si se necesita personalización, usar las opciones del plugin (`opts.lsp`).

---

## 3. Verificación de Comandos

### ✅ `:SapConnectionsHelp`

| Aspecto | Resultado |
|---------|-----------|
| Definido con `nvim_create_user_command` | ✅ Sí |
| Desc | ✅ `"Ayuda de comandos sap-nvim"` |
| Funcional | ✅ Muestra notificación con comandos disponibles |
| Keymap asociado | ✅ `<leader>ah` → `:SapConnectionsHelp` |

### ✅ `:SapSetup`

| Aspecto | Resultado |
|---------|-----------|
| Definido con `nvim_create_user_command` | ✅ Sí (en `core/setup.lua` y `sap-nvim.lua`) |
| Desc | ✅ `"sap-nvim: Configuración interactiva de conexiones SAP"` |
| Funcionalidad | ✅ Completo — menú interactivo con new/edit/view/test/delete/install |
| Keymap asociado | ✅ `<leader>asc` → `:SapSetup` |

### ⚠️ Observación: `:SapSetup` definido dos veces

Se encontró DEFINICIÓN DOBLE del comando `:SapSetup`:
1. `core/setup.lua` — la implementación real con toda la lógica
2. `sap-nvim.lua` (config) — solo la cabecera (la implementación está en core/setup.lua)

En Neovim, si se define el mismo comando dos veces, el segundo `nvim_create_user_command` **lanza un error** a menos que se especifique `force = true`. Esto podría causar un error silencioso al cargar la configuración si ambos archivos lo definen.

```lua
-- En core/setup.lua:
vim.api.nvim_create_user_command("SapSetup", function() show_main_menu() end, { desc = "..." })

-- En sap-nvim.lua (config):
-- Si hay un require que ya definió SapSetup, el segundo create_user_command FALLARÁ
```

**Recomendación:** Mantener `:SapSetup` solo en `core/setup.lua`. Eliminar la redeclaración del archivo de configuración.

---

## 4. Verificación de `<leader>asc` → `:SapSetup`

| Aspecto | Resultado |
|---------|-----------|
| Keymap | ✅ `<leader>asc` |
| Acción | ✅ `:SapSetup<CR>` → llama a `show_main_menu()` |
| Desc | ✅ `"ABAP: Configurar SAP"` |
| Conflictos | ⚠️ Definido en 2 archivos (misma funcionalidad, ver arriba) |

---

## 5. Descriptores (desc)

| Keymap | desc actual | Evaluación |
|--------|-------------|------------|
| `<leader>aa` | `"ABAP: Guardar y Activar"` | ✅ |
| `<leader>ac` | `"ABAP: Ejecutar ATC"` | ✅ |
| `<leader>au` | `"ABAP: Ejecutar AUnit"` | ✅ |
| `<leader>as` | `"ABAP: Buscar objeto"` | ✅ |
| `<leader>ai` | `"ABAP: Terminal"` | ✅ |
| `<leader>ah` | `"ABAP: Ayuda sap-nvim"` | ✅ |
| `<leader>asc` | `"ABAP: Configurar SAP"` | ✅ |
| `<leader>asg` (keymaps.lua) | `"ABAP: Abrir SAP GUI"` | ✅ (pero inactivo por conflicto) |
| `<leader>asg` (sap-nvim.lua) | `"Abrir SAP GUI"` | ❌ **Falta prefijo "ABAP:"** |
| `<leader>aso` (keymaps.lua) | `"ABAP: Abrir objeto en SAP GUI"` | ✅ (pero inactivo) |
| `<leader>aso` (sap-nvim.lua) | `"Abrir objeto en SAP GUI"` | ❌ **Falta prefijo "ABAP:"** |
| `<leader>am` | `"MCP: Mostrar servidores"` | ✅ |
| `<leader>at` | `"MCP: Mostrar herramientas"` | ✅ |
| `<leader>a1`..`<leader>a5` | `"ABAP: Conexión N"` | ✅ |

---

## 6. Mapeo de transacciones SAP por extensión

Validación del `tx_map` en `<leader>aso` (`sap-nvim.lua` config):

| Extensión | Transacción SAP | Propósito | ✅/❌ |
|-----------|----------------|-----------|-------|
| `.abap` | **SE80** | Object Navigator (navegador de repositorio ABAP) | ✅ |
| `.cls` | **SE24** | Class Builder | ✅ |
| `.prog` | **SE38** | ABAP Editor (programas) | ✅ |
| `.func` | **SE37** | Function Builder | ✅ |
| `.tabl` | **SE11** | Data Dictionary (tablas) | ✅ |
| `.stru` | **SE11** | Data Dictionary (estructuras) | ✅ |

**Todas las transacciones son correctas.** ✅

### ⚠️ Observación: Extensiones no cubiertas

Faltan algunas extensiones ABAP comunes que podrían tener soporte:

| Extensión | Tipo ABAP | Transacción sugerida |
|-----------|-----------|---------------------|
| `.intf` | Interface | SE24 |
| `.nrob` | Number Range Object | SNRO |
| `.smim` | MIME Object | SMW0 |
| `.dbtab` | Database Table | SE11 |
| `.ddls` | CDS View | SE80 (DDL Source) |
| `.enh` | Enhancement | SE80 |
| `.bdoc` | BDoc | SE80 |
| `.wdr` | Web Dynpro Component | SE80 |
| `.fugr` | Function Group | SE37 (o SE80) |

**Recomendación:** Ampliar el `tx_map` para incluir `.intf` y `.ddls` como mínimo, ya son extensiones muy comunes.

---

## 7. Resumen de Problemas

| # | Severidad | Problema | Archivos afectados |
|---|-----------|----------|-------------------|
| 1 | 🔴 **Alta** | `<leader>asg` definido en 2 archivos con distinta implementación | `keymaps.lua`, `sap-nvim.lua` |
| 2 | 🔴 **Alta** | `<leader>aso` definido en 2 archivos con distinta implementación | `keymaps.lua`, `sap-nvim.lua` |
| 3 | 🟡 **Media** | `:SapSetup` definido 2 veces → puede causar error al cargar | `core/setup.lua`, `sap-nvim.lua` |
| 4 | 🟡 **Media** | LSP keymaps duplicados (ABAP filetype) en plugin y config | `core/lsp.lua`, `sap-nvim.lua` |
| 5 | 🟡 **Media** | `<leader>asc` definido en 2 archivos (misma función) | `core/setup.lua`, `sap-nvim.lua` |
| 6 | 🟢 **Baja** | desc de `<leader>asg` y `<leader>aso` sin prefijo "ABAP:" | `sap-nvim.lua` |
| 7 | 🟢 **Baja** | Extensiones ABAP faltantes en `tx_map` (`.intf`, `.ddls`, etc.) | `sap-nvim.lua` |
| 8 | 🟢 **Baja** | `core/lsp.lua` tiene `<leader>ca` y `gi` que la config no tiene — asimetría | `core/lsp.lua`, `sap-nvim.lua` |

---

## 8. Recomendaciones

### Inmediatas (🔴 Alta prioridad)

1. **Unificar `<leader>asg` y `<leader>aso`** — Eliminar las definiciones duplicadas del archivo de configuración `sap-nvim.lua` y dejar la lógica completa en `core/adt.lua` o `core/keymaps.lua`. La configuración del usuario no debería definir keymaps del plugin.

2. **Unificar `:SapSetup`** — Eliminar la segunda definición del comando en `sap-nvim.lua`. Dejar solo la de `core/setup.lua`.

### A medio plazo (🟡 Media prioridad)

3. **Eliminar LSP keymaps duplicados** — Quitar los buffer-local keymaps del FileType autocmd en `sap-nvim.lua`. Si el usuario quiere personalizar, debe pasar `opts.lsp` al setup del plugin.

4. **Eliminar `<leader>asc` duplicado** — Mantener solo la definición en `core/setup.lua`.

5. **Normalizar descriptores** — Añadir prefijo "ABAP:" a los desc de `<leader>asg` y `<leader>aso` en `sap-nvim.lua`.

### Mejoras (🟢 Baja prioridad)

6. **Ampliar `tx_map`** — Añadir al menos `.intf` → SE24 y `.ddls` → SE80.

7. **Sincronizar LSP keymaps** — Asegurar que los keymaps en `core/lsp.lua` (que tiene `gi` y `<leader>ca`) estén disponibles cuando se cargue solo el plugin sin la config duplicada.

---

## 9. Arquitectura recomendada (cómo debería quedar)

```
core/keymaps.lua     → Keymaps ABAP (<leader>aa, ac, au, as, ai, a1-5)
                        Keymaps SAP GUI (<leader>asg, aso) [ÚNICA DEFINICIÓN]
core/lsp.lua         → Keymaps LSP (gd, K, gr, gi, [d, ]d, <leader>e, rn, ca, f)
core/setup.lua       → :SapSetup (comando) + <leader>asc (keymap)
integrations/mcphub  → <leader>am, <leader>at

sap-nvim.lua (config) → NINGÚN keymap ni comando. Solo configuración del plugin.
```

Esto sigue el principio de separación de responsabilidades: el plugin define la funcionalidad, la configuración del usuario solo la parametriza.

---

## 10. Leyenda

| Símbolo | Significado |
|---------|-------------|
| ✅ | Correcto / Sin problemas |
| ⚠️ | Advertencia / Duplicado sin conflicto funcional |
| ❌ | Conflicto / Problema que requiere acción |
| 🔴 | Alta severidad — rompe o crea comportamiento inesperado |
| 🟡 | Media severidad — duplicación, riesgo de errores |
| 🟢 | Baja severidad — mejora estética o funcionalidad menor |
