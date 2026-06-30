-- sap-nvim.core.doctor
-- :SapDoctor — one-shot, READ-ONLY validator for a configured SAP system.
--
-- Runs the safe validation ladder: local tooling first, then live read-only
-- ADT calls (system info, object search, transport list). It never writes,
-- activates, or locks anything. Use it on a fresh machine to confirm the whole
-- chain (sapcli → connection → objects → transports) works end to end.

local M = {}
local sapcli = require("sap-nvim.core.sapcli")
local config = require("sap-nvim.core.config")

local function open_report(lines)
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modified = false
  vim.bo[buf].bufhidden = "wipe"
  local width = 76
  local height = math.min(#lines + 2, vim.o.lines - 6)
  local win = vim.api.nvim_open_win(buf, true, {
    relative = "editor",
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = "minimal",
    border = "rounded",
    title = " :SapDoctor — diagnóstico SAP (solo lectura) ",
    title_pos = "center",
  })
  vim.wo[win].cursorline = true
  vim.keymap.set("n", "q", "<cmd>q<CR>", { buffer = buf, nowait = true })
  vim.keymap.set("n", "<Esc>", "<cmd>q<CR>", { buffer = buf, nowait = true })
end

local function mark(ok)
  return ok and "  ✅ " or "  ❌ "
end

local function warn(ok)
  return ok and "  ✅ " or "  ⚠ "
end

local function sapcli_config_path()
  return vim.fn.expand("~/.sapcli/config.yml")
end

local function read_sapcli_config()
  local f = io.open(sapcli_config_path(), "r")
  if not f then return nil end
  local content = f:read("*a") or ""
  f:close()
  return content
end

local function current_context_from_config(content)
  return tostring(content or ""):match("current%-context:%s*([%w_%-]+)")
end

local function legacy_password_present(content)
  content = tostring(content or "")
  return content:match("^%s*password:%s*%S+") ~= nil
    or content:match("\n%s*password:%s*%S+") ~= nil
end

local function config_permissions_ok(path)
  local st = vim.loop.fs_stat(path)
  if not st then return true, "sin archivo" end
  return (st.mode % 64) == 0, string.format("%o", st.mode % 512)
end

local function connection_state(adt_http)
  if not adt_http then
    return false, "no disponible"
  end
  local ready = adt_http.ready and adt_http.ready() == true
  if ready then
    return true, "validada"
  end
  local needs_login = adt_http.needs_login and adt_http.needs_login() == true
  if needs_login then
    return false, "pausada/no validada; posible 401 previo, usa :SapRelogin"
  end
  return false, "no validada; usa :SapLogin"
end

local function productive_readiness_lines(opts)
  opts = opts or {}
  local cfg = opts.config or config
  local sec = cfg.security()
  local prod = cfg.productive()
  local profile = cfg.profile_name and cfg.profile_name() or "dev"
  local sapcli_cfg = opts.sapcli_config
  if sapcli_cfg == nil then sapcli_cfg = read_sapcli_config() end
  local current_context = current_context_from_config(sapcli_cfg)
  local ok_adt, adt_http
  if opts.adt_http ~= nil then
    adt_http = opts.adt_http
    ok_adt = adt_http ~= false
  else
    ok_adt, adt_http = pcall(require, "sap-nvim.core.adt_http")
  end
  local ctx = ok_adt and adt_http and adt_http.context_info and adt_http.context_info() or nil
  local ready_ok, ready_detail = connection_state(ok_adt and adt_http or nil)
  local perm_ok, perm_detail = config_permissions_ok(sapcli_config_path())
  local ca_needed = prod.require_tls ~= false and sec.ca_file and sec.ca_file ~= ""
  local ca_ok = not ca_needed or vim.fn.filereadable(vim.fn.expand(sec.ca_file)) == 1
  local tls_ok = prod.require_tls == false or sec.verify_tls == true
  local transport_safe = prod.allow_release_transports ~= true
    and prod.allow_delete_transports ~= true
    and prod.allow_reassign_transports ~= true
    and prod.allow_transport_task_post ~= true

  local lines = {
    "Productivo/seguridad:",
    (profile == "prod" and mark(true) or warn(true)) .. "perfil activo: " .. profile:upper() .. " (dev/qa/prod)",
    mark(current_context ~= nil) .. "current-context: " .. tostring(current_context or "no configurado"),
    mark(perm_ok) .. "~/.sapcli/config.yml permisos 0600" .. (perm_detail and (" (" .. perm_detail .. ")") or ""),
    mark(not legacy_password_present(sapcli_cfg)) .. "~/.sapcli/config.yml sin password legacy",
    mark(sec.allow_plaintext_password ~= true) .. "password legacy deshabilitada por configuración",
    mark(tls_ok) .. "TLS verify_tls requerido/listo" .. (tls_ok and "" or " (configura security.verify_tls=true)"),
  }

  if sec.ca_file and sec.ca_file ~= "" then
    table.insert(lines, mark(ca_ok) .. "CA file legible: " .. vim.fn.expand(sec.ca_file))
  elseif prod.require_tls ~= false then
    table.insert(lines, warn(true) .. "CA file no configurado; válido si el trust store del sistema cubre SAP")
  end

  table.insert(lines, mark(prod.safe_mode == true) .. "safe_mode activo")
  table.insert(lines, mark(prod.confirm_destructive ~= false) .. "confirmación fuerte para acciones destructivas")
  table.insert(lines, mark(prod.audit_sensitive_actions ~= false) .. "auditoría local de acciones sensibles")
  table.insert(lines, mark(profile ~= "prod" or prod.read_only == true) .. "prod read_only por defecto")
  table.insert(lines, mark(profile ~= "prod" or prod.allow_create_objects ~= true) .. "create bloqueado en prod salvo opt-in")
  table.insert(lines, mark(profile ~= "prod" or prod.allow_write_objects ~= true) .. "write/activate bloqueado en prod salvo opt-in")
  table.insert(lines, mark(profile ~= "prod" or prod.allow_release_transports ~= true) .. "release transporte bloqueado en prod salvo opt-in")
  table.insert(lines, mark(prod.allow_delete_objects ~= true) .. "borrado remoto de objetos bloqueado")
  table.insert(lines, mark(prod.allow_delete_transports ~= true) .. "borrado de transportes bloqueado")
  table.insert(lines, mark(prod.allow_debug_set_variable ~= true) .. "debug set-variable bloqueado")
  table.insert(lines, mark(transport_safe) .. "acciones CTS destructivas bloqueadas por defecto")
  table.insert(lines, mark(ready_ok) .. "conexión ADT: " .. ready_detail)
  if ctx then
    table.insert(lines, warn(true) .. "contexto visible: "
      .. tostring(ctx.sysid or "???") .. "/" .. tostring(ctx.client or "???")
      .. "/" .. tostring(ctx.user or "???"))
  else
    table.insert(lines, warn(false) .. "contexto visible: no se pudo leer SID/mandante/usuario")
  end

  return lines
end

local function auth_hint(lines)
  local text = table.concat(lines or {}, "\n"):lower()
  if text == "" then return nil end
  if text:match("401") or text:match("unauthorized") or text:match("nicht autorisiert") or text:match("no autorizado") then
    return "credenciales/login ADT rechazado"
  end
  if text:match("403") or text:match("forbidden") or text:match("not authorized") or text:match("no tiene autoriz") then
    return "autorización SAP insuficiente para el endpoint"
  end
  if text:match("s_develop") or text:match("s_adt") or text:match("s_cts") or text:match("s_transport") then
    return "revisar roles/autorizaciones ADT/CTS/S_DEVELOP"
  end
  if text:match("transport") and (text:match("authorization") or text:match("autoriz")) then
    return "autorización CTS/transporte insuficiente"
  end
  return nil
end

function M.run()
  local results = { "Local:" }
  local permission_signals = {}

  -- ── Local checks (no SAP contact) ──
  local local_checks = {
    { "sapcli instalado",   function() return vim.fn.executable("sapcli") == 1 end },
    { "abaplint instalado", function() return vim.fn.executable("abaplint") == 1 end },
    { "current-context configurado", function()
      local c = sapcli.systemlist({ "sapcli", "config", "current-context" })
      return vim.v.shell_error == 0 and c[1] ~= nil and not c[1]:match("No configuration")
    end },
    { "~/.sapcli/config.yml protegido (0600)", function()
      local st = vim.loop.fs_stat(vim.fn.expand("~/.sapcli/config.yml"))
      if not st then return true end -- sin archivo todavía, nada que filtrar
      -- Inseguro si el grupo u otros tienen cualquier permiso (bits bajos != 0).
      return (st.mode % 64) == 0
    end },
    { "~/.sapcli/config.yml sin password legacy", function()
      return not legacy_password_present(read_sapcli_config())
    end },
  }
  for _, c in ipairs(local_checks) do
    table.insert(results, mark(c[2]()) .. c[1])
  end

  table.insert(results, "")
  for _, line in ipairs(productive_readiness_lines()) do
    table.insert(results, line)
  end

  if vim.fn.executable("sapcli") ~= 1 then
    table.insert(results, "")
    table.insert(results, "  sapcli falta — instalá con: pipx install git+https://github.com/jfilak/sapcli.git")
    open_report(results)
    return
  end

  table.insert(results, "")
  table.insert(results, "En vivo ADT (contactan el sistema SAP — SOLO LECTURA):")

  local function finish()
    if #permission_signals > 0 then
      table.insert(results, "")
      table.insert(results, "Permisos/autorizaciones detectados:")
      for _, hint in ipairs(permission_signals) do
        table.insert(results, "  ⚠ " .. hint)
      end
      table.insert(results, "  Validación SAP: SU53 tras el fallo; STAUTHTRACE para /sap/bc/adt/* si persiste.")
    end
    table.insert(results, "")
    table.insert(results, "  q / <Esc> para cerrar.")
    vim.schedule(function() open_report(results) end)
  end

  local function run_sapcli_read(label, cmd, cb)
    local out = {}
    sapcli.jobstart(cmd, {
      on_stdout = function(_, d)
        for _, l in ipairs(d) do if l ~= "" then out[#out + 1] = l end end
      end,
      on_stderr = function(_, d)
        for _, l in ipairs(d) do if vim.trim(l) ~= "" then out[#out + 1] = l end end
      end,
      on_exit = function(_, code)
        local detail = out[1] and ("  → " .. out[1]) or ""
        table.insert(results, mark(code == 0) .. label .. detail)
        local hint = auth_hint(out)
        if hint then
          permission_signals[#permission_signals + 1] = label .. ": " .. hint
        end
        cb()
      end,
    })
  end

  local function run_live_checks()
    local adt_http = require("sap-nvim.core.adt_http")
    local adt = require("sap-nvim.core.adt")

    local body, _, code = adt_http.raw({
      method = "GET",
      path = "/sap/bc/adt/core/discovery",
      accept = "application/atomsvc+xml, application/xml;q=0.9, */*;q=0.8",
    })
    local discovery_ok = code >= 200 and code < 400 and body and body ~= ""
    table.insert(results, mark(discovery_ok) .. "Discovery ADT  → HTTP " .. tostring(code))
    if not discovery_ok then
      local hint = auth_hint({ tostring(code), body or "" })
      if hint then permission_signals[#permission_signals + 1] = "Discovery ADT: " .. hint end
    end

    adt.find_objects_async("*", function(objects, err)
      local ok = objects ~= nil
      table.insert(results, mark(ok) .. "Búsqueda global ADT (*)" .. (ok and ("  → " .. tostring(#objects) .. " resultado(s)") or ("  → " .. tostring(err))))
      if not ok then
        local hint = auth_hint({ err or "" })
        if hint then permission_signals[#permission_signals + 1] = "Búsqueda global ADT: " .. hint end
      end

      adt.fetch_inactive_objects(function(inactive, ierr)
        local iok = inactive ~= nil
        table.insert(results, mark(iok) .. "Objetos inactivos ADT" .. (iok and ("  → " .. tostring(#inactive) .. " objeto(s)") or ("  → " .. tostring(ierr))))
        if not iok then
          local hint = auth_hint({ ierr or "" })
          if hint then permission_signals[#permission_signals + 1] = "Objetos inactivos ADT: " .. hint end
        end

        table.insert(results, "")
        table.insert(results, "En vivo sapcli wrapper (solo lectura/fallback):")
        run_sapcli_read("Transportes visibles (cts list transport)", { "sapcli", "cts", "list", "transport" }, finish)
      end)
    end)
  end

  require("sap-nvim.core.connection").ensure(function(ok)
    if ok then
      run_live_checks()
    else
      table.insert(results, "  ❌ Login SAP no validado. Ejecuta :SapLogin y repite :SapDoctor.")
      table.insert(results, "")
      table.insert(results, "  q / <Esc> para cerrar.")
      open_report(results)
    end
  end)
end

M._productive_readiness_lines = productive_readiness_lines
M._legacy_password_present = legacy_password_present

function M.setup()
  vim.api.nvim_create_user_command("SapDoctor", M.run,
    { desc = "sap-nvim: Validar conexión y operaciones SAP (solo lectura)" })
  vim.keymap.set("n", "<leader>asd", M.run, { desc = "ABAP: Diagnóstico SAP (SapDoctor)" })
end

return M
