-- sap-nvim.core.setup
-- :SapSetup — interactive SAP connection wizard.
--
-- Connections live in sapcli's own kubeconfig-style file (~/.sapcli/config.yml)
-- and are managed EXCLUSIVELY through `sapcli config` subcommands. That file is
-- the single source of truth; we never hand-write its YAML. This guarantees the
-- format always matches whatever sapcli version is installed.
--
-- Model (kubeconfig-style):
--   connection  → host/port/client/ssl          (sapcli config set-connection)
--   user        → user alias + password          (sapcli config set-user)
--   context     → connection + user reference     (sapcli config set-context)
--   current-context → the active context          (sapcli config use-context)

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ─── sapcli runner ────────────────────────────────────────────────────────────

-- Run a command synchronously. Returns ok(boolean), lines(string[]).
local function run(args)
  local lines = vim.fn.systemlist(args)
  return vim.v.shell_error == 0, lines
end

local function sapcli_available()
  return vim.fn.executable("sapcli") == 1
end

-- ─── Read current config via sapcli ──────────────────────────────────────────

-- List of context names from `sapcli config get-contexts`.
-- Output columns are: "[* ]NAME  CONNECTION  USER"; we take the first token.
local function get_contexts()
  local ok, lines = run({ "sapcli", "config", "get-contexts" })
  if not ok then return {} end
  local names = {}
  for _, line in ipairs(lines) do
    local l = vim.trim(line)
    if l ~= "" and l ~= "No contexts defined." then
      l = l:gsub("^%*%s*", "") -- strip "current" marker
      local name = l:match("^(%S+)")
      if name then table.insert(names, name) end
    end
  end
  return names
end

local function current_context()
  local ok, lines = run({ "sapcli", "config", "current-context" })
  if ok and lines[1] then
    local c = vim.trim(lines[1])
    if c ~= "" and not c:match("No configuration") then return c end
  end
  return nil
end

-- ─── Write config via sapcli ─────────────────────────────────────────────────

-- Creates connection + user + context and activates it. `v` is the field table.
local function create_connection(v)
  local name = v.name
  if not name or name == "" then
    notify("Nombre de conexión requerido", vim.log.levels.ERROR)
    return
  end

  local conn = {
    "sapcli", "config", "set-connection", name,
    "--ashost", v.ashost or "",
    "--client", v.client or "100",
    "--port", v.port or "44300",
  }
  if (v.ssl or "true") == "false" then
    table.insert(conn, "--no-ssl")
  else
    table.insert(conn, "--ssl")
  end

  local user_ref = name .. "-user"
  local user = { "sapcli", "config", "set-user", user_ref, "--user", v.user or "" }
  if v.password and v.password ~= "" then
    table.insert(user, "--password")
    table.insert(user, v.password)
  end

  local ctx = {
    "sapcli", "config", "set-context", name,
    "--connection", name, "--user", user_ref,
  }

  for _, args in ipairs({ conn, user, ctx }) do
    local ok, out = run(args)
    if not ok then
      notify("Error configurando: " .. table.concat(out, " "), vim.log.levels.ERROR)
      return
    end
  end

  run({ "sapcli", "config", "use-context", name })

  -- Harden the config file. It stores the password in plaintext, so on a shared
  -- machine no other user must be able to read it. 0600 = owner read/write only.
  local cfg = vim.fn.expand("~/.sapcli/config.yml")
  pcall(vim.loop.fs_chmod, cfg, tonumber("600", 8))

  notify("✅ Conexión '" .. name .. "' creada y activada (config 0600). Verificá con :SapDoctor")
end

-- Deletes a context and its dedicated connection/user (best-effort).
local function delete_connection(name)
  run({ "sapcli", "config", "delete-context", name })
  run({ "sapcli", "config", "delete-connection", name })
  run({ "sapcli", "config", "delete-user", name .. "-user" })
  notify("🗑️ Conexión '" .. name .. "' eliminada.")
end

-- ─── Read-only connection test (LIVE — contacts the SAP system) ───────────────

