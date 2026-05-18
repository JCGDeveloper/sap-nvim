-- sap-nvim.core.setup
-- Asistente interactivo de configuración SAP desde Neovim
-- Uso: :SapSetup

local M = {}

local config_path = vim.fn.expand("~/.sapcli/config.yml")
local nvim_connections_path = vim.fn.expand("~/Desktop/sap-nvim/config/sap-connections.json")

-- ─── Utilerías ───────────────────────────────────────────────────────────────

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Forward declarations (Lua necesita que las variables existan antes de usarse)
local show_new_connection
local show_edit_connection
local show_connections
local show_test_connection
local show_delete_connection
local install_sapcli

local function read_file(path)
  local f = io.open(path, "r")
  if not f then return nil end
  local content = f:read("*a")
  f:close()
  return content
end

local function write_file(path, content)
  local dir = vim.fn.fnamemodify(path, ":h")
  vim.fn.mkdir(dir, "p")
  local f = io.open(path, "w")
  if not f then
    notify("No se pudo escribir: " .. path, vim.log.levels.ERROR)
    return false
  end
  f:write(content)
  f:close()
  return true
end

local function shell(cmd)
  local result = vim.fn.system(cmd)
  local ok = vim.v.shell_error == 0
  return ok, result
end

-- ─── Parsear YAML básico (sin dependencias) ──────────────────────────────────

-- Lee ~/.sapcli/config.yml y devuelve { contexts = {}, current = "" }
local function parse_sapcli_config()
  local config = read_file(config_path)
  if not config then
    return { contexts = {}, current = "" }
  end

  local result = { contexts = {}, current = "" }
  local current_ctx = ""
  local in_context = nil
  local ctx_data = {}

  for line in config:gmatch("[^\r\n]+") do
    -- current-context
    local cur = line:match("^current%-context:%s*(.+)$")
    if cur then
      result.current = vim.trim(cur)
    end

    -- context header (ej: "desarrollo:")
    local ctx_name = line:match("^([%w_-]+):%s*$")
    if ctx_name and not line:match("^  ") then
      -- Guardar contexto anterior
      if in_context and next(ctx_data) then
        result.contexts[in_context] = vim.deepcopy(ctx_data)
        ctx_data = {}
      end
      in_context = ctx_name
    end

    -- valores dentro de un contexto
    if in_context then
      local key, val = line:match("^  (%w+):%s*(.+)$")
      if key then
        ctx_data[key] = vim.trim(val)
      end
    end
  end

  -- Guardar último contexto
  if in_context and next(ctx_data) then
    result.contexts[in_context] = ctx_data
  end

  return result
end

-- ─── Escribir config.yml ────────────────────────────────────────────────────

local function write_sapcli_config(config)
  local lines = {
    "# sapcli configuration",
    "# Generado por sap-nvim :SapSetup",
    "# Editado: " .. os.date("%Y-%m-%d %H:%M"),
    "",
  }

  if config.current and config.current ~= "" then
    table.insert(lines, "current-context: " .. config.current)
    table.insert(lines, "")
  end

  for name, ctx in pairs(config.contexts) do
    table.insert(lines, name .. ":")
    for key, val in pairs(ctx) do
      if key ~= "description" then
        if key == "password" then
          table.insert(lines, "  " .. key .. ": " .. val)
        else
          table.insert(lines, "  " .. key .. ": " .. val)
        end
      end
    end
    table.insert(lines, "")
  end

  return write_file(config_path, table.concat(lines, "\n"))
end

-- ─── Sincronizar con sap-connections.json de Neovim ─────────────────────────

local function sync_to_neovim(config)
  local connections = {}
  for name, ctx in pairs(config.contexts) do
    connections[name] = {
      ashost = ctx.ashost or "",
      sysnr = ctx.sysnr or "00",
      client = ctx.client or "100",
      port = tonumber(ctx.port) or 443,
      user = ctx.user or "",
      ssl = ctx.ssl ~= "false",
      system_id = (ctx.sysid or name):upper():sub(1, 3),
      description = ctx.description or ("Conexión " .. name),
    }
  end

  local output = vim.fn.json_encode({
    current = config.current,
    connections = connections,
  })

  vim.fn.mkdir(vim.fn.fnamemodify(nvim_connections_path, ":h"), "p")
  write_file(nvim_connections_path, output)
  return connections
