-- sap-nvim.core.include  (paridad Eclipse "Ctrl+1: create include")
-- Crea un INCLUDE en SAP por ADT directo (sapcli no expone includes) y lo abre.
-- Endpoint y payload tomados de abap-adt-api (objectcreator.ts, tipo PROG/I):
--   POST /sap/bc/adt/programs/includes   (Content-Type application/*; ?corrNr=<transporte>)
--   <include:abapInclude ... adtcore:name/description/type=PROG/I/language/responsible>
--     <adtcore:packageRef adtcore:name="<PAQUETE>"/></include:abapInclude>

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function xmlesc(s)
  return (s or ""):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

-- Nombre del include bajo el cursor: primero `INCLUDE <name>.` en la línea; si no, <cword>.
function M.name_under_cursor()
  local line = vim.api.nvim_get_current_line()
  local n = line:match("[Ii][Nn][Cc][Ll][Uu][Dd][Ee]%s+([%w_/]+)")
  if not n or n == "" then
    n = vim.fn.expand("<cword>")
  end
  if not n or n == "" then return nil end
  return n:upper()
end

-- Construye el payload XML de creación del include (PROG/I).
function M.build_payload(name, desc, package, responsible)
  return table.concat({
    '<?xml version="1.0" encoding="UTF-8"?>',
    '<include:abapInclude xmlns:include="http://www.sap.com/adt/programs/includes"',
    '  xmlns:adtcore="http://www.sap.com/adt/core"',
    '  adtcore:description="' .. xmlesc(desc) .. '"',
    '  adtcore:name="' .. xmlesc(name) .. '" adtcore:type="PROG/I"',
    '  adtcore:language="EN" adtcore:masterLanguage="EN"',
    '  adtcore:responsible="' .. xmlesc(responsible) .. '">',
    '  <adtcore:packageRef adtcore:name="' .. xmlesc(package) .. '"/>',
    '</include:abapInclude>',
  }, "\n")
end

-- Resuelve el paquete del buffer actual: sap_obj.package (lo rellena template_vars.prime al
-- abrir) -> si no, pregunta al usuario.
local function resolve_package(cb)
  local meta = vim.b.sap_obj
  if meta and meta.package and meta.package ~= "" then
    cb(meta.package:upper())
    return
  end
  vim.ui.input({ prompt = "Paquete del include: ", default = "$TMP" }, function(p)
    if p and p ~= "" then cb(p:upper()) else cb(nil) end
  end)
end

-- Crea el include en SAP y, si va bien, lo abre.
function M.create_under_cursor()
  if not adt_http.is_available() then
    notify("ADT no disponible (config.yml/curl).", vim.log.levels.WARN)
    return
  end
  local name = M.name_under_cursor()
  if not name then
    notify("No hay nombre de include bajo el cursor.", vim.log.levels.WARN)
    return
  end
  if not name:match("^[ZY]") and not name:match("^/") then
    notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
  end

  resolve_package(function(package)
    if not package then return end
    vim.ui.input({ prompt = "Descripción del include " .. name .. ": ", default = name }, function(desc)
      desc = (desc and desc ~= "") and desc or name
      local responsible = (adt_http.creds() and adt_http.creds().user or ""):upper()

      require("sap-nvim.core.source").resolve_transport(function(corrnr)
        local payload = M.build_payload(name, desc, package, responsible)
        notify("Creando include " .. name .. " en " .. package .. "...")

        local body, _, code = adt_http.raw({
          method = "POST",
          path = "/sap/bc/adt/programs/includes",
          query = corrnr and { corrNr = corrnr } or nil,
          content_type = "application/*",
          accept = "application/*",
          body = payload,
        })

        if code == 200 or code == 201 then
          notify(name .. " creado. Abriendo...")
          -- (source.open apila el programa actual en la pila de navegación, así que dentro
          --  del include recién abierto `-` vuelve a la línea donde se escribió INCLUDE ...)
          require("sap-nvim.core.source").open(name, "include")
        else
          local msg = (body or ""):match("<message[^>]->([^<]+)</") or (body or ""):match("adtcore:type=\"EXCEPTION\"[^>]->([^<]+)")
          notify("No se pudo crear " .. name .. " (HTTP " .. tostring(code) .. "): " .. (msg or "ver SAP"), vim.log.levels.ERROR)
        end
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapCreateInclude", function()
    M.create_under_cursor()
  end, { desc = "sap-nvim: Crear el include bajo el cursor (ADT) y abrirlo" })

  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    group = vim.api.nvim_create_augroup("sap_nvim_include", { clear = true }),
    callback = function(ev)
      vim.keymap.set("n", "<leader>aci", function() M.create_under_cursor() end,
        { buffer = ev.buf, desc = "ABAP: Crear include bajo el cursor (Ctrl+1)" })
    end,
  })
end

return M
