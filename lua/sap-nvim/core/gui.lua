-- sap-nvim.core.gui
-- Ejecutar transaccion / abrir WebGUI (como el "Web Browser GUI" de VSCode)

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Abre una URL en el navegador del sistema (WSL/Linux/mac).
local function open_url(url)
  -- WSL: abrir en el navegador de Windows. OJO: `explorer.exe <url>` ROMPE la URL cuando
  -- lleva `&`/`~`/`;` (abre el explorador de archivos). powershell Start-Process con la URL
  -- entre comillas simples la trata como literal y abre el navegador por defecto.
  if vim.fn.executable("powershell.exe") == 1 then
    vim.fn.jobstart({ "powershell.exe", "-NoProfile", "-Command", "Start-Process '" .. url .. "'" }, { detach = true })
    return
  end
  if vim.fn.executable("wslview") == 1 then
    vim.fn.jobstart({ "wslview", url }, { detach = true }); return
  end
  for _, o in ipairs({ "xdg-open", "open", "sensible-browser" }) do
    if vim.fn.executable(o) == 1 then vim.fn.jobstart({ o, url }, { detach = true }); return end
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

-- Mapeo tipo de objeto -> transacción/campo/okcode para EJECUTAR en WebGUI. Idéntico a la
-- extensión de VSCode (SapGuiPanel.getTransactionInfo): PROG/P -> SE38, FUGR/FF -> SE37, etc.
local RUN_INFO = {
  program        = { tx = "SE38", field = "RS38M-PROGRAMM",  okcode = "STRT" },
  functiongroup  = { tx = "SE37", field = "RS38L-NAME",       okcode = "WB_EXEC" },
  functionmodule = { tx = "SE37", field = "RS38L-NAME",       okcode = "WB_EXEC" },
  class          = { tx = "SE24", field = "SEOCLASS-CLSNAME", okcode = "WB_EXEC" },
}

-- encodeURIComponent estricto: deja alfanuméricos y `- _ .`; codifica el resto. CLAVE: el
-- shortcut lleva `=` y `;` que, SIN codificar, rompen el parseo de la URL del ITS y el OKCODE
-- (ejecutar/F8) nunca se aplica — ese era el bug. VSCode los codifica (`%3d`, `%3b`, `%20`).
local function enc(s)
  return (s:gsub("[^%w%-_.]", function(c) return string.format("%%%02X", string.byte(c)) end))
end

-- Construye la URL WebGUI que EJECUTA el objeto (shortcut de transacción completo y codificado).
local function webgui_run_url(base, client, info, name)
  local shortcut = "*" .. info.tx .. " " .. info.field .. "=" .. name:upper() .. ";DYNP_OKCODE=" .. info.okcode
  return base
    .. "/sap/bc/gui/sap/its/webgui?~transaction=" .. enc(shortcut)
    .. "&sap-client=" .. client
    .. "&sap-language=EN&saml2=disabled"
end

-- Ejecuta el PROGRAMA/report del buffer actual (o el nombre dado) via SE38 en WebGUI.
-- Usa vim.b.sap_obj si es un program; si no, pide el nombre. Abre SE38 y lo EJECUTA (STRT).
function M.run_program(progname)
  local base, client = base_client()
  if not base then return end
  local meta = vim.b.sap_obj
  local name = progname or (meta and meta.group == "program" and meta.name) or nil
  local function go(p)
    p = (p or ""):upper()
    if p == "" then return end
    notify("Ejecutando programa " .. p .. " (SE38) en WebGUI...")
    open_url(webgui_run_url(base, client, RUN_INFO.program, p))
  end
  if name then
    go(name)
  else
    vim.ui.input({ prompt = "Programa a ejecutar: " }, function(v)
      if v then go(v) end
    end)
  end
end

-- Muestra texto en un split de solo lectura (q/- cierra).
local function show(bufname, lines)
  local b = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
  vim.bo[b].modifiable = false; vim.bo[b].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, b, bufname)
  vim.cmd("botright split"); vim.api.nvim_win_set_buf(0, b)
  pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
  vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
  vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- Ejecuta una CLASE (runClass / F9 de VSCode): corre if_oo_adt_classrun~main y muestra la
-- salida (out->write). `sapcli class execute NAME`. Usa la clase del buffer o pregunta.
function M.run_class(name)
  local meta = vim.b.sap_obj
  name = name or (meta and meta.group == "class" and meta.name) or nil
  local function go(c)
    c = (c or ""):upper(); if c == "" then return end
    notify("Ejecutando clase " .. c .. " (if_oo_adt_classrun~main)...")
    local out = {}
    vim.fn.jobstart({ "sapcli", "class", "execute", c }, {
      on_stdout = function(_, d) for _, l in ipairs(d) do out[#out + 1] = l end end,
      on_stderr = function(_, d) for _, l in ipairs(d) do if vim.trim(l) ~= "" then out[#out + 1] = l end end end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code ~= 0 and #out == 0 then notify("No se pudo ejecutar " .. c, vim.log.levels.ERROR); return end
          show("sap-runclass://" .. c, out)
        end)
      end,
    })
  end
  if name then go(name) else vim.ui.input({ prompt = "Clase a ejecutar: " }, function(v) if v then go(v) end end)
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

  vim.api.nvim_create_user_command("SapRunClass", function(a)
    M.run_class(a.args ~= "" and a.args or nil)
  end, { desc = "sap-nvim: Ejecutar clase (if_oo_adt_classrun~main)", nargs = "?" })

  -- Atajos: <leader>ax ejecutar transacción, <leader>aR ejecutar el programa del buffer.
  vim.keymap.set("n", "<leader>ax", function()
    local w = vim.fn.expand("<cword>")
    if w and w:match("^[%w_/]+$") and #w >= 3 and #w <= 20 then M.run_transaction(w)
    else vim.ui.input({ prompt = "Transacción: " }, function(v) if v and v ~= "" then M.run_transaction(v) end end) end
  end, { desc = "ABAP: Ejecutar transacción (WebGUI)" })
  vim.keymap.set("n", "<leader>aR", function() M.run_program() end,
    { desc = "ABAP: Ejecutar el programa/report (WebGUI)" })
  vim.keymap.set("n", "<leader>aE", function() M.run_class() end,
    { desc = "ABAP: Ejecutar clase (classrun)" })
end

return M
