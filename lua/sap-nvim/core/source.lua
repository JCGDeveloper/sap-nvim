-- sap-nvim.core.source
-- Edición de objetos ABAP remotos al estilo de la extensión `abap-remote-fs` de
-- VSCode, pero sobre la CLI de sapcli (que envuelve la misma API REST de ADT):
--
--   abrir   -> sapcli <group> read NAME            (fuente completa por stdout)
--   push    -> sapcli <group> write NAME - [--corrnr T]   (lock/unlock interno)
--   activar -> sapcli <group> activate NAME        (ver adt.activate_current)
--
-- El objeto se respalda en un archivo de caché real (~/.cache/sap-nvim/<contexto>/)
-- con nombre abapGit, para que treesitter/abaplint/LSP funcionen. `:w` solo guarda
-- en la caché; subir a SAP es la acción explícita `:SapPush`.

local M = {}
local adt = require("sap-nvim.core.adt")
local objtype = require("sap-nvim.core.objtype")

-- Transporte recordado por sesión (CORRNR o el sentinel LOCAL).
local LOCAL = "__LOCAL__"
local session_transport = nil

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- abaplint.json RELAJADO para la caché. Los objetos remotos se editan EN AISLADO (sin las
-- clases estándar de SAP ni el resto del proyecto), así que la regla `check_syntax` de
-- abaplint da FALSOS POSITIVOS ("Super class X not found", "redefinition", tipos
-- desconocidos). SAP ya hace el check real al activar; aquí solo queremos estilo. Por eso
-- desactivamos check_syntax y dejamos reglas que funcionan en aislado.
local CACHE_ABAPLINT = [[{
  "global": { "files": "/**/*.*" },
  "syntax": { "version": "v750", "errorNamespace": "." },
  "rules": {
    "check_syntax": false,
    "parser_error": true,
    "sequential_blank": { "lines": 4 },
    "contains_tab": true,
    "whitespace_end": true,
    "line_length": { "length": 255 }
  }
}
]]

-- ~/.cache/nvim/sap-nvim/<current-context>/ — se crea si no existe, con un abaplint.json
-- relajado (ver arriba) para que el linter (sap-nvim o el LSP del usuario, si respeta el
-- abaplint.json más cercano) no marque falsos "redefinition"/"class not found".
function M.cache_dir()
  local ctx = adt.get_current_context()
  local name = (ctx and ctx.name) or "default"
  local dir = vim.fn.stdpath("cache") .. "/sap-nvim/" .. name
  vim.fn.mkdir(dir, "p")
  local cfg = dir .. "/abaplint.json"
  if vim.fn.filereadable(cfg) == 0 then  -- no sobreescribir si el usuario lo personaliza
    pcall(vim.fn.writefile, vim.split(CACHE_ABAPLINT, "\n"), cfg)
  end
  return dir
end

