-- sap-nvim.core.message  (R-D1, innovación — no está en VSCode)
-- Crea el texto de un mensaje a partir de un MESSAGE con literal+número bajo el cursor, y
-- REESCRIBE la línea a sintaxis válida (lo que quita los errores del linter):
--   * Clase de mensajes (SE91):   MESSAGE 'hola &1'(001) TYPE 'E' DISPLAY LIKE 'E'.
--                               -> MESSAGE e001(zclase) DISPLAY LIKE 'E'.
--   * Elemento de texto:          (idem) -> MESSAGE text-001 TYPE 'E' DISPLAY LIKE 'E'.
--                                 (la creación del text symbol vía ADT se añade aparte)

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- §7 S1: solo objetos propios (Z/Y o namespace /XXX/). Bloquea tocar estándar SAP.
local function is_own(name)
  local n = (name or ""):upper()
  return n:match("^[ZY]") ~= nil or n:match("^/%w+/") ~= nil
end

local function remote_delete_allowed()
  local ok, cfg = pcall(function()
    return require("sap-nvim.core.config").productive()
  end)
  return ok and cfg.allow_delete_objects == true
end

-- Parsea el MESSAGE con literal+número. Devuelve los trozos necesarios para reescribir.
-- { indent, literal, msgno, type, class?, rest } donde `rest` es lo que va tras el
-- '...'(nnn) (TYPE/DISPLAY/WITH... + punto).
local function parse(line)
  if not line:lower():find("message") then return nil end
  local indent = line:match("^(%s*)")
  -- MESSAGE 'literal'(nnn)<rest>
  local literal, msgno, rest =
    line:match("[Mm][Ee][Ss][Ss][Aa][Gg][Ee]%s+'(.-)'%s*%((%d+)%)(.*)$")
  if not msgno then return nil end
  local p = {
    indent = indent,
    literal = literal,
    msgno = string.format("%03d", tonumber(msgno)),
    rest = rest or "",
  }
  -- tipo: TYPE 'E' o TYPE e  -> letra minúscula
  p.type = (rest:match("[Tt][Yy][Pp][Ee]%s+'?([EeIiWwSsAaXx])'?") or "i"):lower()
  -- clase si ya estuviera (poco común en esta forma)
  p.class = rest:match("%(([%w_/]+)%)")
  return p
end

-- `rest` sin la cláusula TYPE '?' (para la forma de clase de mensajes, donde el tipo va
-- embebido en e001). Preserva DISPLAY/WITH y el punto.
local function strip_type(rest)
  return (rest:gsub("%s*[Tt][Yy][Pp][Ee]%s+'?[EeIiWwSsAaXx]'?", "", 1))
end

-- Reescribe la línea actual con la nueva sintaxis.
local function rewrite_line(new)
  vim.api.nvim_set_current_line(new)
end

-- Crea el mensaje en SE91 y, al terminar, reescribe la línea a MESSAGE e001(clase) ...
local function create_se91(p, class, text, corrnr, allow_create_class)
  if not is_own(class) then  -- §7 S1: defensa en profundidad
    notify("Solo se pueden crear/editar clases de mensajes propias (Z/Y). " .. class .. " es estándar SAP.", vim.log.levels.WARN)
    return
  end
  local args = { "sapcli", "messageclass", "message", "create", class, p.msgno, text }
  if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end
  notify("Creando mensaje " .. class .. "/" .. p.msgno .. "...")
  local err = {}
  vim.fn.jobstart(args, {
    on_stderr = function(_, d) for _, l in ipairs(d) do if vim.trim(l) ~= "" then err[#err + 1] = l end end end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code == 0 then
          local new = p.indent .. "MESSAGE " .. p.type .. p.msgno .. "(" .. class:lower() .. ")"
            .. strip_type(p.rest)
          rewrite_line(new)
          notify("Mensaje " .. class .. "/" .. p.msgno .. ' creado y línea reescrita.')
          return
        end
        local e = err[1] or ("code " .. code)
        if allow_create_class and e:lower():match("not") then
          vim.ui.select({ "Sí, crear la clase " .. class, "No" },
            { prompt = "La clase de mensajes " .. class .. " no existe. ¿Crearla?" },
            function(ch)
              if not ch or ch:match("^No") then return end
              vim.ui.input({ prompt = "Paquete ($TMP local): ", default = "$TMP" }, function(pkg)
                pkg = (pkg ~= "" and pkg or "$TMP"):upper()
                local cargs = { "sapcli", "messageclass", "create", class, "Mensajes " .. class, pkg }
                if corrnr and pkg ~= "$TMP" then vim.list_extend(cargs, { "--corrnr", corrnr }) end
                vim.fn.jobstart(cargs, { on_exit = function(_, c2)
                  vim.schedule(function()
                    if c2 ~= 0 then notify("No se pudo crear la clase " .. class, vim.log.levels.ERROR); return end
                    create_se91(p, class, text, corrnr, false)
                  end)
                end })
              end)
            end)
        else
          notify("No se pudo crear el mensaje: " .. e, vim.log.levels.ERROR)
        end
      end)
    end,
  })