end

-- ─── Verificar sapcli ────────────────────────────────────────────────────────

local function check_sapcli()
  local ok, path = shell("which sapcli 2>/dev/null")
  if not ok or path == "" then
    return false, "sapcli no está instalado. Ejecuta: pip3 install sapcli"
  end
  return true, vim.trim(path)
end

-- ─── Probar conexión ─────────────────────────────────────────────────────────

local function test_connection(ctx_name)
  notify("Probando conexión '" .. ctx_name .. "'...")

  -- Construir args desde la configuración
  local config = parse_sapcli_config()
  local ctx = config.contexts[ctx_name]
  if not ctx then
    notify("Contexto '" .. ctx_name .. "' no encontrado", vim.log.levels.ERROR)
    return
  end

  local args = { "sapcli" }
  if ctx.ashost then table.insert(args, "--ashost"); table.insert(args, ctx.ashost) end
  if ctx.sysnr then table.insert(args, "--sysnr"); table.insert(args, ctx.sysnr) end
  if ctx.client then table.insert(args, "--client"); table.insert(args, ctx.client) end
  if ctx.port then table.insert(args, "--port"); table.insert(args, ctx.port) end
  if ctx.user then table.insert(args, "--user"); table.insert(args, ctx.user) end
  if ctx.password then table.insert(args, "--password"); table.insert(args, ctx.password) end
  if ctx.ssl == "false" then table.insert(args, "--no-ssl") end
  table.insert(args, "abap")
  table.insert(args, "search")
  table.insert(args, "Z*")

  vim.fn.jobstart(args, {
    on_stdout = function(_, data)
      if data then
        local lines = vim.iter(data):filter(function(l) return l ~= "" end):totable()
        if #lines > 0 then
          notify("Conexión OK: " .. #lines .. " resultados para Z*")
        end
      end
    end,
    on_stderr = function(_, data)
      if data then
        local err_lines = vim.iter(data):filter(function(l) return l ~= "" end):totable()
        if #err_lines > 0 then
          notify("Error de conexión: " .. err_lines[1], vim.log.levels.ERROR)
        end
      end
    end,
    on_exit = function(_, code)
      if code == 0 then
        notify("✅ Conexión '" .. ctx_name .. "' verificada correctamente")
      else
        notify("❌ Conexión falló (código " .. code .. ")", vim.log.levels.ERROR)
      end
    end,
  })
end

-- ─── UI: Cuadro de diálogo con inputs ────────────────────────────────────────

local function input_dialog(title, fields, callback)
  -- Crea un buffer temporal con campos para rellenar
  local buf = vim.api.nvim_create_buf(false, true)
  local width = 72
  local height = #fields + 4
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })

  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].modified = false
  vim.wo[win].cursorline = false

  -- Cabecera con instrucciones
  local lines = { "  Completá los campos. Editá y guardá (:wq) para confirmar." }
  for _, field in ipairs(fields) do
    local label = string.format("  %-20s = %s", field.key, field.value or "")
    table.insert(lines, label)
  end
  table.insert(lines, "")
  table.insert(lines, "  ─ Guardá con :wq · Cancelá con :cq ─")

  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  -- Autocmd para capturar al guardar
  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local values = {}
      for _, line in ipairs(content) do
        local key, val = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
        if key and val then
          values[key] = val
        end
      end
      vim.api.nvim_buf_delete(buf, { force = true })
      if win and vim.api.nvim_win_is_valid(win) then
        vim.api.nvim_win_close(win, true)
      end
      callback(values)
    end,
  })

  -- Cancel con :cq
  vim.api.nvim_create_autocmd("QuitPre", {
    buffer = buf,
    once = true,
    callback = function()
      if vim.v.this_session ~= "" then
        pcall(vim.api.nvim_buf_delete, buf, { force = true })
        pcall(vim.api.nvim_win_close, win, true)
      end
    end,
  })
end

-- ─── UI: Menú principal con telescopio-like ──────────────────────────────────

