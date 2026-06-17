-- sap-nvim.core.new  (F13)
-- Crea objetos ABAP EN EL SISTEMA con `sapcli <group> create NAME DESC PKG [--corrnr]`
-- y los abre para editar con source.open (SAP genera el esqueleto). Reemplaza el viejo
-- comportamiento de escribir una plantilla local que nunca llegaba a SAP.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Tipos creables. group = primer positional de sapcli. needs_group: el function module
-- vive dentro de un grupo de funciones (firma `create GROUP NAME DESC`, sin paquete).
local TYPES = {
  { key = "program",        label = "Programa (REPORT)",   group = "program" },
  { key = "class",          label = "Clase",               group = "class" },
  { key = "interface",      label = "Interface",           group = "interface" },
  { key = "function_group", label = "Function Group",      group = "functiongroup" },
  { key = "function_module",label = "Function Module",     group = "functionmodule", needs_group = true },
  { key = "table",          label = "Tabla (DDIC)",        group = "table" },
  { key = "structure",      label = "Estructura",          group = "structure" },
  { key = "data_element",   label = "Data Element",        group = "dataelement" },
  { key = "domain",         label = "Dominio",             group = "domain" },
  { key = "cds_view",       label = "CDS View (DDL)",       group = "ddl" },
  { key = "transaction",    label = "Transacción",         group = "transaction" },
  { key = "message_class",  label = "Message Class",        group = "messageclass" },
}

-- ─── Lanzar la creación en SAP y abrir ──────────────────────────────────────

local function do_create(spec, name, desc, pkg, corrnr, fgroup)
  local args = { "sapcli", spec.group, "create" }
  if spec.needs_group then
    vim.list_extend(args, { fgroup, name, desc })       -- functionmodule: GROUP NAME DESC
  else
    vim.list_extend(args, { name, desc, pkg })          -- resto: NAME DESC PACKAGE
  end
  if corrnr and corrnr ~= "" then vim.list_extend(args, { "--corrnr", corrnr }) end

  notify("Creando " .. spec.label .. " " .. name .. " en " .. (spec.needs_group and fgroup or pkg) .. "...")
  local err = {}
  vim.fn.jobstart(args, {
    on_stderr = function(_, data)
      for _, l in ipairs(data) do if vim.trim(l) ~= "" then err[#err + 1] = vim.trim(l) end end
    end,
    on_exit = function(_, code)
      vim.schedule(function()
        if code ~= 0 then
          notify("No se pudo crear " .. name .. ": " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR)
          return
        end
        notify(name .. " creado. Abriendo para editar...")
        require("sap-nvim.core.source").open(name, spec.group)
      end)
    end,
  })
end

-- ─── Pickers de paquete y transporte (desde el sistema) ─────────────────────

local function extract_transport_id(line)
  return line:match("%u%u%uK%d+") or line:match("%u%u%u%uK%d+") or line:match("^(%S+)")
end

-- callback(pkg)  — "$TMP" para local.
local function ask_package(callback)
  local adt = require("sap-nvim.core.adt")
  if not adt.is_configured() then
    vim.ui.input({ prompt = "Paquete ($TMP para local): ", default = "$TMP" }, function(pkg)
      callback(((pkg and pkg ~= "") and pkg or "$TMP"):upper())
    end)
    return
  end
  vim.ui.input({ prompt = "Prefijo de paquete ($TMP para local): ", default = "Z" }, function(prefix)
    if not prefix or prefix == "" or prefix:upper() == "$TMP" then callback("$TMP") return end
    notify("Buscando paquetes en el sistema...")
    adt.fetch_packages(prefix:upper() .. "*", function(packages, err)
      vim.schedule(function()
        if not packages or #packages == 0 then
          notify((err or "Sin resultados") .. " — usando '" .. prefix:upper() .. "'", vim.log.levels.WARN)
          callback(prefix:upper())
          return
        end
        local items = { "$TMP  (local, sin transporte)" }
        for _, p in ipairs(packages) do items[#items + 1] = p end
        vim.ui.select(items, { prompt = "Paquete:", format_item = function(i) return i end },
          function(choice)
            if not choice then callback("$TMP") return end
            if choice:match("^%$TMP") then callback("$TMP") return end
            callback(choice:match("^(%S+)"))
          end)
      end)
    end)
  end)
end

-- callback(transport_id)  — "" para ninguno. Solo se llama si pkg ~= "$TMP".
local function ask_transport(callback)
  local adt = require("sap-nvim.core.adt")
  if not adt.is_configured() then
    vim.ui.input({ prompt = "Orden de transporte (vacío = ninguna): " }, function(t)
      callback(t and t:upper() or "")
    end)
    return
  end
  notify("Obteniendo órdenes de transporte...")
  adt.fetch_transport_orders(function(transports, err)
    vim.schedule(function()
      local items = { "[ Sin transporte ]", "[ Ingresar manualmente ]" }
      for _, t in ipairs(transports or {}) do items[#items + 1] = t end
      vim.ui.select(items, { prompt = "Orden de transporte:", format_item = function(i) return i end },
        function(choice)
          if not choice or choice == "[ Sin transporte ]" then callback("") return end
          if choice == "[ Ingresar manualmente ]" then
            vim.ui.input({ prompt = "Orden: " }, function(t) callback(t and t:upper() or "") end)
            return
          end
          callback((extract_transport_id(choice) or ""):upper())
        end)
    end)
  end)
end

-- ─── Flujo principal ────────────────────────────────────────────────────────

function M.new_object()
  if not require("sap-nvim.core.adt").is_configured() then
    notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
    return
  end

  vim.ui.select(TYPES, {
    prompt = "Nuevo objeto ABAP en SAP:",
    format_item = function(it) return it.label end,
  }, function(spec)
    if not spec then return end

    vim.ui.input({ prompt = spec.label .. " — nombre: ", default = "Z" }, function(name)
      if not name or name == "" then return end
      name = name:upper()
      if not name:match("^[ZY]") and not name:match("^/") then
        notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
      end

      vim.ui.input({ prompt = "Descripción: ", default = name }, function(desc)
        desc = (desc and desc ~= "") and desc or name

        -- Function module: pide el grupo de funciones, sin paquete/transporte propio.
        if spec.needs_group then
          vim.ui.input({ prompt = "Function Group destino: ", default = "Z" }, function(fg)
            if not fg or fg == "" then return end
            do_create(spec, name, desc, nil, nil, fg:upper())
          end)
          return
        end

        ask_package(function(pkg)
          if pkg == "$TMP" then
            do_create(spec, name, desc, pkg, "")
          else
            ask_transport(function(corrnr) do_create(spec, name, desc, pkg, corrnr) end)
          end
        end)
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapNew", function() M.new_object() end,
    { desc = "sap-nvim: Crear objeto ABAP en el sistema y abrirlo" })
  vim.keymap.set("n", "<leader>an", function() M.new_object() end,
    { desc = "ABAP: Nuevo objeto (crear en SAP)" })
end

return M