-- Abre un objeto remoto: lo lee de SAP, lo cachea y lo muestra en un buffer.
-- opts.line / opts.col (opcional): salta a esa posición tras abrir (para go-to-definition).
function M.open(name, group, opts)
  opts = opts or {}
  if not group then
    notify("Tipo de objeto desconocido para '" .. name .. "'", vim.log.levels.WARN)
    return
  end
  if not adt.is_configured() then
    notify("No hay conexion SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  -- Los módulos de función necesitan su GRUPO de funciones: `functionmodule read GROUP NAME`.
  -- Si no nos lo pasaron, lo pedimos y reintentamos open con opts.fgroup puesto.
  local fgroup = opts.fgroup
  if group == "functionmodule" and (not fgroup or fgroup == "") then
    vim.ui.input({ prompt = "Grupo de funciones: " }, function(input)
      if not input or input == "" then return end
      opts.fgroup = vim.trim(input)
      M.open(name, group, opts)
    end)
    return
  end

  local path = M.cache_dir() .. "/" .. objtype.gitfile(group, name)
  notify("Leyendo " .. name .. " (" .. group .. ") desde SAP...")

  -- Comando de lectura: el FM lleva GRUPO antes del nombre; el resto, el nombre a secas.
  local read_args = (group == "functionmodule")
    and { "sapcli", "functionmodule", "read", fgroup, name }
    or { "sapcli", group, "read", name }

  local out, err = {}, {}
  vim.fn.jobstart(read_args, {
    on_stdout = function(_, data)
      for _, l in ipairs(data) do table.insert(out, l) end
    end,
    on_stderr = function(_, data)
      for _, l in ipairs(data) do
        if vim.trim(l) ~= "" then table.insert(err, vim.trim(l)) end
      end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          local msg = #err > 0 and err[1] or ("read fallido (code " .. code .. ")")
          notify("No se pudo leer " .. name .. ": " .. msg, vim.log.levels.ERROR)
          return
        end
        -- jobstart entrega un último elemento "" por el EOF: lo descartamos.
        if out[#out] == "" then table.remove(out) end
        vim.fn.writefile(out, path)
        vim.cmd("edit! " .. vim.fn.fnameescape(path))
        local bufnr = vim.api.nvim_get_current_buf()
        vim.b[bufnr].sap_obj = { name = name, group = group, fgroup = fgroup }
        vim.bo[bufnr].filetype = "abap"
        if opts.line then
          pcall(vim.api.nvim_win_set_cursor, 0, { opts.line, opts.col or 0 })
          vim.cmd("normal! zz")
        end
        notify(name .. " abierto (" .. group .. "). :SapPush para subir, :SapActivate para activar.")
        -- Programa: prefetch de sus includes a la caché (en segundo plano) para que
        -- `gd` navegue forms/variables entre includes sin abrirlos antes.
        if group == "program" then
          M.prefetch_includes(out)
        end
      end)
    end,
  })
end

-- Descarga a la caché (silenciosamente) los includes referenciados que aún no estén,
-- para alimentar el go-to-definition cross-include.
function M.prefetch_includes(lines)
  local dir = M.cache_dir()
  for _, raw in ipairs(lines) do
    local inc = raw:lower():match("^%s*include%s+([%w_/]+)")
    if inc then
      local p = dir .. "/" .. objtype.gitfile("include", inc)
      if vim.fn.filereadable(p) == 0 then
        local acc = {}
        vim.fn.jobstart({ "sapcli", "include", "read", inc }, {
          on_stdout = function(_, data)
            for _, l in ipairs(data) do acc[#acc + 1] = l end
          end,
          on_exit = function(_, code)
            if code == 0 then
              if acc[#acc] == "" then table.remove(acc) end
              if #acc > 0 then pcall(vim.fn.writefile, acc, p) end
            end
          end,
        })
      end
    end
  end
end

-- Resuelve el transporte a usar para el push y llama cb(corrnr_or_nil).
-- corrnr = nil  -> objeto local ($TMP), sin orden. Público para reusar (message.lua, etc.).
function M.resolve_transport(cb)
  if session_transport == LOCAL then return cb(nil) end
  if session_transport then return cb(session_transport) end

  adt.fetch_transport_orders(function(transports, _)
    vim.schedule(function()
      local items = { "(objeto local $TMP — sin orden)" }
      for _, t in ipairs(transports or {}) do table.insert(items, t) end

      vim.ui.select(items, { prompt = "Orden de transporte para el push:" }, function(choice)
        if not choice then return end -- cancelado
        if choice:match("^%(objeto local") then
          session_transport = LOCAL
          return cb(nil)
        end
        -- La primera palabra de la fila CTS es el ID de la orden (p.ej. SIDK900123).
        local corrnr = choice:match("^%s*(%S+)")
        session_transport = corrnr
        cb(corrnr)
      end)
    end)
  end)
end

-- Olvida el transporte recordado para que el próximo push vuelva a preguntar.
function M.reset_transport()
  session_transport = nil
  notify("Transporte de sesion reiniciado; el proximo push preguntara de nuevo.")
end

-- Sube el buffer actual a SAP. `activate` => añade -a (write + activate).
function M.push(bufnr, activate)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local obj = vim.b[bufnr].sap_obj
  if not obj then
    notify("Este buffer no es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN)
    return
  end

  pcall(vim.cmd, "write") -- vuelca la caché a disco
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)

  M.resolve_transport(function(corrnr)
    -- El FM mete su GRUPO de funciones antes del nombre: `functionmodule write GROUP NAME -`.
    local args = (obj.group == "functionmodule")
      and { "sapcli", "functionmodule", "write", obj.fgroup, obj.name, "-" }
      or { "sapcli", obj.group, "write", obj.name, "-" }
    if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end
    if activate then table.insert(args, "-a") end

    local verb = activate and "Subiendo+activando " or "Subiendo "
    notify(verb .. obj.name .. (corrnr and (" [" .. corrnr .. "]") or " [$TMP]") .. "...")

    -- sapcli imprime los hallazgos de activación por stdout y los errores de
    -- conexión por stderr: capturamos AMBOS y los parseamos juntos.
    local sink = {}
    local function collect(_, data)
      for _, l in ipairs(data) do
        if l ~= "" then table.insert(sink, l) end
      end
    end

    local job = vim.fn.jobstart(args, {
      on_stdout = collect,
      on_stderr = collect,
      on_exit = function(_, code)
        vim.schedule(function()
          local qf = adt._parse_activation_errors(sink, vim.api.nvim_buf_get_name(bufnr), bufnr)
          local errors, warnings = {}, {}
          for _, e in ipairs(qf) do
            table.insert(e.type == "E" and errors or warnings, e)
          end

          -- Fallo: exit != 0 o cualquier hallazgo de error.
          if code ~= 0 or #errors > 0 then
            local list = #qf > 0 and qf or { { text = (sink[1] or ("sapcli code " .. code)), type = "E" } }
            vim.fn.setqflist({}, "r", { items = list, title = "SAP " .. obj.name .. ": errores" })
            pcall(vim.cmd, "copen")
            pcall(vim.cmd, "cfirst")
            local n = #errors > 0 and #errors or #list
            notify(n .. " error(es) en " .. obj.name .. ". Revisa quickfix.", vim.log.levels.ERROR)
            return
          end

          -- Éxito: si hay warnings, los volcamos al quickfix pero sin abrirlo.
          if #warnings > 0 then
            vim.fn.setqflist({}, "r", { items = warnings, title = "SAP " .. obj.name .. ": " .. #warnings .. " warning(s)" })
            notify(obj.name .. (activate and " activado" or " subido") .. " con " .. #warnings
              .. " warning(s) (:copen para verlos).", vim.log.levels.WARN)
          else
            vim.fn.setqflist({}, "r", { title = "SAP " .. obj.name .. ": OK" })
            notify(obj.name .. (activate and " subido y activado correctamente." or " subido correctamente."))
          end
        end)
      end,
    })
    if job > 0 then
      vim.fn.chansend(job, table.concat(lines, "\n"))
      vim.fn.chanclose(job, "stdin")
    else
      notify("No se pudo lanzar sapcli write.", vim.log.levels.ERROR)
    end
  end)
end

-- Borra un objeto del sistema: `sapcli <group> delete NAME [--corrnr]`. Pide confirmación
-- y resuelve transporte (igual que el push). Tras borrar, limpia el buffer y la caché.
function M.delete(bufnr)
  bufnr = bufnr or vim.api.nvim_get_current_buf()
  local obj = vim.b[bufnr].sap_obj
  if not obj then
    notify("Este buffer no es un objeto SAP abierto con sap-nvim.", vim.log.levels.WARN)
    return
  end

  vim.ui.select({ "No", "Sí, BORRAR " .. obj.name .. " del sistema" },
    { prompt = "¿Borrar " .. obj.name .. " (" .. obj.group .. ") de SAP? Esto es irreversible." },
    function(choice)
      if not choice or not choice:match("^Sí") then return end

      M.resolve_transport(function(corrnr)
        local args = { "sapcli", obj.group, "delete", obj.name }
        if corrnr then vim.list_extend(args, { "--corrnr", corrnr }) end

        notify("Borrando " .. obj.name .. "...")
        local err = {}
        vim.fn.jobstart(args, {
          on_stderr = function(_, data)
            for _, l in ipairs(data) do if vim.trim(l) ~= "" then err[#err + 1] = l end end
          end,
          on_exit = function(_, code)
            vim.schedule(function()
              if code ~= 0 then
                notify("No se pudo borrar " .. obj.name .. ": " .. (err[1] or ("code " .. code)),
                  vim.log.levels.ERROR)
                return
              end
              local path = vim.api.nvim_buf_get_name(bufnr)
              pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
              if path ~= "" then pcall(os.remove, path) end
              notify(obj.name .. " borrado del sistema.")
            end)
          end,
        })
      end)
    end)
end

-- Activar. Para objetos remotos abiertos con sap-nvim, activar implica subir antes
-- (write + activate atómico, como hace la extensión de VSCode al guardar). Para
-- archivos sueltos en disco, cae al activate clásico que deduce group/name del nombre.
function M.activate()
  local bufnr = vim.api.nvim_get_current_buf()
  if vim.b[bufnr].sap_obj then
    M.push(bufnr, true)
  else
    adt.activate_current()
  end
end

function M.setup()
  vim.api.nvim_create_user_command("SapPush", function()
    M.push(nil, false)
  end, { desc = "sap-nvim: Subir el objeto actual a SAP (sapcli write)" })

  vim.api.nvim_create_user_command("SapPushActivate", function()
    M.push(nil, true)
  end, { desc = "sap-nvim: Subir y activar el objeto actual" })

  vim.api.nvim_create_user_command("SapActivate", function()
    M.activate()
  end, { desc = "sap-nvim: Activar el objeto actual (sube antes si es objeto remoto)" })

  vim.api.nvim_create_user_command("SapTransportReset", function()
    M.reset_transport()
  end, { desc = "sap-nvim: Olvidar la orden de transporte recordada" })

  vim.api.nvim_create_user_command("SapDelete", function()
    M.delete(nil)
  end, { desc = "sap-nvim: Borrar el objeto actual del sistema (con confirmación)" })

  vim.api.nvim_create_user_command("SapOpenFunction", function()
    -- Un módulo de función necesita GRUPO + NOMBRE: pedimos ambos y abrimos.
    vim.ui.input({ prompt = "Grupo de funciones: " }, function(grupo)
      if not grupo or grupo == "" then return end
      vim.ui.input({ prompt = "Módulo de función: " }, function(nombre)
        if not nombre or nombre == "" then return end
        M.open(vim.trim(nombre), "functionmodule", { fgroup = vim.trim(grupo) })
      end)
    end)
  end, { desc = "sap-nvim: Abrir un módulo de función (pide grupo y nombre)" })

  vim.keymap.set("n", "<leader>au", function() M.push(nil, false) end,
    { desc = "ABAP: Subir (push) objeto a SAP sin activar" })
  vim.keymap.set("n", "<leader>aX", function() M.delete(nil) end,
    { desc = "ABAP: Borrar objeto del sistema" })
end

return M
