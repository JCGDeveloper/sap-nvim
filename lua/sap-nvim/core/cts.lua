-- sap-nvim.core.cts
-- Gestión de órdenes de transporte (CTS) por ADT directo. Crear y listar. Endpoints y
-- payloads de abap-adt-api (transports.ts): crear = POST /sap/bc/adt/cts/transports (REF de
-- un objeto + paquete); listar = GET /sap/bc/adt/cts/transportrequests?user=&targets=true.
-- POST usa adt_http.raw (síncrono, gestiona CSRF de forma fiable); GET usa request_async.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function xmlesc(s)
  return (tostring(s or "")):gsub("&", "&amp;"):gsub("<", "&lt;"):gsub(">", "&gt;"):gsub('"', "&quot;")
end

-- Extrae y formatea un error ADT (HTTP 400/500) o nil. Robusto ante body vacío.
local function parse_exception(body)
  if not body or body == "" then return nil end
  if not body:find("exception", 1, true) and not body:find("<message", 1, true) then return nil end
  local msg = body:match("<message[^>]*>([^<]*)</message>")
    or body:match("<.->([^<]+)</.-exception>")
    or "error ADT"
  return (msg:gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&amp;", "&"))
end

-- URI + paquete del objeto del buffer actual (para REF/DEVCLASS al crear).
local function current_object()
  local bufnr = vim.api.nvim_get_current_buf()
  local meta = vim.b[bufnr].sap_obj
  local uri
  local ok, intel = pcall(require, "sap-nvim.core.intel")
  if ok and intel.object_uri then uri = intel.object_uri(bufnr) end
  local pkg = (meta and meta.package) or ""
  return uri and uri:gsub("%?.*$", ""), pkg
end

-- ── Feature 1: crear orden de transporte ─────────────────────────────────────

function M.create_transport()
  if not adt_http.is_available() then
    notify("ADT no disponible (config.yml/curl).", vim.log.levels.WARN)
    return
  end
  local ref, pkg = current_object()
  if not ref or ref == "" then
    notify("Abre un objeto ABAP (la orden se crea para su contexto/paquete).", vim.log.levels.WARN)
    return
  end

  local function ask_pkg(cb)
    if pkg and pkg ~= "" then cb(pkg) else
      vim.ui.input({ prompt = "Paquete (DEVCLASS): " }, function(p)
        if p and p ~= "" then cb(p:upper()) end
      end)
    end
  end

  ask_pkg(function(devclass)
    vim.ui.input({ prompt = "Descripción de la orden: " }, function(desc)
      if not desc or vim.trim(desc) == "" then return end
      local body = '<?xml version="1.0" encoding="UTF-8"?><asx:abap xmlns:asx="http://www.sap.com/abapxml" version="1.0"><asx:values><DATA>'
        .. "<DEVCLASS>" .. xmlesc(devclass) .. "</DEVCLASS>"
        .. "<REQUEST_TEXT>" .. xmlesc(desc) .. "</REQUEST_TEXT>"
        .. "<REF>" .. xmlesc(ref) .. "</REF>"
        .. "<OPERATION>I</OPERATION>"
        .. "</DATA></asx:values></asx:abap>"
      notify("Creando orden de transporte…")
      local resp, _, code = adt_http.raw({
        method = "POST",
        path = "/sap/bc/adt/cts/transports",
        accept = "text/plain",
        content_type = "application/vnd.sap.as+xml; charset=UTF-8; dataname=com.sap.adt.CreateCorrectionRequest",
        body = body,
      })
      local err = parse_exception(resp)
      if err or not (tostring(code):match("^2")) then
        notify("No se pudo crear la orden (HTTP " .. tostring(code) .. "): " .. (err or "ver SAP"), vim.log.levels.ERROR)
        return
      end
      -- Respuesta = texto plano con la URI; el número es el último segmento.
      local number = (resp or ""):gsub("%s+$", ""):match("([^/]+)$") or vim.trim(resp or "")
      notify("Orden creada: " .. number)
      pcall(vim.fn.setreg, "+", number) -- al portapapeles para pegarla en el push
    end)
  end)
end

-- ── Feature 2: listar mis órdenes modificables ───────────────────────────────

function M.list_transports()
  if not adt_http.is_available() then
    notify("ADT no disponible.", vim.log.levels.WARN)
    return
  end
  local c = adt_http.creds()
  local user = (c and c.user or ""):upper()
  notify("Leyendo mis órdenes de transporte…")
  adt_http.request_async({
    method = "GET",
    path = "/sap/bc/adt/cts/transportrequests",
    query = { user = user, targets = "true" },
    accept = "application/vnd.sap.adt.transportorganizertree.v1+xml",
  }, function(body)
    vim.schedule(function()
      local err = parse_exception(body)
      if err then
        notify("Error listando órdenes: " .. err, vim.log.levels.ERROR)
        return
      end
      local items, seen = {}, {}
      for req in (body or ""):gmatch("<tm:request%s(.-)>") do
        local number = req:match('tm:number="([^"]*)"')
        local desc = req:match('tm:desc="([^"]*)"')
        local status = req:match('tm:status="([^"]*)"')
        if number and number ~= "" and not seen[number] then
          seen[number] = true
          items[#items + 1] = string.format("%-12s [%s]  %s", number, status or "?",
            (desc or ""):gsub("&amp;", "&"))
        end
      end
      if #items == 0 then
        notify("No tienes órdenes de transporte modificables.", vim.log.levels.WARN)
        return
      end
      vim.ui.select(items, { prompt = "Mis órdenes de transporte:" }, function(choice)
        if not choice then return end
        local number = choice:match("^(%S+)")
        if number then
          pcall(vim.fn.setreg, "+", number)
          notify("Orden " .. number .. " copiada al portapapeles.")
        end
      end)
    end)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapCreateTransport", function() M.create_transport() end,
    { desc = "sap-nvim: Crear orden de transporte (ADT)" })
  vim.api.nvim_create_user_command("SapListTransports", function() M.list_transports() end,
    { desc = "sap-nvim: Listar mis órdenes de transporte (ADT)" })

  vim.keymap.set("n", "<leader>ct", function() M.create_transport() end,
    { desc = "CTS: Crear orden de transporte" })
  vim.keymap.set("n", "<leader>cl", function() M.list_transports() end,
    { desc = "CTS: Listar mis órdenes" })
end

return M
