# Flujos de Trabajo — sap-nvim

## Flujo Diario

### 1. Desarrollo Local (sin conexión SAP)

```
1. Abres Neovim → archivo .abap
2. Tree-sitter resalta sintaxis ✅
3. abaplint valida en tiempo real ✅
4. Escribes código con autocompletado
5. Formateas con <leader>f
```

### 2. Conexión Remota (con SAP accesible)

```
1. Seleccionas conexión: <leader>a1
2. Buscas objeto: <leader>as ZCL_EJEMPLO
3. Lees código remoto: SapSearch ZCL_EJEMPLO
4. Modificas localmente
5. Activas: <leader>aa
   → Guarda local → sapcli activate → resultado en quickfix
```

### 3. Con IA Agéntica (MCP + ARC-1)

```
1. Instrucción: "Analiza ZCL_SD_SALES_ORDER"
2. MCP busca el objeto en SAP remoto
3. IA lee el código y entiende el contexto
4. Detecta error y propone corrección
5. Confirma → IA modifica y activa remotamente
6. Resultado: código corregido + transport creado
```

## Atajos de Teclado

| Atajo | Acción |
|---|---|
| `<leader>aa` | Guardar y activar objeto ABAP |
| `<leader>ac` | Ejecutar ATC (ABAP Test Cockpit) |
| `<leader>au` | Ejecutar pruebas unitarias |
| `<leader>as` | Buscar objetos ABAP |
| `<leader>ai` | Abrir terminal |
| `<leader>asg` | Abrir SAP GUI (aplicación) |
| `<leader>aso` | Abrir objeto actual en SAP GUI |
| `<leader>a1-5` | Seleccionar conexión SAP |
| `<leader>am` | Mostrar servidores MCP |
| `<leader>at` | Mostrar herramientas MCP |
| `gd` | Ir a definición (LSP) |
| `K` | Información del símbolo |
| `gr` | Ver referencias |
| `[d` / `]d` | Navegar diagnósticos |
| `<leader>f` | Formatear código |
| `<leader>rn` | Renombrar símbolo |

## Comandos Ex

| Comando | Acción |
|---|---|
| `:SapActivate [objeto]` | Activar objeto ABAP |
| `:SapSearch <query>` | Buscar objetos ABAP |
| `:SapConnections` | Listar conexiones |
| `:Oil sap://ZPAQUETE` | Navegar paquete SAP |

## Modos de Trabajo

### Sin conexión a SAP
Ideal para cuando estás fuera de la red corporativa:
- ✅ Tree-sitter para sintaxis
- ✅ abaplint para validación
- ✅ Escribes código ABAP offline
- ⏳ Activas cuando te conectas

### Con VPN / Conexión directa
- ✅ Todo lo anterior
- ✅ sapcli para operaciones ADT
- ✅ Activación remota con <leader>aa
- ✅ ATC y AUnit remotos

### Con MCP / IA
- ✅ Todo lo anterior
- ✅ Agente IA con acceso al DDIC
- ✅ Búsqueda y modificación autónoma
- ✅ Correcciones inteligentes