end

-- Acción principal: a partir del MESSAGE bajo el cursor, elegir destino y crear + reescribir.
function M.create_from_cursor()
  if not require("sap-nvim.core.adt").is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN); return
  end
  local p = parse(vim.api.nvim_get_current_line())
  if not p then
    notify("No hay un MESSAGE 'texto'(nnn) bajo el cursor.", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "Clase de mensajes (SE91)", "Elemento de texto (text symbol)" },
    { prompt = "Crear el mensaje " .. p.msgno .. ' ("' .. (p.literal or "") .. '") como:' },
    function(choice)
      if not choice then return end
      if choice:match("^Clase") then
        vim.ui.input({ prompt = "Clase de mensajes (SE91): ", default = p.class or "Z" }, function(class)
          if not class or class == "" then return end
          class = class:upper()
          if not is_own(class) then  -- §7 S1
            notify("Solo se pueden crear mensajes en clases propias (Z/Y). " .. class .. " es estándar SAP.", vim.log.levels.WARN)
            return
          end
          vim.ui.input({ prompt = "Texto del mensaje: ", default = p.literal or "" }, function(text)
            if not text or text == "" then return end
            require("sap-nvim.core.source").resolve_transport(function(corrnr)
              create_se91(p, class, text, corrnr, true)
            end)
          end)
        end)
      else
        local ok, ts = pcall(require, "sap-nvim.core.textsymbol")
        if ok and ts and ts.create then
          ts.create(p)
        else
          notify("Elemento de texto: creación del text symbol en construcción (vía ADT). "
            .. "De momento usa la clase de mensajes (SE91).", vim.log.levels.WARN)
        end
      end
    end)
end

-- ── Gestión de una clase de mensajes (ver / editar / borrar / crear) ──────────────
-- Permite CORREGIR un mensaje creado por error: abre la clase, lista sus mensajes y deja
-- editar/borrar/crear sobre la línea. Lecturas vía sapcli; escrituras seguras (§7).

-- Lee la clase entera (JSON). Síncrono (`messageclass read` se cuelga vía jobstart), pero
-- CON timeout (§7 S9): si SAP no responde en 45s, mata el proceso y no congela el editor.
local READ_TIMEOUT_MS = 45000
local function read_class(name)
  local cmd = { "sapcli", "messageclass", "read", name, "--output", "JSON" }
  local res, code
  if vim.system then -- Neovim 0.10+: spawn con timeout real, mata el proceso si excede
    local ok, out = pcall(function() return vim.system(cmd, { text = true }):wait(READ_TIMEOUT_MS) end)
    if not ok then return nil, "timeout o error lanzando sapcli" end
    res, code = out.stdout, out.code
    if code == nil then return nil, "sapcli no respondió en " .. (READ_TIMEOUT_MS / 1000) .. "s (timeout)" end
  else -- fallback: sin timeout fiable, pero acotado por el shell
    res = vim.fn.system(cmd)
    code = vim.v.shell_error
  end
  if code ~= 0 or not res or res == "" then return nil, res end
  local ok, data = pcall(vim.json.decode, res)
  if not ok or type(data) ~= "table" then return nil, res end
  return data
end

-- Estado por buffer de gestión: { name, by_no = { ["001"] = {text, selfexplanatory} } }.
local manage_state = {}

