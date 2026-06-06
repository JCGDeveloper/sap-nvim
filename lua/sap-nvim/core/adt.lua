-- sap-nvim.core.adt
-- Cliente ADT para conexión y operaciones con sistemas SAP remotos

local M = {
  connections = {},
  current = nil,
}

function M.setup(opts)
  opts = opts or {}
  M.connections = opts.connections or {}
end

-- Read current sapcli context from config file
function M.get_current_context()
  local config_path = vim.fn.expand("~/.sapcli/config.yml")
  local f = io.open(config_path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()

  local current = content:match("current%-context:%s*([%w_%-]+)")
  if not current then return nil end

  local in_ctx = false
  local user = nil
  for line in content:gmatch("[^\r\n]+") do
    if line:match("^" .. vim.pesc(current) .. ":%s*$") then
      in_ctx = true
    elseif in_ctx and not line:match("^%s") then
      break
    elseif in_ctx then
      local u = line:match("^%s+user:%s*(.+)$")
      if u then user = vim.trim(u) end
    end
  end

  return { name = current, user = user }
end

-- Returns true if sapcli has a configured current-context
function M.is_configured()
  return M.get_current_context() ~= nil
end

-- Fetch packages matching a prefix pattern, e.g. "Z*" (async)
-- callback(packages, err)
function M.fetch_packages(pattern, callback)
  pattern = pattern or "Z*"
  local packages = {}
  local stderr = {}

  vim.fn.jobstart({ "sapcli", "package", "list", pattern }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local pkg = vim.trim(line)
        if pkg ~= "" then table.insert(packages, pkg) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      if code == 0 and #packages > 0 then
        callback(packages, nil)
      else
        local err = #stderr > 0 and stderr[1] or "No packages found for: " .. pattern
        callback(nil, err)
      end
    end,
  })
end

-- Fetch open transport orders (async)
-- callback(transports, err)  — each entry is the raw sapcli output line
function M.fetch_transport_orders(callback)
  local ctx = M.get_current_context()
  local args = { "sapcli", "cts", "list", "transport" }
  if ctx and ctx.user and ctx.user ~= "" then
    vim.list_extend(args, { "--owner", ctx.user:upper() })
  end

  local transports = {}
  local stderr = {}

  vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local t = vim.trim(line)
        if t ~= "" then table.insert(transports, t) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        callback(transports, nil)
      else
        local err = #stderr > 0 and stderr[1] or "Could not fetch transport orders"
        callback(nil, err)
      end
    end,
  })
end

-- Search ABAP objects by name pattern (async)
-- callback(results, err)
function M.fetch_objects(query, callback)
  local results = {}
  local stderr = {}

  vim.fn.jobstart({ "sapcli", "abap", "find", query }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local t = vim.trim(line)
        if t ~= "" then table.insert(results, t) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        callback(results, nil)
      else
        local err = #stderr > 0 and stderr[1] or "Search failed for: " .. query
        callback(nil, err)
      end
    end,
  })
end

-- Seleccionar conexión activa
function M.select_connection(name)
  if M.connections[name] then
    M.current = M.connections[name]
    vim.notify(("sap-nvim: Conexión '%s' seleccionada"):format(name))
  else
    vim.notify(("sap-nvim: Conexión '%s' no encontrada"):format(name), vim.log.levels.ERROR)
  end
end

