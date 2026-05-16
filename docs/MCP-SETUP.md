# Configuración de Servidores MCP para SAP

## ARC-1 (Recomendado para Producción)

### Instalación
```bash
git clone https://github.com/marianfoo/arc-1.git ~/sap-mcp-servers/arc-1
cd ~/sap-mcp-servers/arc-1
npm install
```

### Configuración
Crear archivo `.env`:

```env
# Conexión SAP
SAP_ADT_URL=https://sap.example.com:443
SAP_CLIENT=100
SAP_USER=tu_usuario
SAP_PASS=tu_contraseña

# Seguridad
ARC_DEFAULT_DENY=true
ARC_ALLOWED_PACKAGES=Z*,Y*
ARC_READ_ONLY=false
```

### Herramientas MCP Expuestas

| Herramienta | Descripción |
|---|---|
| `abap_search` | Buscar objetos en el repositorio SAP |
| `abap_get_source` | Leer código fuente de un objeto |
| `abap_set_source` | Modificar código fuente |
| `abap_activate` | Activar objetos |
| `abap_syntax_check` | Verificar sintaxis |
| `abap_get_table` | Obtener definición de tabla DDIC |
| `abap_get_table_contents` | Leer datos de una tabla |
| `abap_lock` | Bloquear objeto para edición |
| `abap_unlock` | Liberar bloqueo |
| `abap_atc_run` | Ejecutar ABAP Test Cockpit |
| `abap_aunit_run` | Ejecutar pruebas unitarias |

## mcp-abap-adt-api (Ligero)

### Instalación
```bash
git clone https://github.com/mario-andreschak/mcp-abap-abap-adt-api.git ~/sap-mcp-servers/mcp-abap-adt-api
cd ~/sap-mcp-servers/mcp-abap-adt-api
npm install
```

### Uso con Neovim

```lua
-- mcphub.nvim
require("mcphub").setup({
  servers = {
    {
      name = "arc-1",
      cmd = { "node", "~/sap-mcp-servers/arc-1/server.js" },
    },
  },
})
```

### Ejemplo de Interacción con IA

```
Usuario: "Explícame cómo funciona ZCL_FACTURACION y corrígeme el error"

1. IA usa abap_search → localiza ZCL_FACTURACION
2. IA usa abap_get_source → lee el código
3. IA analiza: detecta variable no inicializada
4. IA usa abap_syntax_check → verifica corrección
5. IA usa abap_set_source → aplica el fix
6. IA usa abap_activate → activa en SAP
7. IA responde: "Error corregido: v_total no estaba inicializado. 
   Añadí v_total = 0 antes del loop. Objeto activado."
```

### Seguridad

ARC-1 implementa:
- **Default deny**: Sin permiso explícito, la IA solo puede leer
- **Package whitelist**: Solo paquetes Z*, Y* permitidos
- **Principal propagation**: Opera con tu usuario SAP real
- **Read-only mode**: Opción para sistemas productivos
