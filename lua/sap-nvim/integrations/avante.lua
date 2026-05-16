-- sap-nvim.integrations.avante
-- Integración con Avante para asistencia IA en ABAP

local M = {}

function M.setup(opts)
  opts = opts or {}

  local ok, avante = pcall(require, "avante")
  if not ok then
    return
  end

  -- Configurar Avante para usar MCP de SAP
  avante.setup({
    provider = opts.provider or "claude",
    -- MCP servers para ABAP
    mcp_servers = opts.mcp_servers or {},
    -- System prompt especializado para ABAP
    system_prompt = [[Eres un asistente experto en ABAP, SAP S/4HANA y CDS.

Reglas:
1. Siempre que necesites información del sistema SAP, usa las herramientas MCP disponibles
2. Para leer código remoto: usa GetProgram, GetClass, GetInterface
3. Para consultar DDIC: usa GetTable, GetTableContents
4. Para modificar: primero lee, luego modifica, luego activa
5. Sigue los estándares Clean ABAP
6. Prefiere ABAP OO sobre procedural
7. Usa CDS views para modelos de datos

Formato de respuesta:
- Explica el problema y la solución
- Muestra el código ABAP con sintaxis correcta
- Indica qué pruebas unitarias ejecutar]],
  })
end

return M
