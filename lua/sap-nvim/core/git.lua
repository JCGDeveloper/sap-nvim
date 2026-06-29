-- sap-nvim.core.git
-- Integración abapGit / Git (gCTS) usando `sapcli gcts`.
-- Replica la sección de Git de la extensión VSCode (abap-remote-fs):
-- listar repos, log, pull, push, commit, checkout y clone.
--
-- Seguridad §7: pull/push/checkout/clone MODIFICAN el sistema o el repo remoto,
-- por lo que exigen confirmación explícita (vim.ui.select Sí/No) antes de ejecutar.
-- Toda llamada a SAP es async (vim.fn.jobstart + vim.schedule).

local M = {}
local sapcli = require("sap-nvim.core.sapcli")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
-- (Copiado del patrón de core/transport.lua.)
local function show(bufname, lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false
  vim.bo[b].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, b, bufname)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- Pide un valor con vim.ui.input si `value` viene vacío; ejecuta `cb(val)` con el
-- valor recortado (no llama a cb si el usuario cancela o deja vacío).
local function ensure_input(value, prompt, cb)
  if value and vim.trim(value) ~= "" then
    cb(vim.trim(value))
    return
  end
  vim.ui.input({ prompt = prompt }, function(input)
    if not input or vim.trim(input) == "" then return end
    cb(vim.trim(input))
  end)
end

-- Confirmación Sí/No (§7). Llama a `cb()` solo si el usuario elige "Sí, ...".
local function confirm(question, cb)
  vim.ui.select({ "No", "Sí, " .. question }, {
    prompt = "Confirmar (modifica el sistema o el repo remoto):",
  }, function(choice)
    if not choice or not choice:match("^Sí") then return end
    cb()
  end)
end

-- Corre `sapcli gcts <args...>` async; al terminar llama a
-- `on_done(code, stdout_lines, stderr_lines)` dentro de vim.schedule.
local function run_gcts(args, on_done)
  local cmd = { "sapcli", "gcts" }
  for _, a in ipairs(args) do
    table.insert(cmd, a)
  end

  local stdout, stderr = {}, {}
  sapcli.jobstart(cmd, {
    on_stdout = function(_, data)
      for _, line in ipairs(data) do
        if line ~= "" then table.insert(stdout, line) end
      end
    end,
    on_stderr = function(_, data)
      for _, line in ipairs(data) do
        if vim.trim(line) ~= "" then table.insert(stderr, line) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        on_done(code, stdout, stderr)
      end)
    end,
  })
end

