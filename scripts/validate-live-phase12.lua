-- Live validation for phase 1/2.
-- Guarded by SAP_NVIM_LIVE_WRITE=1 because it creates, writes and activates
-- one temporary local Z report in the current SAP context.

local failed = false
local done = false

local function out(...)
  local parts = {}
  for i = 1, select("#", ...) do
    parts[#parts + 1] = tostring(select(i, ...))
  end
  print(table.concat(parts, " "))
end

local function fail(...)
  failed = true
  out("FAIL", ...)
end

local function xml_escape(s)
  return tostring(s or "")
    :gsub("&", "&amp;")
    :gsub("<", "&lt;")
    :gsub(">", "&gt;")
    :gsub('"', "&quot;")
    :gsub("'", "&apos;")
end

local function b64(s)
  if vim.base64 and vim.base64.encode then
    return vim.base64.encode(s or "")
  end
  return vim.fn.system({ "base64", "-w0" }, s or ""):gsub("%s+$", "")
end

local function short(body)
  body = tostring(body or ""):gsub("\r", ""):gsub("\n+", " ")
  return body:sub(1, 500)
end

local function lock_handle(body)
  return body and (
    body:match("<LOCK_HANDLE>([^<]*)</LOCK_HANDLE>")
    or body:match("<[^>]*LOCK_HANDLE[^>]*>([^<]*)</[^>]+>")
  ) or nil
end

local function active_errors(qf)
  local errors = 0
  for _, item in ipairs(qf or {}) do
    if item.type == "E" then
      errors = errors + 1
    end
  end
  return errors
end

vim.notify = function(msg)
  out(msg)
end

vim.opt.runtimepath:append(vim.fn.getcwd())
require("sap-nvim").setup({ new = { language = "ES" } })

if vim.env.SAP_NVIM_LIVE_WRITE ~= "1" and vim.g.sap_nvim_live_write ~= 1 then
  fail("SAP_NVIM_LIVE_WRITE no está activo; no se ejecuta validación viva.")
  done = true
else
  local config = require("sap-nvim.core.config")
  local profile = config.profile_name and config.profile_name() or "dev"
  out("profile", profile)
  if profile == "prod" then
    fail("perfil prod detectado; no se crea ni activa objeto temporal.")
    done = true
  end
end

if not done then
  local adt_http = require("sap-nvim.core.adt_http")
  local info = adt_http.context_info() or {}
  out("context", info.context or "?", info.sysid or "?", info.client or "?", info.user or "?", info.base or "?")

  adt_http.validate(function(ok, code)
    out("validate", ok, code)
    if not ok then
      fail("ADT no validó; no se toca SAP.")
      done = true
      return
    end
    adt_http.mark_validated()

    local c = adt_http.creds()
    if not c then
      fail("sin credenciales tras validate.")
      done = true
      return
    end

    local requested_name = vim.g.sap_nvim_live_name or vim.env.SAP_NVIM_LIVE_NAME
    local name = tostring(requested_name or ""):upper()
    local skip_create = name ~= ""
    if name == "" then
      name = ("ZNVIM_LIVE_%s"):format(os.date("%m%d%H%M%S")):upper()
    end
    local pkg = "$TMP"
    local desc = "sap-nvim live validation"
    local lang = "ES"
    local uri = "/sap/bc/adt/programs/programs/" .. name:lower()
    local source_uri = uri .. "/source/main"
    local source = table.concat({
      "REPORT " .. name .. ".",
      "",
      "START-OF-SELECTION.",
      "  WRITE: / 'sap-nvim live validation OK'.",
    }, "\n")

    local create_body = table.concat({
      '<?xml version="1.0" encoding="UTF-8"?>',
      '<program:abapProgram xmlns:program="http://www.sap.com/adt/programs/programs" xmlns:adtcore="http://www.sap.com/adt/core"',
      ' adtcore:type="PROG/P"',
      ' adtcore:description="' .. xml_escape(desc) .. '"',
      ' adtcore:language="' .. xml_escape(lang) .. '"',
      ' adtcore:name="' .. xml_escape(name) .. '"',
      ' adtcore:masterLanguage="' .. xml_escape(lang) .. '"',
      ' adtcore:responsible="' .. xml_escape(c.user:upper()) .. '"',
      ' adtcore:version="active">',
      '<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>',
      "<program:logicalDatabase><program:ref/></program:logicalDatabase>",
      "</program:abapProgram>",
    }, "\n")

    if skip_create then
      out("create", "skip-existing", name)
    else
      local body, _, create_code = adt_http.raw({
        method = "POST",
        path = "/sap/bc/adt/programs/programs",
        body = create_body,
        content_type = "application/vnd.sap.adt.programs.programs.v2+xml; charset=utf-8",
        accept = "application/vnd.sap.adt.programs.programs.v2+xml, application/xml, text/xml",
      })
      out("create", create_code, name)
      if create_code < 200 or create_code >= 300 then
        fail("create", short(body))
        done = true
        return
      end
    end

    local lock_body, _, lock_code = adt_http.raw({
      method = "POST",
      path = uri,
      query = { _action = "LOCK", accessMode = "MODIFY" },
      stateful = true,
      accept = table.concat({
        "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result;q=0.8",
        "application/vnd.sap.as+xml;charset=UTF-8;dataname=com.sap.adt.lock.result2;q=0.9",
      }, ", "),
    })
    local handle = lock_handle(lock_body)
    out("lock", lock_code, handle and "handle" or "no-handle")
    if lock_code < 200 or lock_code >= 300 or not handle or handle == "" then
      fail("lock", short(lock_body))
      done = true
      return
    end

    local put_body, _, put_code = adt_http.raw({
      method = "PUT",
      path = source_uri,
      query = { lockHandle = handle },
      body = source,
      content_type = "text/plain; charset=utf-8",
      accept = "text/plain, application/xml, application/*",
      stateful = true,
    })
    out("write", put_code)

    local _, _, unlock_code = adt_http.raw({
      method = "POST",
      path = uri,
      query = { _action = "UNLOCK", lockHandle = handle },
      stateful = true,
    })
    out("unlock", unlock_code)

    if put_code < 200 or put_code >= 300 then
      fail("write", short(put_body))
      done = true
      return
    end

    local check_body = '<?xml version="1.0" encoding="UTF-8"?><chkrun:checkObjectList xmlns:chkrun="http://www.sap.com/adt/checkrun" xmlns:adtcore="http://www.sap.com/adt/core"><chkrun:checkObject adtcore:uri="'
      .. uri
      .. '" chkrun:version="inactive"><chkrun:artifacts><chkrun:artifact chkrun:contentType="text/plain; charset=utf-8" chkrun:uri="'
      .. source_uri
      .. '"><chkrun:content>'
      .. b64(source)
      .. "</chkrun:content></chkrun:artifact></chkrun:artifacts></chkrun:checkObject></chkrun:checkObjectList>"

    local check_resp, _, check_code = adt_http.raw({
      method = "POST",
      path = "/sap/bc/adt/checkruns",
      query = { reporters = "abapCheckRun" },
      content_type = "application/vnd.sap.adt.checkobjects+xml",
      body = check_body,
      accept = "application/vnd.sap.adt.checkmessages+xml, application/xml",
    })
    local messages, errors = 0, 0
    for attrs in tostring(check_resp or ""):gmatch("<[%w_:]*checkMessage([^>]*)") do
      messages = messages + 1
      local typ = attrs:match('type="([^"]*)"') or attrs:match('severity="([^"]*)"') or "E"
      if typ:upper():sub(1, 1) == "E" then
        errors = errors + 1
      end
    end
    out("check", check_code, "messages", messages, "errors", errors)
    if check_code < 200 or check_code >= 300 or errors > 0 then
      fail("check", short(check_resp))
      done = true
      return
    end

    local adt = require("sap-nvim.core.adt")
    local obj = {
      name = name,
      group = "program",
      type = "PROG/P",
      uri = uri,
      package = pkg,
      source_lines = vim.split(source, "\n", { plain = true }),
    }
    adt.activate_bulk({ obj }, function(resp, qf)
      local qf_count = #(qf or {})
      local qf_errors = active_errors(qf)
      out("activate", resp and "response" or "no-response", "qf", qf_count, "errors", qf_errors)
      for i, item in ipairs(qf or {}) do
        out("activate_qf", i, item.type or "?", item.text or "")
      end
      if qf_errors > 0 then
        fail("activate", qf_errors .. " error(es)")
        done = true
        return
      end

      local dbg = require("sap-nvim.core.debugger")
      dbg.init_session(function(debug_ok)
        out("dbg_init", debug_ok)
        if not debug_ok then
          fail("debugger init")
          done = true
          return
        end
        dbg.set_breakpoint(source_uri, 4, function(bp_ok, bp_info)
          out("dbg_breakpoint", bp_ok, bp_info and (bp_info.id or bp_info.errorMessage or "info") or "")
          if not bp_ok then
            fail("debugger breakpoint")
          end
          dbg.clear_breakpoints_for_sources({ source_uri }, function(clear)
            out("dbg_clear", clear.deleted or 0, clear.failed or 0, clear.matched or 0, clear.reason or "")
            if (clear.failed or 0) > 0 then
              fail("debugger clear breakpoint")
            end
            dbg.stop(function()
              out("dbg_stop", "ok")
              done = true
            end)
          end)
        end, nil, { source_uri = source_uri })
      end)
    end, { scope = "single", confirmed = true, precheck = true })
  end)
end

local finished = vim.wait(90000, function()
  return done
end, 100)

if not finished then
  fail("timeout")
end

if failed then
  vim.cmd("cquit")
end
