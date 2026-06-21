# Capa de IA — servidor MCP de ADT + agentes que programan en SAP

Esto conecta un **servidor MCP de ABAP ADT** a un agente de IA (Claude Code) para que pueda
**leer, escribir, activar, ejecutar, testear y depurar** ABAP en tu sistema — con barreras de
seguridad. Es **opcional** y vive fuera del repo (en `~/.config` y `~/.claude`); aquí solo se
documenta el procedimiento. **No pongas credenciales en el repo.**

---

## 1. Servidor MCP (CRUD ADT)

Usamos **[`fr0ster/mcp-abap-adt`](https://github.com/fr0ster/mcp-abap-adt)** (`@mcp-abap-adt/core`):
CRUD completo on-prem S/4 (clases, interfaces, FUGR/FM, programas, CDS/RAP, DDIC), activación,
transportes, ejecución y runtime (dumps/SAT). ~168 herramientas.

```sh
npm install -g @mcp-abap-adt/core      # binario `mcp-abap-adt` en el PATH
```

### Conexión (auth) — `~/.config/mcp-abap-adt/.env` (modo 600, NO en el repo)
```env
SAP_URL=https://<host>:<puerto-https>      # p.ej. https://miSistema:44300
SAP_CLIENT=<cliente>
SAP_LANGUAGE=EN
SAP_AUTH_TYPE=basic
SAP_SYSTEM_TYPE=onprem                     # imprescindible on-prem (habilita Programs, etc.)
SAP_USERNAME=<usuario>
SAP_PASSWORD=<contraseña>
SAP_RESPONSIBLE=<usuario>
TLS_REJECT_UNAUTHORIZED=0                   # si el cert es autofirmado
```
```sh
chmod 600 ~/.config/mcp-abap-adt/.env
```

### Registrar en Claude Code
```sh
claude mcp add abap-adt --scope user -- mcp-abap-adt --env-path ~/.config/mcp-abap-adt/.env
claude mcp list                            # debe mostrar  abap-adt … ✔ Connected
```

---

## 2. Agentes ABAP (`~/.claude/agents/`)

| Agente | Rol |
|---|---|
| `abap-orchestrator` | Coordina el bucle spec → implementa → activa → testea → revisa |
| `abap-implementer` | Crea/actualiza objetos y los **activa**; corrige errores de activación |
| `abap-tester` | **AUnit + ATC** (Clean ABAP); bloqueante |
| `abap-reviewer` | Revisión Clean ABAP (nombres, sintaxis moderna, SQL, errores) |
| `abap-debugger` | **Debug post-mortem**: dumps (ST22), reproducir, perfilar (SAT), causa raíz, fix |

> No hay step-debugger interactivo por MCP (breakpoints/variables) — eso es el depurador manual
> de nvim (`<leader>ad`). El agente hace diagnóstico post-mortem + reproducción + perfilado.

Uso (tras reiniciar Claude Code):
> *"Usa el **abap-orchestrator**: crea ZCL_DEMO con un método que lea 10 filas de VBAK y las
> muestre; actívala, ejecútala y pasa AUnit + ATC."*
> *"Usa el **abap-debugger**: ZNVIM ha dado un dump, dime por qué y arréglalo."*

---

## 3. Convenciones y restricciones del proyecto

**`~/.claude/sap/conventions.md`** — nomenclatura por proyecto, restricciones DURAS (lo prohibido),
reglas obligatorias, sintaxis nueva y la variante ATC de la empresa. Los agentes lo leen y lo
**obedecen**. Edítalo para "mandarles" las reglas de tu empresa/proyecto.

---

## 4. Seguridad — solo lectura en estándar, escritura solo Z/Y

Un **hook** `PreToolUse` (`~/.claude/hooks/abap-zonly-guard.py`, registrado en
`~/.claude/settings.json`) **bloquea** cualquier `Create/Update/Delete/Write` del MCP sobre objetos
que no sean `Z*/Y*` (o namespace `/.../`). Las lecturas pasan. Capas:

1. **Autorizaciones de SAP** — tu usuario de dev no puede modificar estándar (muro real).
2. **Agentes** — instruidos para `Z*/Y*` y cliente sandbox.
3. **Hook** — bloqueo duro a nivel de herramienta (probado).

```jsonc
// ~/.claude/settings.json
{
  "hooks": {
    "PreToolUse": [
      { "matcher": "mcp__abap-adt__.*",
        "hooks": [ { "type": "command",
          "command": "python3 ~/.claude/hooks/abap-zonly-guard.py" } ] }
    ]
  }
}
```

---

## 5. Usarlo desde Neovim

- **Chat natural**: `coder/claudecode.nvim` (en `~/.config/nvim-sap/lua/plugins/ai.lua`) abre
  Claude Code en un panel — **`<leader>ii`**. Usa tu suscripción (sin API key); el Claude que abre
  ya tiene el MCP + agentes + convenciones + hook. `<leader>is` (visual) envía selección;
  `<leader>id`/`ix` aceptan/rechazan los diffs propuestos.
- **Inspeccionar el MCP**: `mcphub.nvim` (en `~/.config/nvim-sap/lua/plugins/mcp.lua` +
  `~/.config/mcphub/servers.json`) — **`<leader>aM`** (`:MCPHub`) para ver/ejecutar tools una a una.

> Avante/codecompanion necesitan una API key de LLM; por eso usamos Claude Code (suscripción).
