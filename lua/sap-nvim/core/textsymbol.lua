-- sap-nvim.core.textsymbol
-- Elementos de texto (text symbols / textos de selección / encabezados) editables, estilo
-- SE38/SE91, y lectura de clases de mensajes (SE91).
--
-- LEER: GET por ADT. EDITAR/CREAR/BORRAR: buffer editable; al guardar (:w) se hace
-- lock -> PUT -> unlock contra ADT en la MISMA sesión stateful, vía el DAEMON persistente
-- (curl-por-llamada perdía la sesión y daba 423/000). Formato y endpoint de abap-adt-api
-- (src/api/textelements.ts): texto plano con anotaciones @MaxLength: / @DDICReference:.

local M = {}
local sapcli = require("sap-nvim.core.sapcli")
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Las 3 categorías de ADT, con su media type. selections soporta @DDICReference (la
-- "referencia al Diccionario" de SE38); symbols soporta @MaxLength.
local CATS = {
  { cat = "selections", label = "Textos de selección (PARAMETERS / SELECT-OPTIONS)" },
  { cat = "symbols",    label = "Símbolos de texto (TEXT-xxx)" },
  { cat = "headings",   label = "Encabezados de lista" },
}
local function media(cat) return "application/vnd.sap.adt.textelements." .. cat .. ".v1" end

-- ── Parse / format (puros, probados offline) ─────────────────────────────────

