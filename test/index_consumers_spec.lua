-- Offline regression tests for cache-first index consumers.

vim.env.XDG_STATE_HOME = "/tmp/sap-nvim-index-consumers-test-" .. tostring(vim.fn.getpid())
vim.opt.rtp:append(vim.fn.getcwd())
vim.notify = function(msg)
  print(msg)
end

local state_root = vim.fn.stdpath("state")
vim.fn.delete(state_root .. "/sap-nvim", "rf")

local index = require("sap-nvim.core.index")
index.setup({ index = { stale_after_seconds = 1 } })
index.clear()

index.add_entries({
  {
    name = "ZPKG_FLIGHT",
    type = "DEVC/K",
    uri = "/sap/bc/adt/packages/zpkg_flight",
    description = "Flight package",
  },
  {
    name = "ZCL_FLIGHT_SERVICE",
    type = "CLAS/OC",
    uri = "/sap/bc/adt/oo/classes/zcl_flight_service",
    description = "Flight booking service",
    package = "ZPKG_FLIGHT",
    parent = "ZPKG_FLIGHT",
  },
  {
    name = "GET_BOOKINGS",
    type = "CLAS/OM",
    description = "Read bookings",
    parent = "ZCL_FLIGHT_SERVICE",
    parent_type = "CLAS/OC",
  },
  {
    name = "CARRID",
    type = "FIELD",
    description = "Carrier",
    parent = "ZCL_FLIGHT_SERVICE",
    parent_type = "CLAS/OC",
  },
}, { source = "test", save = true })

local repo_rows = index.repository_rows("ZPKG_FLIGHT")
if #repo_rows ~= 1 or repo_rows[1].name ~= "ZCL_FLIGHT_SERVICE" or repo_rows[1].group ~= "class" then
  error("repository rows were not served from index")
end

local child_rows = index.repository_rows("ZCL_FLIGHT_SERVICE")
if #child_rows ~= 2 then
  error("object children were not served from index")
end

local docs = require("sap-nvim.core.docs")
local docs_rows, docs_status
docs.search_adt("ZCL_FLIGHT", { all_types = true }, function(rows, status)
  docs_rows, docs_status = rows, status
end)
if not docs_rows or #docs_rows == 0 or docs_rows[1].name ~= "ZCL_FLIGHT_SERVICE" then
  error("docs did not use cached index rows before ADT")
end
if not docs_status or not docs_status:find("indice local", 1, true) then
  error("docs status did not report local index source")
end

package.loaded["sap-nvim.core.intel"] = {
  proposals_async = function(_, _, _, cb)
    cb({})
  end,
}
package.loaded["blink.cmp.types"] = {
  CompletionItemKind = {
    Text = 1,
    Class = 2,
    Variable = 3,
    Field = 4,
    Method = 5,
    Function = 6,
    Keyword = 7,
  },
}

local blink_source = require("sap-nvim.core.blink_source").new()
local buf = vim.api.nvim_create_buf(false, true)
vim.bo[buf].filetype = "abap"
vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "DATA lo TYPE REF TO zcl_fl" })
local completion
blink_source:get_completions({ bufnr = buf, cursor = { 1, #"DATA lo TYPE REF TO zcl_fl" } }, function(result)
  completion = result
end)
if not completion or not completion.items or completion.items[1].label ~= "ZCL_FLIGHT_SERVICE" then
  error("blink source did not return cached object completion")
end

vim.api.nvim_buf_set_lines(buf, 0, -1, false, { "lo->get" })
blink_source:get_completions({ bufnr = buf, cursor = { 1, #"lo->get" } }, function(result)
  completion = result
end)
if not completion or not completion.items or completion.items[1].label ~= "GET_BOOKINGS" then
  error("blink source did not return cached method completion")
end

local cache = index.load()
cache.generated_at = os.time() - 5
index.save(cache)
local status = index.status()
if not status.stale then
  error("stale index status was not reported")
end

index.clear()

print("INDEX_CONSUMERS_SPEC_OK")