local function show_main_menu()
  local items = {
    { label = "1. Nueva conexión SAP",       action = "new" },
    { label = "2. Editar conexión existente", action = "edit" },
    { label = "3. Ver conexiones",            action = "view" },
    { label = "4. Probar conexión",           action = "test" },
    { label = "5. Eliminar conexión",         action = "delete" },
    { label = "6. Instalar/verificar sapcli", action = "install" },
    { label = "7. Salir",                     action = "exit" },
  }

  vim.ui.select(items, {
    prompt = "╔══════════════════════════════╗\n║  sap-nvim — Configuración SAP  ║\n╚══════════════════════════════╝\nSeleccioná una opción:",
    format_item = function(item) return item.label end,
  }, function(choice)
    if not choice then return end

    if choice.action == "new" then
      show_new_connection()
    elseif choice.action == "edit" then
      show_edit_connection()
    elseif choice.action == "view" then
      show_connections()
    elseif choice.action == "test" then
      show_test_connection()
    elseif choice.action == "delete" then
      show_delete_connection()
    elseif choice.action == "install" then
      install_sapcli()
    elseif choice.action == "exit" then
      notify("Configuración cerrada")
    end
  end)
end

-- ─── Nueva conexión ──────────────────────────────────────────────────────────

function show_new_connection()
  input_dialog("NUEVA CONEXIÓN", {
    { key = "name",     value = "desarrollo" },
    { key = "ashost",   value = "" },
    { key = "sysnr",    value = "00" },
    { key = "client",   value = "100" },
    { key = "port",     value = "443" },
    { key = "user",     value = "" },
    { key = "password", value = "" },
    { key = "ssl",      value = "true" },
    { key = "sysid",    value = "" },
    { key = "description", value = "" },
  }, function(values)
    local name = values["name"]
    if not name or name == "" then
      notify("Nombre de conexión requerido", vim.log.levels.ERROR)
      return
    end

    local config = parse_sapcli_config()
    if config.contexts[name] then
      notify("La conexión '" .. name .. "' ya existe. Usá 'Editar' para modificarla.", vim.log.levels.WARN)
      return
    end

    config.contexts[name] = {
      ashost = values["ashost"] or "",
      sysnr = values["sysnr"] or "00",
      client = values["client"] or "100",
      port = values["port"] or "443",
      user = values["user"] or "",
      password = values["password"] or "",
      ssl = values["ssl"] or "true",
      sysid = values["sysid"] or "",
      description = values["description"] or ("Conexión " .. name),
    }

    if not config.current or config.current == "" then
      config.current = name
    end

    if write_sapcli_config(config) then
      sync_to_neovim(config)
      notify("✅ Conexión '" .. name .. "' guardada. Usá <leader>a" .. (#vim.tbl_keys(config.contexts)) .. " para seleccionarla.")
    end
  end)
end

-- ─── Editar conexión ─────────────────────────────────────────────────────────

function show_edit_connection()
  local config = parse_sapcli_config()
  local names = vim.tbl_keys(config.contexts)

  if #names == 0 then
    notify("No hay conexiones configuradas. Creá una nueva primero.", vim.log.levels.INFO)
    return
  end

  vim.ui.select(names, {
    prompt = "Seleccioná la conexión a editar:",
  }, function(name)
    if not name then return end
    local ctx = config.contexts[name]

    input_dialog("EDITAR: " .. name, {
      { key = "ashost",   value = ctx.ashost or "" },
      { key = "sysnr",    value = ctx.sysnr or "00" },
      { key = "client",   value = ctx.client or "100" },
      { key = "port",     value = ctx.port or "443" },
      { key = "user",     value = ctx.user or "" },
      { key = "password", value = ctx.password or "" },
      { key = "ssl",      value = ctx.ssl or "true" },
      { key = "sysid",    value = ctx.sysid or "" },
      { key = "description", value = ctx.description or "" },
    }, function(values)
      config.contexts[name] = {
        ashost = values["ashost"] or "",
        sysnr = values["sysnr"] or "00",
        client = values["client"] or "100",
        port = values["port"] or "443",
        user = values["user"] or "",
        password = values["password"] or "",
        ssl = values["ssl"] or "true",
        sysid = values["sysid"] or "",
        description = values["description"] or ("Conexión " .. name),
      }

      if write_sapcli_config(config) then
        sync_to_neovim(config)
        notify("✅ Conexión '" .. name .. "' actualizada.")
      end
    end)
  end)
end

-- ─── Ver conexiones ──────────────────────────────────────────────────────────

function show_connections()
  local config = parse_sapcli_config()
  local names = vim.tbl_keys(config.contexts)

  if #names == 0 then
    notify("No hay conexiones configuradas.", vim.log.levels.INFO)
    return
  end

  local lines = { "Conexiones SAP configuradas:", "" }
  table.sort(names)
  for _, name in ipairs(names) do
    local ctx = config.contexts[name]
    local active = (name == config.current) and " ★ ACTIVA" or ""
    table.insert(lines, string.format("  %s%s", name, active))
    if ctx.ashost and ctx.ashost ~= "" then
      table.insert(lines, string.format("    ashost: %s  sysnr: %s  client: %s",
        ctx.ashost, ctx.sysnr or "00", ctx.client or "100"))
    end
    table.insert(lines, "")
  end

  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].bufhidden = "wipe"

  local width = 64
  local height = #lines + 2
  local row = math.floor((vim.o.lines - height) / 2)
  local col = math.floor((vim.o.columns - width) / 2)

  vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = row,
    col = col,
    style = "minimal",
    border = "rounded",
    title = " Conexiones SAP ",
    title_pos = "center",
  })

  vim.keymap.set("n", "q", "<cmd>q<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>q<CR>", { buffer = buf, nowait = true })
