# Test Report: sapcli CLI & Conexiones (sap-nvim)

**Fecha:** 2026-05-16 21:55 (GMT+2)  
**Proyecto:** `/Users/jcgomez/Desktop/sap-nvim/`  
**Shell:** Nushell (macOS)  

---

## 1. Instalación de sapcli ✅

| Item | Resultado |
|------|-----------|
| `which sapcli` | `/usr/local/bin/sapcli` |
| `sapcli --version` | `sapcli 1.0.0` |

**Veredicto:** ✅ sapcli instalado y funcional.

---

## 2. Subcomandos disponibles ✅

sapcli expone **~35 subcomandos** principales:

| Grupo | Subcomandos |
|-------|------------|
| **Objetos ABAP** | `program`, `include`, `interface`, `class`, `functiongroup`, `functionmodule`, `table`, `structure`, `dataelement`, `domain`, `authorizationfield`, `badi`, `featuretoggle` |
| **CDS** | `ddl`, `dcl`, `bdef` |
| **Calidad** | `aunit`, `atc` |
| **Transporte** | `package`, `cts`, `checkout`, `checkin`, `activation` |
| **ADT/APIs** | `adt`, `abapgit`, `rap`, `abap`, `transaction`, `gcts`, `startrfc` |
| **Utilidades** | `datapreview`, `strust`, `user`, `bsp`, `flp`, `config` |

**Nota:** El subcomando `config` incluye operaciones de gestión de conexiones (`set-connection`, `get-contexts`, `view`, etc.), lo que permite añadir contextos por CLI sin modificar YAML manualmente.

**Veredicto:** ✅ Amplia cobertura de operaciones SAP.

---

## 3. Archivo de configuración ~/.sapcli/config.yml ❌

| Check | Resultado |
|-------|-----------|
| `~/.sapcli/` existe | ❌ No existe |
| `~/.sapcli/config.yml` | ❌ No existe |

**Detalle:** El directorio `~/.sapcli/` no ha sido creado aún. Esto es esperable en una instalación limpia — se crea al ejecutar:
- `./scripts/sapcli-setup.sh` (asistente interactivo bash)
- `:SapSetup` dentro de Neovim (asistente Lua)

**Veredicto:** ⚠️ No hay config YAML. No es un error, pero hay que ejecutar el setup antes de usar sapcli con conexiones persistentes.

---

## 4. sap-connections.json ✅

| Check | Resultado |
|-------|-----------|
| Ruta | `/Users/jcgomez/Desktop/sap-nvim/config/sap-connections.json` |
| JSON válido | ✅ |
| Conexiones definidas | 3: `desarrollo`, `calidad`, `produccion` |

**Estructura actual:**

```json
{
  "desarrollo": {
    "system_id": "D01",
    "host": "sap.desarrollo.empresa.com",
    "port": 443,
    "client": "100",
    "username": "$USER",
    "auth": "basic"
  },
  "calidad": { ... },
  "produccion": { ... }
}
```

**Veredicto:** ✅ JSON válido, 3 conexiones definidas.

---

## 5. sapcli-setup.sh (sintaxis bash) ✅

| Check | Resultado |
|-------|-----------|
| `bash -n` | ✅ Sin errores |
| Líneas | 317 líneas |
| Encoding | UTF-8, Unix line endings |

**Funcionalidades del script:**
- ✅ Verifica/instala sapcli automáticamente
- ✅ Crea `~/.sapcli/config.yml` interactivamente
- ✅ Soporta múltiples contextos (desarrollo, calidad, producción)
- ✅ Sincroniza con `sap-connections.json` vía Python inline
- ✅ Crea backups automáticos
- ✅ Menú completo: nueva conexión, editar, ver, probar, eliminar
- ✅ Buena experiencia UX con colores y prompts

**Veredicto:** ✅ Script bash correcto, robusto, con manejo de errores (`set -euo pipefail`).

---

## 6. setup.lua (sintaxis Lua) ✅

| Check | Resultado |
|-------|-----------|
| `luac -p` | ✅ Sin errores |
| Líneas | ~550 líneas |
| Ruta | `/Users/jcgomez/Desktop/sap-nvim/lua/sap-nvim/core/setup.lua` |