-- Notifica el resultado de una operación: éxito o el primer mensaje de error.
local function notify_result(code, stdout, stderr, ok_msg)
  if code == 0 then
    notify(ok_msg)
  else
    local msg = (#stderr > 0 and stderr[1])
      or (#stdout > 0 and stdout[1])
      or ("Error (code " .. code .. ")")
    notify(msg, vim.log.levels.ERROR)
  end
end

-- Listar repos gCTS -> split.
function M.repos()
  notify("Obteniendo repositorios gCTS...")
  run_gcts({ "repolist" }, function(code, stdout, stderr)
    if code ~= 0 or #stdout == 0 then
      local msg = (#stderr > 0 and stderr[1]) or "No hay repositorios gCTS."
      notify(msg, vim.log.levels.WARN)
      return
    end
    show("sap-git://repos", stdout)
  end)
end

-- Ver el log de commits de un paquete -> split.
function M.log(pkg)
  ensure_input(pkg, "Paquete (gCTS log): ", function(p)
    notify("Leyendo log de " .. p .. "...")
    run_gcts({ "log", p }, function(code, stdout, stderr)
      if code ~= 0 or #stdout == 0 then
        local msg = (#stderr > 0 and stderr[1]) or ("No se pudo leer el log de " .. p)
        notify(msg, vim.log.levels.WARN)
        return
      end
      show("sap-git://log/" .. p, stdout)
    end)
  end)
end

-- Pull: trae cambios del repo remoto al sistema (§7 -> confirma).
function M.pull(pkg)
  ensure_input(pkg, "Paquete a hacer PULL: ", function(p)
    confirm("hacer pull en " .. p .. " (sobrescribe objetos locales)", function()
      notify("Haciendo pull en " .. p .. "...")
      run_gcts({ "pull", p }, function(code, stdout, stderr)
        notify_result(code, stdout, stderr, "Pull completado en " .. p)
      end)
    end)
  end)
end

-- Push: envía los cambios al repo remoto (§7 -> confirma).
function M.push(pkg)
  ensure_input(pkg, "Paquete a hacer PUSH: ", function(p)
    confirm("hacer push de " .. p .. " al repo remoto", function()
      notify("Haciendo push de " .. p .. "...")
      run_gcts({ "push", p }, function(code, stdout, stderr)
        notify_result(code, stdout, stderr, "Push completado de " .. p)
      end)
    end)
  end)
end

-- Commit: pide paquete y mensaje (§7 -> confirma).
function M.commit(pkg)
  ensure_input(pkg, "Paquete a hacer COMMIT: ", function(p)
    vim.ui.input({ prompt = "Mensaje de commit: " }, function(msg)
      if not msg or vim.trim(msg) == "" then
        notify("Commit cancelado: mensaje vacío.", vim.log.levels.WARN)
        return
      end
      msg = vim.trim(msg)
      confirm("hacer commit en " .. p, function()
        notify("Haciendo commit en " .. p .. "...")
        run_gcts({ "commit", p, "-m", msg }, function(code, stdout, stderr)
          notify_result(code, stdout, stderr, "Commit creado en " .. p)
        end)
      end)
    end)
  end)
end

-- Checkout: cambia la rama activa del sistema (§7 -> confirma).
function M.checkout(pkg, branch)
  ensure_input(pkg, "Paquete para CHECKOUT: ", function(p)
    ensure_input(branch, "Rama (branch) destino: ", function(b)
      confirm("hacer checkout de " .. p .. " a la rama " .. b .. " (cambia el código del sistema)", function()
        notify("Haciendo checkout de " .. p .. " -> " .. b .. "...")
        run_gcts({ "checkout", p, b }, function(code, stdout, stderr)
          notify_result(code, stdout, stderr, "Checkout de " .. p .. " a " .. b .. " completado")
        end)
      end)
    end)
  end)
end

-- Clone: clona un repo remoto en un paquete (§7 -> confirma; puede tardar).
function M.clone()
  vim.ui.input({ prompt = "URL del repositorio Git: " }, function(url)
    if not url or vim.trim(url) == "" then return end
    url = vim.trim(url)
    vim.ui.input({ prompt = "Paquete destino: " }, function(pkg)
      if not pkg or vim.trim(pkg) == "" then return end
      pkg = vim.trim(pkg)
      confirm("clonar " .. url .. " en el paquete " .. pkg, function()
        notify("Clonando " .. url .. " en " .. pkg .. " (puede tardar)...")
        run_gcts({ "clone", url, pkg }, function(code, stdout, stderr)
          notify_result(code, stdout, stderr, "Clone completado en " .. pkg)
        end)
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapGitRepos", function()
    M.repos()
  end, { desc = "sap-nvim: Listar repositorios gCTS" })

  vim.api.nvim_create_user_command("SapGitLog", function(opts)
    M.log(opts.args)
  end, { nargs = "?", desc = "sap-nvim: Ver log de commits de un paquete" })

  vim.api.nvim_create_user_command("SapGitPull", function(opts)
    M.pull(opts.args)
  end, { nargs = "?", desc = "sap-nvim: Pull gCTS (trae del repo remoto)" })

  vim.api.nvim_create_user_command("SapGitPush", function(opts)
    M.push(opts.args)
  end, { nargs = "?", desc = "sap-nvim: Push gCTS (envía al repo remoto)" })

  vim.api.nvim_create_user_command("SapGitCommit", function(opts)
    M.commit(opts.args)
  end, { nargs = "?", desc = "sap-nvim: Commit gCTS" })

  vim.api.nvim_create_user_command("SapGitCheckout", function(opts)
    -- Acepta "PAQUETE RAMA"; si falta algo, lo pide por vim.ui.input.
    local parts = vim.split(opts.args or "", "%s+", { trimempty = true })
    M.checkout(parts[1], parts[2])
  end, { nargs = "?", desc = "sap-nvim: Checkout gCTS (cambia de rama)" })

  vim.api.nvim_create_user_command("SapGitClone", function()
    M.clone()
  end, { desc = "sap-nvim: Clonar repo gCTS en un paquete" })
end

return M