-- Parse sapcli activation error output into quickfix entries.
-- Tries multiple line-number formats from SAP ADT responses.
function M._parse_activation_errors(lines, filename)
  local qf = {}

  -- Patterns ordered from most specific to least specific.
  -- Each returns (lnum_string, message_string) or nil.
  local patterns = {
    -- "Line 42: message" / "line 42: message"
    function(l) return l:match("[Ll]ine%s+(%d+):%s*(.+)") end,
    -- "Row 42: message" / "row 42: message"
    function(l) return l:match("[Rr]ow%s+(%d+):%s*(.+)") end,
    -- "(42,3): message" or "(42): message"  ← ADT JSON format
    function(l) return l:match("%((%d+),%d+%):%s*(.+)") end,
    function(l) return l:match("%((%d+)%):%s*(.+)") end,
    -- "error at line 42 column 3"
    function(l)
      local n = l:match("[Ee]rror%s+at%s+[Ll]ine%s+(%d+)")
      if n then return n, l end
    end,
    -- "syntax error in program .* line 42"
    function(l)
      local n = l:match("[Ss]yntax%s+error.+[Ll]ine%s+(%d+)")
      if n then return n, l end
    end,
    -- "at row 42" anywhere in the line
    function(l)
      local n = l:match("[Aa]t%s+[Rr]ow%s+(%d+)")
      if n then return n, l end
    end,
    -- Leading number with colon: "  42: message"
    function(l) return l:match("^%s*(%d+):%s+(.+)") end,
  }

  for _, line in ipairs(lines) do
    local lnum, text
    for _, pat in ipairs(patterns) do
      lnum, text = pat(line)
      if lnum then break end
    end

    if lnum then
      table.insert(qf, {
        filename = filename,
        lnum     = tonumber(lnum),
        col      = 1,
        text     = vim.trim(text or line),
        type     = "E",
      })
    end
  end

  return qf
end

-- Activate the current ABAP object. On success clears quickfix.
-- On failure parses error lines and jumps to the first one.
function M.activate_current()
  local bufnr      = vim.api.nvim_get_current_buf()
  local filename   = vim.api.nvim_buf_get_name(bufnr)
  local objtype    = require("sap-nvim.core.objtype")
  local group      = objtype.group(filename)
  local obj_name   = objtype.name(filename)

  if obj_name == "" then
    vim.notify("[sap-nvim] No hay un objeto ABAP para activar", vim.log.levels.WARN)
    return
  end

  if not objtype.is_activatable(group) then
    vim.notify("[sap-nvim] Tipo no activable o desconocido para: " .. filename, vim.log.levels.WARN)
    return
  end

  pcall(vim.cmd, "write")
  vim.notify("[sap-nvim] Activando " .. obj_name .. " (" .. group .. ")...")

  local out, err = {}, {}

  vim.fn.jobstart({ "sapcli", group, "activate", obj_name }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(out, l) end
      end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(err, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          vim.b[bufnr].sap_activation_status = "OK"
          vim.notify("[sap-nvim] " .. obj_name .. " activado correctamente")
          vim.fn.setqflist({}, "r", { title = "Activation OK: " .. obj_name })
          return
        end

        -- Merge stdout + stderr and try to parse line numbers
        local all = {}
        for _, l in ipairs(out) do table.insert(all, l) end
        for _, l in ipairs(err) do table.insert(all, l) end

        local qf = M._parse_activation_errors(all, filename)

        vim.b[bufnr].sap_activation_status = "ERR"
        if #qf > 0 then
          vim.fn.setqflist({}, "r")
          vim.fn.setqflist(qf, "r")
          vim.fn.setqflist({}, "a", { title = "Activation errors: " .. obj_name })
          vim.cmd("copen")
          vim.cmd("cfirst")
          vim.notify(
            "[sap-nvim] " .. #qf .. " error(es) en " .. obj_name .. ". Revisar quickfix.",
            vim.log.levels.ERROR
          )
        else
          local raw = #all > 0 and all[1] or ("Error activando " .. obj_name)
          vim.notify("[sap-nvim] " .. raw, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

-- Fetch the list of inactive objects (async)
-- callback(objects, err)
function M.fetch_inactive_objects(callback)
  local objects = {}
  local stderr = {}

  vim.fn.jobstart({ "sapcli", "activation", "inactiveobjects", "list" }, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        local t = vim.trim(line)
        if t ~= "" then table.insert(objects, t) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        callback(objects, nil)
      else
        local err = #stderr > 0 and stderr[1] or "Could not fetch inactive objects"
        callback(nil, err)
      end
    end,
  })
end

-- Ejecutar ATC (ABAP Test Cockpit)
function M.run_atc()
  local filename    = vim.api.nvim_buf_get_name(0)
  local objtype     = require("sap-nvim.core.objtype")
  local group       = objtype.group(filename)
  local object_name = objtype.name(filename)
  if object_name == "" then return end

  local atc_type = objtype.atc_type(group)
  vim.notify("[sap-nvim] Ejecutando ATC sobre " .. object_name .. " (" .. atc_type .. ")...")
  local lines = {}
  vim.fn.jobstart({ "sapcli", "atc", "run", atc_type, object_name }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(lines, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if #lines > 0 then
          vim.notify("[sap-nvim] ATC:\n" .. table.concat(lines, "\n"))
        end
        local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
        vim.notify("[sap-nvim] ATC " .. (code == 0 and "OK" or "encontro issues"), lvl)
      end)
    end,
  })
end

-- Ejecutar pruebas unitarias
function M.run_aunit()
  local object_name = vim.fn.expand("%:t:r")
  if object_name == "" then return end

  vim.notify("[sap-nvim] Ejecutando AUnit sobre " .. object_name .. "...")
  local lines = {}
  vim.fn.jobstart({ "sapcli", "aunit", "run", "class", object_name, "--output", "junit4" }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(lines, l) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if #lines > 0 then
          vim.notify("[sap-nvim] AUnit:\n" .. table.concat(lines, "\n"))
        end
        local lvl = code == 0 and vim.log.levels.INFO or vim.log.levels.WARN
        vim.notify("[sap-nvim] AUnit " .. (code == 0 and "OK" or "fallaron"), lvl)
      end)
    end,
  })
