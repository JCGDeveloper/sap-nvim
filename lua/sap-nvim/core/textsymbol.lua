-- sap-nvim.core.textsymbol
-- Acceso a elementos de texto (text symbols) de un programa y a clases de mensajes (SE91).
--
-- VER funciona (GET por ADT / sapcli read). CREAR/EDITAR text symbols por ADT NO va de
-- forma fiable: requiere una sesión ADT stateful (lock+PUT en la misma sesión), que con
-- curl-por-llamada no se mantiene (HTTP 423/000), y sapcli no expone text symbols. Pendiente
-- (ver docs/KNOWN-ISSUES.md): necesita un helper con sesión persistente.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local SYM_CT = "application/vnd.sap.adt.textelements.symbols.v1"

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function program_of_buffer()
  local meta = vim.b.sap_obj
  if not meta or meta.group ~= "program" then return nil end
  return meta.name
end

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
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

-- Las 3 categorías de elementos de texto que expone ADT (igual que la extensión de VSCode
-- `getTextElements`): símbolos de texto (TEXT-xxx), textos de selección (PARAMETERS/
-- SELECT-OPTIONS) y encabezados de lista. Cada una con su Accept propio.
local CATEGORIES = {
  { cat = "symbols",    label = "Símbolos de texto (TEXT-xxx)" },
  { cat = "selections", label = "Textos de selección (PARAMETERS / SELECT-OPTIONS)" },
  { cat = "headings",   label = "Encabezados de lista" },
}

-- VER los elementos de texto del programa (cursor o nombre dado): las 3 categorías juntas.
function M.open(progname)
  local name = progname or program_of_buffer()
  if not name then notify("Abre el programa o indica su nombre.", vim.log.levels.WARN); return end
  name = name:lower()
  notify("Leyendo elementos de texto de " .. name:upper() .. "...")
  local lines = {}
  local any = false
  for _, c in ipairs(CATEGORIES) do
    local uri = "/sap/bc/adt/textelements/programs/" .. name .. "/source/" .. c.cat
    local body = adt_http.raw({ path = uri, accept = "application/vnd.sap.adt.textelements." .. c.cat .. ".v1" })
    lines[#lines + 1] = "── " .. c.label .. " ──"
    if body and body ~= "" and not body:match("Exception") and not body:match("<html") then
      any = true
      for _, l in ipairs(vim.split(body:gsub("%s+$", ""), "\n")) do lines[#lines + 1] = l end
    else
      lines[#lines + 1] = "(ninguno)"
    end
    lines[#lines + 1] = ""
  end
  if not any then
    notify("Sin elementos de texto o no accesibles para " .. name:upper(), vim.log.levels.WARN); return
  end
  show("sap-textelements://" .. name:upper(), lines)
end

-- Creación desde un MESSAGE — pendiente (ver cabecera). Avisa con claridad.
function M.create(_p)
  notify("Crear text symbols por ADT aún no está soportado (sesión stateful). "
    .. "Usa la clase de mensajes (SE91) por ahora. Ver docs/KNOWN-ISSUES.md.", vim.log.levels.WARN)
end

-- VER una clase de mensajes (SE91) con sapcli messageclass read.
-- Usa vim.fn.system() (síncrono): `messageclass read` SE CUELGA vía jobstart (deja el
-- proceso colgado para siempre), pero con system() responde al instante. On-demand, OK.
function M.message_class(name)
  if not name or name == "" then return end
  name = name:upper()
  notify("Leyendo clase de mensajes " .. name .. "...")
  local res = vim.fn.system({ "sapcli", "messageclass", "read", name, "--output", "HUMAN" })
  if vim.v.shell_error ~= 0 or not res or res == "" or res:match("Exception") then
    notify("No se pudo leer la clase de mensajes " .. name, vim.log.levels.ERROR); return
  end
  local lines = vim.split(res:gsub("\n$", ""), "\n")
  show("sap-se91://" .. name, lines)
end

function M.setup()
  vim.api.nvim_create_user_command("SapTextElements", function(a)
    M.open(a.args ~= "" and a.args or nil)
  end, { desc = "sap-nvim: Ver los elementos de texto del programa", nargs = "?" })

  vim.api.nvim_create_user_command("SapMessageClass", function(a)
    if a.args ~= "" then M.message_class(a.args)
    else vim.ui.input({ prompt = "Clase de mensajes (SE91): " }, function(v) if v then M.message_class(v) end end) end
  end, { desc = "sap-nvim: Ver una clase de mensajes (SE91)", nargs = "?" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_textsymbol", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>ave", function() M.open() end,
        { buffer = ev.buf, desc = "ABAP: Ver elementos de texto del programa" })
      -- Clase de mensajes bajo el cursor (cword) o pregunta.
      vim.keymap.set("n", "<leader>av9", function()
        local w = vim.fn.expand("<cword>")
        if w and w ~= "" then M.message_class(w)
        else vim.ui.input({ prompt = "Clase de mensajes: " }, function(v) if v then M.message_class(v) end end) end
      end, { buffer = ev.buf, desc = "ABAP: Ver clase de mensajes (SE91)" })
    end,
  })
end

return M