end

-- ─── Probar conexión ─────────────────────────────────────────────────────────

function show_test_connection()
  local config = parse_sapcli_config()
  local names = vim.tbl_keys(config.contexts)

  if #names == 0 then
    notify("No hay conexiones para probar.", vim.log.levels.INFO)
    return
  end

  vim.ui.select(names, {
    prompt = "Seleccioná la conexión a probar:",
  }, function(name)
    if name then test_connection(name) end
  end)
end

-- ─── Eliminar conexión ───────────────────────────────────────────────────────

function show_delete_connection()
  local config = parse_sapcli_config()
  local names = vim.tbl_keys(config.contexts)

  if #names == 0 then
    notify("No hay conexiones para eliminar.", vim.log.levels.INFO)
    return
  end

  vim.ui.select(names, {
    prompt = "Seleccioná la conexión a eliminar (⚠️ esta acción no se puede deshacer):",
  }, function(name)
    if not name then return end
    config.contexts[name] = nil
    if config.current == name then
      local remaining = vim.tbl_keys(config.contexts)
      config.current = remaining[1] or ""
    end
    if write_sapcli_config(config) then
      sync_to_neovim(config)
      notify("🗑️ Conexión '" .. name .. "' eliminada.")
    end
  end)
end

-- ─── Instalar/verificar sapcli ───────────────────────────────────────────────

function install_sapcli()
  local ok, path = check_sapcli()
  if ok then
    notify("✅ sapcli ya está instalado: " .. path)
    -- Ver version
    local _, ver = shell("sapcli --version 2>&1")
    notify("Versión: " .. vim.trim(ver))
    return
  end

  notify("Instalando sapcli...")
  vim.fn.jobstart({ "pip3", "install", "sapcli" }, {
    on_exit = function(_, code)
      if code == 0 then
        notify("✅ sapcli instalado correctamente. Ejecutá :SapSetup de nuevo para configurar conexiones.")
      else
        notify("❌ Error al instalar sapcli. Intentá: pip3 install sapcli", vim.log.levels.ERROR)
      end
    end,
  })
end

-- ─── Entry point ─────────────────────────────────────────────────────────────

function M.setup()
  vim.api.nvim_create_user_command("SapSetup", function()
    show_main_menu()
  end, { desc = "sap-nvim: Asistente de configuración SAP interactivo" })

  -- También crear alias rápido
  vim.keymap.set("n", "<leader>asc", function()
    show_main_menu()
  end, { desc = "ABAP: Configurar conexiones SAP" })

  -- Cargar conexiones existentes al iniciar
  local config = parse_sapcli_config()
  if next(config.contexts) then
    vim.g.sap_nvim_connections = sync_to_neovim(config)
  end
end

return M