-- Parsea el buffer editable -> lista de { id, text, ddicReference, maxLength }.
-- Acepta `CLAVE = texto` o `CLAVE=texto`. Anotaciones @DDICReference:X / @MaxLength:N
-- aplican al SIGUIENTE elemento. Ignora comentarios (" o * o --) y líneas en blanco.
function M.parse_buffer(lines)
  local out = {}
  local pending_ddic, pending_max
  for _, raw in ipairs(lines) do
    local line = vim.trim(raw)
    if line == "" or line:match("^[\"*]") or line:match("^%-%-") then
      -- comentario / blanco: ignorar (no rompe las anotaciones pendientes)
    elseif line:match("^@DDICReference:") then
      pending_ddic = vim.trim(line:sub(#"@DDICReference:" + 1))
    elseif line:match("^@MaxLength:") then
      pending_max = tonumber(vim.trim(line:sub(#"@MaxLength:" + 1)))
    else
      local eq = line:find("=", 1, true)
      if eq then
        local id = vim.trim(line:sub(1, eq - 1))
        local text = line:sub(eq + 1):gsub("^%s+", "")
        if id ~= "" then
          out[#out + 1] = { id = id:upper(), text = text, ddicReference = pending_ddic, maxLength = pending_max }
          pending_ddic, pending_max = nil, nil
        end
      end
    end
  end
  return out
end

-- Formatea elementos -> cuerpo @-anotado para el PUT (idéntico a abap-adt-api formatTextElements).
function M.format_elements(elements, category)
  local lines = {}
  for _, el in ipairs(elements) do
    if category == "symbols" and el.maxLength and el.maxLength > 0 then
      lines[#lines + 1] = "@MaxLength:" .. el.maxLength
    end
    if category == "selections" and el.ddicReference and el.ddicReference ~= "" then
      lines[#lines + 1] = "@DDICReference:" .. el.ddicReference
    end
    lines[#lines + 1] = el.id:upper() .. "=" .. (el.text or "")
    if category ~= "headings" then
      lines[#lines + 1] = ""
    end
  end
  return table.concat(lines, "\n")
end

-- ── Lectura ──────────────────────────────────────────────────────────────────

local function program_of_buffer()
  local meta = vim.b.sap_obj
  if meta and meta.group == "program" then return meta.name end
  return nil
end

-- GET del cuerpo de una categoría (texto @-anotado) o "" si vacío/404.
local function read_category(name, cat)
  local uri = "/sap/bc/adt/textelements/programs/" .. name:lower() .. "/source/" .. cat
  local body = adt_http.raw({ path = uri, accept = media(cat) })
  if not body or body == "" or body:match("Exception") or body:match("<html") then
    return ""
  end
  return (body:gsub("%s+$", ""))
end

-- ── Guardado (lock -> PUT -> unlock) vía DAEMON stateful ─────────────────────

function M.save(buf)
  local name = vim.b[buf].te_prog
  local cat = vim.b[buf].te_cat
  if not name or not cat then notify("Buffer de elementos de texto inválido.", vim.log.levels.ERROR); return end

  local d = require("sap-nvim.core.adt_daemon")
  if not d.available() or not d.ensure() then
    notify("La escritura de elementos de texto necesita el daemon ADT (sesión stateful). No disponible.", vim.log.levels.ERROR)
    return
  end

  local elements = M.parse_buffer(vim.api.nvim_buf_get_lines(buf, 0, -1, false))
  local body = M.format_elements(elements, cat)
  local obj_uri = "/sap/bc/adt/programs/programs/" .. name:lower()
  local text_uri = "/sap/bc/adt/textelements/programs/" .. name:lower() .. "/source/" .. cat

  require("sap-nvim.core.source").resolve_transport(function(corrnr)
    notify("Bloqueando " .. name:upper() .. "...")
    -- 1) LOCK (stateful)
    d.request_async({
      method = "POST",
      path = obj_uri,
      query = { _action = "LOCK", accessMode = "MODIFY" },
      accept = "application/*,application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result",
      stateful = true,
    }, function(lockbody)
      local handle = lockbody and (lockbody:match("<LOCK_HANDLE>([^<]*)</LOCK_HANDLE>") or lockbody:match("LOCK_HANDLE>([^<]+)<"))
      if not handle or handle == "" then
        vim.schedule(function() notify("No se pudo bloquear " .. name:upper() .. " (¿ya bloqueado / sin permiso?).", vim.log.levels.ERROR) end)
        return
      end
      -- 2) PUT del textpool (misma sesión)
      local put_q = { lockHandle = handle }
      if corrnr then put_q.corrNr = corrnr end
      d.request_async({
        method = "PUT",
        path = text_uri,
        query = put_q,
        content_type = media(cat) .. "; charset=UTF-8",
        accept = media(cat),
        body = body,
        stateful = true,
      }, function(putbody)
        local put_ok = putbody ~= nil
        -- 3) UNLOCK siempre (no dejar el objeto bloqueado)
        d.request_async({
          method = "POST",
          path = obj_uri,
          query = { _action = "UNLOCK", lockHandle = handle },
          stateful = true,
        }, function()
          vim.schedule(function()
            if put_ok then
              vim.bo[buf].modified = false
              notify(name:upper() .. ": elementos de texto guardados. Activa el programa (:SapActivate) para que surtan efecto.")
            else
              notify("El guardado falló (texto inválido, longitud >30 o transporte). Objeto desbloqueado.", vim.log.levels.ERROR)
            end
          end)
        end)
      end)
    end)
  end)
end

-- ── Editor editable ──────────────────────────────────────────────────────────

function M.edit(progname, cat)
  local name = progname or program_of_buffer()
  if not name then notify("Abre el programa o indica su nombre.", vim.log.levels.WARN); return end
  if not adt_http.is_available() then notify("ADT no disponible.", vim.log.levels.WARN); return end

  local raw = read_category(name, cat)
  local header = {
    '" Elementos de texto — ' .. name:upper() .. ' [' .. cat .. ']   (:w guarda en SAP)',
    '" Edita el texto tras "=", añade/quita líneas para crear/borrar.',
  }
  if cat == "selections" then
    header[#header + 1] = '" Referencia DDIC: pon  @DDICReference:CAMPO  en la línea de ENCIMA del parámetro.'
  end
  header[#header + 1] = ""

  local lines = vim.list_extend(header, vim.split(raw, "\n"))

  local buf = vim.api.nvim_create_buf(true, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  pcall(vim.api.nvim_buf_set_name, buf, "sap-textedit://" .. name:upper() .. "/" .. cat)
  vim.bo[buf].buftype = "acwrite"
  vim.bo[buf].filetype = "abap"
  vim.b[buf].te_prog = name
  vim.b[buf].te_cat = cat
  vim.bo[buf].modified = false

  vim.api.nvim_create_autocmd("BufWriteCmd", {
    buffer = buf,
    callback = function() M.save(buf) end,
  })

  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
end

-- Picker de categoría y abre el editor.
function M.open(progname)
  local name = progname or program_of_buffer()
  if not name then notify("Abre el programa o indica su nombre.", vim.log.levels.WARN); return end
  vim.ui.select(CATS, {
    prompt = "Elementos de texto de " .. name:upper() .. ":",
    format_item = function(c) return c.label end,
  }, function(c)
    if c then M.edit(name, c.cat) end
  end)
end

-- Compat: creación desde un MESSAGE (lo llama message.lua). Abre el editor de selecciones.
function M.create(_p)
  M.open()
end

-- ── Clase de mensajes (SE91) — solo lectura, vía sapcli ──────────────────────

local function show_ro(bufname, lines)
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

function M.message_class(name)
  if not name or name == "" then return end
  name = name:upper()
  notify("Leyendo clase de mensajes " .. name .. "...")
  local res = sapcli.system({ "sapcli", "messageclass", "read", name, "--output", "HUMAN" })
  if vim.v.shell_error ~= 0 or not res or res == "" or res:match("Exception") then
    notify("No se pudo leer la clase de mensajes " .. name, vim.log.levels.ERROR); return
  end
  show_ro("sap-se91://" .. name, vim.split(res:gsub("\n$", ""), "\n"))
end

function M.setup()
  vim.api.nvim_create_user_command("SapTextElements", function(a)
    M.open(a.args ~= "" and a.args or nil)
  end, { desc = "sap-nvim: Editar los elementos de texto del programa", nargs = "?" })

  vim.api.nvim_create_user_command("SapMessageClass", function(a)
    if a.args ~= "" then M.message_class(a.args)
    else vim.ui.input({ prompt = "Clase de mensajes (SE91): " }, function(v) if v then M.message_class(v) end end) end
  end, { desc = "sap-nvim: Ver una clase de mensajes (SE91)", nargs = "?" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_textsymbol", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>ave", function() M.open() end,
        { buffer = ev.buf, desc = "ABAP: Editar elementos de texto del programa" })
      vim.keymap.set("n", "<leader>av9", function()
        local w = vim.fn.expand("<cword>")
        if w and w ~= "" then M.message_class(w)
        else vim.ui.input({ prompt = "Clase de mensajes: " }, function(v) if v then M.message_class(v) end end) end
      end, { buffer = ev.buf, desc = "ABAP: Ver clase de mensajes (SE91)" })
    end,
  })
end

return M
