-- sap-nvim.core.gui
-- Ejecutar transaccion / abrir WebGUI (como el "Web Browser GUI" de VSCode)

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Abre una URL en el navegador del sistema (WSL/Linux/mac).
local function open_url(url)
  if vim.ui and vim.ui.open then
    local ok = pcall(vim.ui.open, url)
    if ok then return end
  end
  local openers = { "wslview", "xdg-open", "open", "explorer.exe" }
  for _, o in ipairs(openers) do
    if vim.fn.executable(o) == 1 then
      vim.fn.jobstart({ o, url }, { detach = true })
      return
    end
  end
  notify("Abre manualmente: " .. url, vim.log.levels.WARN)
end

local function base_client()
  local c = require("sap-nvim.core.adt_http").creds()
  if not c then
    notify("Sin conexion SAP (config.yml).", vim.log.levels.WARN)
    return nil
  end
  return c.base, c.client
end

-- Ejecuta una transaccion en WebGUI.
function M.run_transaction(tcode)
  local base, client = base_client()
  if not base then return end
  tcode = (tcode or ""):upper()
  if tcode == "" then return end
  notify("Abriendo transaccion " .. tcode .. " en WebGUI...")
  open_url(base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. client .. "&~transaction=" .. tcode)
end

-- Abre el WebGUI (pantalla inicial).
function M.web_gui()
  local base, client = base_client()
  if not base then return end
  open_url(base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. client)
end

-- Ejecuta el PROGRAMA/report del buffer actual (o el nombre dado) via SE38 en WebGUI.
-- Usa vim.b.sap_obj si es un program; si no, pide el nombre. Abre SE38 con el programa.
function M.run_program(progname)
  local base, client = base_client()
  if not base then return end
  local meta = vim.b.sap_obj
  local name = progname or (meta and meta.group == "program" and meta.name) or nil
  local function go(p)
    p = (p or ""):upper()
    if p == "" then return end
    notify("Ejecutando programa " .. p .. " (SE38) en WebGUI...")
    -- SE38 con el programa precargado: ~transaction=*SE38 con parametro del programa.
    -- NOTA: la sintaxis exacta del shortcut (*SE38 RS38M-PROGRAMM=...;DYNP_OKCODE=STRT)
    -- la verificara el orquestador en vivo; el formato URL-encoded es el habitual de SAP ITS.
    open_url(base .. "/sap/bc/gui/sap/its/webgui?sap-client=" .. client .. "&~transaction=*SE38%20RS38M-PROGRAMM=" .. p .. ";DYNP_OKCODE=STRT")
  end
  if name then
    go(name)
  else
    vim.ui.input({ prompt = "Programa a ejecutar: " }, function(v)
      if v then go(v) end
    end)
  end
end

function M.setup()
  vim.api.nvim_create_user_command("SapRunTransaction", function(a)
    if a.args ~= "" then
      M.run_transaction(a.args)
    else
      vim.ui.input({ prompt = "Transaccion: " }, function(v)
        if v and v ~= "" then M.run_transaction(v) end
      end)
    end
  end, { desc = "sap-nvim: Ejecutar transaccion (WebGUI)", nargs = "?" })

  vim.api.nvim_create_user_command("SapRun", function(a)
    M.run_program(a.args ~= "" and a.args or nil)
  end, { desc = "sap-nvim: Ejecutar el programa/report (WebGUI SE38)", nargs = "?" })

  vim.api.nvim_create_user_command("SapWebGui", function()
    M.web_gui()
  end, { desc = "sap-nvim: Abrir WebGUI" })

  -- Atajos: <leader>ax ejecutar transacción, <leader>aR ejecutar el programa del buffer.
  vim.keymap.set("n", "<leader>ax", function()
    local w = vim.fn.expand("<cword>")
    if w and w:match("^[%w_/]+$") and #w >= 3 and #w <= 20 then M.run_transaction(w)
    else vim.ui.input({ prompt = "Transacción: " }, function(v) if v and v ~= "" then M.run_transaction(v) end end) end
  end, { desc = "ABAP: Ejecutar transacción (WebGUI)" })
  vim.keymap.set("n", "<leader>aR", function() M.run_program() end,
    { desc = "ABAP: Ejecutar el programa/report (WebGUI)" })
end

return M