**Funcionalidades del módulo:**
- ✅ Comando Neovim `:SapSetup`
- ✅ Keymap `<leader>asc`
- ✅ Parseo YAML básico sin dependencias externas
- ✅ Diálogos interactivos dentro de Neovim (flotantes)
- ✅ Sincronización automática con `sap-connections.json`
- ✅ Prueba de conexión vía `vim.fn.jobstart`
- ✅ Verificación/instalación de sapcli
- ✅ CRUD completo de conexiones

**Veredicto:** ✅ Lua válido, bien estructurado. Un posible detalle: en `parse_sapcli_config()`, el parsing YAML asume indentación de 2 espacios (`^  (%w+):`), lo que podría fallar si el config usa tabs u otra indentación.

---

## 7. Sincronización setup.lua ↔ sap-connections.json ❌

### ⚠️ Incompatibilidad de esquemas

El archivo `sap-connections.json` actual fue creado con un esquema diferente al que genera `setup.lua`. Esto causará pérdida de datos si se ejecuta `:SapSetup`.

| Campo | sap-connections.json (actual) | setup.lua (sync_to_neovim) |
|-------|------------------------------|---------------------------|
| `ashost` | ❌ Usa `host` | ✅ `ashost` |
| `sysnr` | ❌ No existe | ✅ `sysnr: "00"` |
| `client` | ✅ `"100"` | ✅ `"100"` |
| `port` | ✅ `443` (int) | ✅ `443` (number) |
| `user` | ❌ Usa `username` | ✅ `user` |
| `password` | ❌ No existe | ❌ No existe en JSON |
| `ssl` | ❌ No existe | ✅ `ssl: true` |
| `system_id` | ✅ `"D01"` | ✅ Generado de `sysid` o `name` |
| `description` | ❌ No existe | ✅ `"Conexión X"` |
| `auth` | ❌ `"basic"` presente | ❌ No se sincroniza |

**Impacto:** Si alguien ejecuta `:SapSetup` → `sync_to_neovim()`, el archivo `sap-connections.json` será **sobrescrito** con el nuevo esquema, perdiendo los campos `host`, `username` y `auth`. El consumer `sap-connect.sh` espera el formato con `host` y `username`, por lo que dejaría de funcionar.

### Lectores de sap-connections.json

| Archivo | Espera uso de |
|---------|--------------|
| `scripts/sap-connect.sh` | `host`, `username` (schema antiguo) |
| `lua/sap-nvim/core/setup.lua` | `ashost`, `user` (schema nuevo) |

**Veredicto:** ❌ Los esquemas no coinciden. Hay que unificarlos.

---

## Resumen General

| # | Check | Estado |
|---|-------|--------|
| 1 | sapcli instalado (v1.0.0) | ✅ |
| 2 | Subcomandos disponibles (~35) | ✅ |
| 3 | Config YAML (`~/.sapcli/config.yml`) | ❌ No existe (pendiente setup) |
| 4 | JSON conexiones (`sap-connections.json`) | ✅ Válido |
| 5 | Sintaxis bash (`sapcli-setup.sh`) | ✅ Sin errores |
| 6 | Sintaxis Lua (`setup.lua`) | ✅ Sin errores |
| 7 | Sincronización esquemas | ❌ Incompatibles |

---

## Recomendaciones

### 🔴 Crítica
1. **Unificar esquema de campos** entre `setup.lua` y `sap-connections.json`:
   - Decidir si el campo es `host` o `ashost` (sapcli CLI usa `--ashost`)
   - Decidir si el campo es `username` o `user` (sapcli CLI usa `--user`)
   - Agregar `password` si se necesita persistencia (actualmente setup.lua lo guarda solo en YAML)
   - Si se necesita `auth`, agregarlo al sync de setup.lua

### 🟡 Media
2. **Actualizar `sap-connect.sh`** para que lea el nuevo esquema (ashost, user, ssl, sysnr) después de la unificación
3. **Ejecutar `sapcli-setup.sh`** o `:SapSetup` para crear `~/.sapcli/config.yml` y regerar `sap-connections.json` con el esquema correcto

### 🟢 Baja
4. **Backup del actual `sap-connections.json`** antes de regenerar (por si se pierden datos)
5. Considerar usar `sapcli config set-connection` en lugar de escribir YAML manualmente, ya que sapcli ya gestiona contextos por CLI
6. Documentar en README que `sap-connections.json` es auto-generado por `:SapSetup` y no debe editarse manualmente

---

*Reporte generado automáticamente por agente de testing.*
