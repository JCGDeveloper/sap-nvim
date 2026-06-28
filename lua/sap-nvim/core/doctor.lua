-- sap-nvim.core.doctor
-- :SapDoctor — one-shot, READ-ONLY validator for a configured SAP system.
--
-- Runs the safe validation ladder: local tooling first, then live read-only
-- ADT calls (system info, object search, transport list). It never writes,
-- activates, or locks anything. Use it on a fresh machine to confirm the whole
-- chain (sapcli → connection → objects → transports) works end to end.

local M = {}
local sapcli = require("sap-nvim.core.sapcli")

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
    { "~/.sapcli/config.yml protegido (0600 — clave en texto plano)", function()
      local st = vim.loop.fs_stat(vim.fn.expand("~/.sapcli/config.yml"))
      if not st then return true end -- sin archivo todavía, nada que filtrar
      -- Inseguro si el grupo u otros tienen cualquier permiso (bits bajos != 0).
      return (st.mode % 64) == 0
    end },
  }
  for _, c in ipairs(local_checks) do
    table.insert(results, mark(c[2]()) .. c[1])
  end

  if vim.fn.executable("sapcli") ~= 1 then
    table.insert(results, "")
    table.insert(results, "  sapcli falta — instalá con: pipx install git+https://github.com/jfilak/sapcli.git")
    open_report(results)
    return
  end

  table.insert(results, "")
  table.insert(results, "En vivo (contactan el sistema SAP — SOLO LECTURA):")

  -- ── Live read-only ladder, chained ──
  local live = {
    { "Conectividad + login (abap systeminfo)", { "sapcli", "abap", "systeminfo" } },
    { "Objetos inactivos (activation inactiveobjects list)", { "sapcli", "activation", "inactiveobjects", "list" } },
    { "Búsqueda global de objetos (abap find *)", { "sapcli", "abap", "find", "--max-results", "5", "*" } },
    { "Transportes visibles (cts list transport)", { "sapcli", "cts", "list", "transport" } },
  }

  local i = 0
  local function step()
    i = i + 1
    local s = live[i]
    if not s then
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
      return
    end
    local out = {}
    vim.fn.jobstart(s[2], {
      on_stdout = function(_, d)
        for _, l in ipairs(d) do if l ~= "" then out[#out + 1] = l end end
      end,
      on_stderr = function(_, d)
        for _, l in ipairs(d) do if vim.trim(l) ~= "" then out[#out + 1] = l end end
      end,
      on_exit = function(_, code)
        local detail = out[1] and ("  → " .. out[1]) or ""
        table.insert(results, mark(code == 0) .. s[1] .. detail)
        local hint = auth_hint(out)
        if hint then
          permission_signals[#permission_signals + 1] = s[1] .. ": " .. hint
        end
        step()
      end,
    })
  end

  require("sap-nvim.core.connection").ensure(function(ok)
    if ok then
      step()
    else
      table.insert(results, "  ❌ Login SAP no validado. Ejecuta :SapLogin y repite :SapDoctor.")
      table.insert(results, "")
      table.insert(results, "  q / <Esc> para cerrar.")
      open_report(results)
    end
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapDoctor", M.run,
    { desc = "sap-nvim: Validar conexión y operaciones SAP (solo lectura)" })
  vim.keymap.set("n", "<leader>asd", M.run, { desc = "ABAP: Diagnóstico SAP (SapDoctor)" })
end

return M