end

-- Buscar objetos en SAP
function M.search(query)
  vim.fn.jobstart({ "sapcli", "abap", "find", query }, {
    on_stdout = function(_, data)
      if data then
        local results = vim.iter(data):filter(function(line) return line ~= "" end):totable()
        if #results > 0 then
          vim.notify(("sap-nvim: %d resultados para '%s'"):format(#results, query))
        end
      end
    end,
  })
end

-- Abrir SAP GUI (aplicación de escritorio)
function M.open_gui(connection_name)
  local sapgui_path = "/Applications/SAP GUI.app"

  -- Intentar rutas alternativas de SAP GUI
  local possible_paths = {
    "/Applications/SAP GUI.app",
    "/Applications/SAPGUI.app",
    "/Applications/SAP GUI 7.60.app",
    "/Applications/SAP GUI 7.70.app",
    "/Applications/SAPGUI/SAP GUI.app",
  }

  local app_path = nil
  for _, path in ipairs(possible_paths) do
    local f = io.open(path .. "/Contents/Info.plist", "r")
    if f then
      f:close()
      app_path = path
      break
    end
  end

  if not app_path then
    vim.notify("sap-nvim: SAP GUI no encontrado. Verifica la ruta de instalación.", vim.log.levels.ERROR)
    return
  end

  -- Determinar el objeto actual
  local object_name = vim.fn.expand("%:t:r")
  local file_ext = vim.fn.expand("%:e")
  local transaction = M._get_transaction_for_extension(file_ext)

  -- Elegir conexión
  local conn = nil
  if connection_name and M.connections[connection_name] then
    conn = M.connections[connection_name]
  elseif M.current then
    conn = M.current
  end

  vim.fn.jobstart({ "open", app_path })
  if object_name ~= "" and object_name ~= "[No Name]" and transaction then
    vim.notify(string.format("[sap-nvim] SAP GUI abierto. Buscá %s en %s.", object_name, transaction))
  else
    vim.notify("[sap-nvim] SAP GUI abierto.")
  end
end

-- Mapear extensión de archivo a transacción SAP
function M._get_transaction_for_extension(ext)
  if not ext or ext == "" then return nil end
  local map = {
    abap = "SE80",          -- Object Navigator
    cls = "SE24",           -- Class Builder
    prog = "SE38",          -- ABAP Editor
    func = "SE37",          -- Function Builder
    ddl = "SE80",           -- CDS View (via SE80)
    dcl = "SE80",           -- CDS Access Control
    bdef = "SE80",          -- CDS Behavior Definition
    dbrel = "SE80",         -- CDS Metadata Extension
    simple = "SE80",
    fugr = "SE37",
    cinclude = "SE80",
    ddls = "SE80",
    intf = "SE80",
    tabl = "SE11",          -- Data Dictionary
    stru = "SE11",
    dtel = "SE11",
    dome = "SE11",
  }
  return map[ext:lower()]
end

return M
