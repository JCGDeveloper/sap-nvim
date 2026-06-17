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

function M.setup()
  vim.api.nvim_create_user_command("SapMessage", function() M.create_from_cursor() end,
    { desc = "sap-nvim: Crear el texto del mensaje (SE91/elemento de texto) y reescribir la línea" })
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_message", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>am", function() M.create_from_cursor() end,
        { buffer = ev.buf, desc = "ABAP: Crear mensaje/texto desde el MESSAGE" })
    end,
  })
end

return M