local function test_connection()
  notify("Probando conexión (sapcli abap systeminfo)... [llamada de SOLO LECTURA]")
  local lines = {}
  vim.fn.jobstart({ "sapcli", "abap", "systeminfo" }, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do if l ~= "" then table.insert(lines, l) end end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do if vim.trim(l) ~= "" then table.insert(lines, l) end end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          notify("✅ Conexión OK:\n" .. table.concat(lines, "\n"))
        else
          notify("❌ Falló (code " .. code .. "):\n" .. table.concat(lines, "\n"),
            vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

-- ─── UI: input dialog (edit fields in a scratch buffer, :wq to confirm) ───────

local function input_dialog(title, fields, callback)
  local buf = vim.api.nvim_create_buf(false, true)
  local width = 72
  local height = #fields + 4
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " " .. title .. " ",
    title_pos = "center",
  })
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].bufhidden = "wipe"

  local lines = { "  Completá los campos. Guardá con :wq · Cancelá con :cq" }
  for _, field in ipairs(fields) do
    table.insert(lines, string.format("  %-12s = %s", field.key, field.value or ""))
  end
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    once = true,
    callback = function()
      local content = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
      local values = {}
      for _, line in ipairs(content) do
        local key, val = line:match("^%s*(%w+)%s*=%s*(.-)%s*$")
        if key then values[key] = val end
      end
      pcall(vim.api.nvim_buf_delete, buf, { force = true })
      if vim.api.nvim_win_is_valid(win) then pcall(vim.api.nvim_win_close, win, true) end
      callback(values)
    end,
  })
end

-- ─── UI flows ─────────────────────────────────────────────────────────────────

local function flow_new()
  input_dialog("NUEVA CONEXIÓN SAP", {
    { key = "name",     value = "dev" },
    { key = "ashost",   value = "" },
    { key = "port",     value = "44300" },
    { key = "client",   value = "100" },
    { key = "user",     value = "" },
    { key = "password", value = "" },
    { key = "ssl",      value = "true" },
  }, create_connection)
end

local function flow_view()
  local ok, lines = run({ "sapcli", "config", "view" })
  if not ok or #lines == 0 then
    notify("No hay configuración. Creá una conexión primero.")
    return
  end
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].bufhidden = "wipe"
  vim.bo[buf].filetype = "yaml"
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = 72,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - 72) / 2),
    style = "minimal",
    border = "rounded",
    title = " Configuración SAP (~/.sapcli/config.yml) ",
    title_pos = "center",
  })
  vim.keymap.set("n", "q", "<cmd>q<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>q<CR>", { buffer = buf, nowait = true })
  vim.wo[win].cursorline = true
end

local function flow_select_then(action_label, action_fn)
  local names = get_contexts()
  if #names == 0 then
    notify("No hay conexiones configuradas.")
    return
  end
  vim.ui.select(names, { prompt = action_label }, function(name)
    if name then action_fn(name) end
  end)
end

local function flow_use()
  flow_select_then("Activar conexión:", function(name)
    local ok = run({ "sapcli", "config", "use-context", name })
    notify(ok and ("✅ Activada: " .. name) or ("Error activando " .. name),
      ok and vim.log.levels.INFO or vim.log.levels.ERROR)
  end)
end

local function install_sapcli()
  if sapcli_available() then
    local _, ver = run({ "sapcli", "--version" })
    notify("✅ sapcli instalado: " .. table.concat(ver, " "))
    return
  end
  notify("Instalando sapcli (pip install sapcli)...")
  vim.fn.jobstart({ "pip3", "install", "sapcli" }, {
    on_exit = function(_, code)
      vim.schedule(function()
        notify(code == 0 and "✅ sapcli instalado." or "❌ Error. Probá: pip install sapcli",
          code == 0 and vim.log.levels.INFO or vim.log.levels.ERROR)
      end)
    end,
  })
end

-- ─── Main menu ────────────────────────────────────────────────────────────────

local function main_menu()
  if not sapcli_available() then
    notify("sapcli no está instalado. Opción 6 lo instala, o: pip install sapcli",
      vim.log.levels.WARN)
  end

  local cur = current_context()
  local items = {
    { label = "1. Nueva conexión SAP", action = flow_new },
    { label = "2. Ver configuración", action = flow_view },
    { label = "3. Activar conexión", action = flow_use },
    { label = "4. Probar conexión (solo lectura)", action = test_connection },
    { label = "5. Eliminar conexión", action = function()
      flow_select_then("Eliminar conexión (no se puede deshacer):", delete_connection)
    end },
    { label = "6. Instalar/verificar sapcli", action = install_sapcli },
  }

  vim.ui.select(items, {
    prompt = "sap-nvim — Configuración SAP" .. (cur and (" [activa: " .. cur .. "]") or ""),
    format_item = function(item) return item.label end,
  }, function(choice)
    if choice then choice.action() end
  end)
end

-- ─── Entry point ──────────────────────────────────────────────────────────────

function M.setup()
  vim.api.nvim_create_user_command("SapSetup", main_menu,
    { desc = "sap-nvim: Asistente de conexión SAP (kubeconfig sapcli)" })

  vim.keymap.set("n", "<leader>asc", main_menu, { desc = "ABAP: Configurar conexiones SAP" })
end

return M