local function render_manage(buf, name, data)
  local lines = { "Clase de mensajes " .. name
    .. "   —   e:editar  d:borrar  a:nuevo  r:refrescar  q:cerrar", "" }
  if data.header and data.header.description then
    lines[#lines + 1] = "  " .. data.header.description
    lines[#lines + 1] = ""
  end
  local by_no = {}
  for _, m in ipairs(data.messages or {}) do
    by_no[m.number] = { text = m.text, selfexplanatory = m.selfexplanatory }
    lines[#lines + 1] = string.format("  %s  %s", m.number, m.text or "")
  end
  if not next(by_no) then lines[#lines + 1] = "  (sin mensajes)" end
  manage_state[buf] = { name = name, by_no = by_no }
  vim.bo[buf].modifiable = true
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.bo[buf].modifiable = false
end

-- Relee la clase y repinta el buffer de gestión.
local function refresh_manage(buf)
  local st = manage_state[buf]; if not st then return end
  local data = read_class(st.name)
  if data then render_manage(buf, st.name, data) end
end

-- Nº de mensaje (3 dígitos) de la línea bajo el cursor, o nil.
local function msgno_under_cursor()
  return vim.api.nvim_get_current_line():match("^%s*(%d%d%d)%s")
end

-- Escribe/actualiza un mensaje (write = update; create para uno nuevo). cb() al terminar OK.
local function write_message(verb, name, msgno, text, selfexpl, cb)
  require("sap-nvim.core.source").resolve_transport(function(corrnr)
    local args = { "sapcli", "messageclass", "message", verb, name, msgno, text }
    if selfexpl ~= nil then vim.list_extend(args, { "--selfexplanatory", selfexpl and "true" or "false" }) end
    if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end
    notify((verb == "create" and "Creando" or "Actualizando") .. " mensaje " .. name .. "/" .. msgno .. "...")
    local err = {}
    vim.fn.jobstart(args, {
      on_stderr = function(_, d) for _, l in ipairs(d) do if vim.trim(l) ~= "" then err[#err + 1] = l end end end,
      on_exit = function(_, code)
        vim.schedule(function()
          if code == 0 then notify("Mensaje " .. name .. "/" .. msgno .. " guardado."); if cb then cb() end
          else notify("No se pudo guardar el mensaje: " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR) end
        end)
      end,
    })
  end)
end

-- Edita el texto del mensaje bajo el cursor.
local function manage_edit(buf)
  local st = manage_state[buf]; if not st then return end
  local no = msgno_under_cursor()
  if not no or not st.by_no[no] then notify("Pon el cursor en una línea de mensaje.", vim.log.levels.WARN); return end
  if not is_own(st.name) then notify("Solo se pueden editar clases propias (Z/Y). " .. st.name .. " es estándar SAP.", vim.log.levels.WARN); return end
  local cur = st.by_no[no]
  vim.ui.input({ prompt = "Texto del mensaje " .. no .. ": ", default = cur.text or "" }, function(text)
    if not text or text == "" or text == cur.text then return end
    write_message("write", st.name, no, text, cur.selfexplanatory, function() refresh_manage(buf) end)
  end)
end

-- Borra el mensaje bajo el cursor (con confirmación, §7 S2).
local function manage_delete(buf)
  if not remote_delete_allowed() then
    notify(
      "Borrado remoto desactivado por seguridad. Para habilitarlo: productive.allow_delete_objects = true.",
      vim.log.levels.WARN
    )
    return
  end
  local st = manage_state[buf]; if not st then return end
  local no = msgno_under_cursor()
  if not no or not st.by_no[no] then notify("Pon el cursor en una línea de mensaje.", vim.log.levels.WARN); return end
  if not is_own(st.name) then notify("Solo se pueden borrar clases propias (Z/Y). " .. st.name .. " es estándar SAP.", vim.log.levels.WARN); return end
  vim.ui.select({ "Sí, borrar " .. st.name .. "/" .. no, "No" },
    { prompt = 'Borrar el mensaje ' .. no .. ' ("' .. (st.by_no[no].text or "") .. '")?' },
    function(ch)
      if not ch or ch:match("^No") then return end
      require("sap-nvim.core.source").resolve_transport(function(corrnr)
        local args = { "sapcli", "messageclass", "message", "delete", st.name, no }
        if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end
        notify("Borrando mensaje " .. st.name .. "/" .. no .. "...")
        local err = {}
        vim.fn.jobstart(args, {
          on_stderr = function(_, d) for _, l in ipairs(d) do if vim.trim(l) ~= "" then err[#err + 1] = l end end end,
          on_exit = function(_, code)
            vim.schedule(function()
              if code == 0 then notify("Mensaje " .. no .. " borrado."); refresh_manage(buf)
              else notify("No se pudo borrar: " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR) end
            end)
          end,
        })
      end)
    end)
end

-- Crea un mensaje nuevo en la clase abierta.
local function manage_new(buf)
  local st = manage_state[buf]; if not st then return end
  if not is_own(st.name) then notify("Solo se pueden modificar clases propias (Z/Y).", vim.log.levels.WARN); return end
  vim.ui.input({ prompt = "Número del nuevo mensaje (3 dígitos): " }, function(no)
    if not no or not no:match("^%d+$") then return end
    no = string.format("%03d", tonumber(no))
    if st.by_no[no] then notify("El mensaje " .. no .. " ya existe (usa e para editarlo).", vim.log.levels.WARN); return end
    vim.ui.input({ prompt = "Texto del mensaje " .. no .. ": " }, function(text)
      if not text or text == "" then return end
      write_message("create", st.name, no, text, nil, function() refresh_manage(buf) end)
    end)
  end)
end

-- Abre el gestor de la clase de mensajes `name` (interactivo).
function M.manage(name)
  if not require("sap-nvim.core.adt").is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN); return
  end
  name = (name or ""):upper()
  if name == "" then return end
  notify("Leyendo clase de mensajes " .. name .. "...")
  local data, raw = read_class(name)
  if not data then
    notify("No se pudo leer la clase " .. name .. (raw and (": " .. vim.trim(raw)) or ""), vim.log.levels.ERROR); return
  end
  local buf = vim.api.nvim_create_buf(true, true)
  vim.bo[buf].buftype = "nofile"
  pcall(vim.api.nvim_buf_set_name, buf, "sap-se91://" .. name)
  render_manage(buf, name, data)
  vim.cmd("botright split")
  vim.api.nvim_win_set_buf(0, buf)
  pcall(vim.api.nvim_win_set_height, 0, 22)
  local opts = { buffer = buf, nowait = true }
  vim.keymap.set("n", "e", function() manage_edit(buf) end, opts)
  vim.keymap.set("n", "d", function() manage_delete(buf) end, opts)
  vim.keymap.set("n", "a", function() manage_new(buf) end, opts)
  vim.keymap.set("n", "r", function() refresh_manage(buf) end, opts)
  vim.keymap.set("n", "q", "<cmd>close<cr>", opts)
  vim.keymap.set("n", "-", "<cmd>close<cr>", opts)
  vim.api.nvim_create_autocmd("BufWipeout", { buffer = buf, once = true,
    callback = function() manage_state[buf] = nil end })
end

function M.setup()
  vim.api.nvim_create_user_command("SapMessage", function() M.create_from_cursor() end,
    { desc = "sap-nvim: Crear el texto del mensaje (SE91/elemento de texto) y reescribir la línea" })
  vim.api.nvim_create_user_command("SapMessageManage", function(a)
    if a.args ~= "" then M.manage(a.args)
    else vim.ui.input({ prompt = "Clase de mensajes (SE91): " }, function(v) if v and v ~= "" then M.manage(v) end end) end
  end, { desc = "sap-nvim: Gestionar una clase de mensajes (ver/editar/borrar/crear)", nargs = "?" })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_message", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>am", function() M.create_from_cursor() end,
        { buffer = ev.buf, desc = "ABAP: Crear mensaje/texto desde el MESSAGE" })
      -- Gestionar la clase de mensajes bajo el cursor (cword) o preguntar.
      vim.keymap.set("n", "<leader>aM", function()
        local w = vim.fn.expand("<cword>")
        if w and w ~= "" and (w:upper():match("^[ZY]") or w:upper():match("^/%w+/")) then M.manage(w)
        else vim.ui.input({ prompt = "Clase de mensajes (SE91): ", default = (w ~= "" and w or "") },
          function(v) if v and v ~= "" then M.manage(v) end end) end
      end, { buffer = ev.buf, desc = "ABAP: Gestionar clase de mensajes (editar/borrar/crear)" })
    end,
  })
end

return M
