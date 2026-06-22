-- sap-nvim.health
-- Diagnostics for `:checkhealth sap-nvim`.
--
-- Neovim auto-discovers this module: running :checkhealth sap-nvim calls M.check().
-- It reports the external tools the plugin shells out to, the tree-sitter
-- parsers, and whether a usable sapcli connection exists — with the exact
-- command to fix anything that is missing.

local M = {}

-- Support both the modern vim.health.* API and the legacy report_* names.
local h = vim.health or require("health")
local start = h.start or h.report_start
local ok = h.ok or h.report_ok
local warn = h.warn or h.report_warn
local err = h.error or h.report_error
local info = h.info or h.report_info

local function has(bin)
  return vim.fn.executable(bin) == 1
end

local function ts_parser_present(lang)
  local data = vim.fn.stdpath("data")
  local candidates = {
    data .. "/treesitter/" .. lang .. "/parser.so",
    data .. "/site/parser/" .. lang .. ".so",
    data .. "/lazy/nvim-treesitter/parser/" .. lang .. ".so",
  }
  for _, p in ipairs(candidates) do
    if vim.fn.filereadable(p) == 1 then
      return true
    end
  end
  -- Fall back to runtimepath lookup (covers custom install dirs).
  return #vim.api.nvim_get_runtime_file("parser/" .. lang .. ".so", false) > 0
end

function M.check()
  start("sap-nvim: required tools")

  -- sapcli es el ÚNICO imprescindible: el plugin lee/escribe objetos a través de él.
  if has("sapcli") then
    ok("sapcli: " .. vim.fn.exepath("sapcli"))
  else
    err("sapcli not found", {
      "Re-run the installer (instala sapcli con el Python correcto >=3.12 vía uv):",
      "  bash ~/sap-nvim/scripts/bootstrap.sh",
    })
  end

  start("sap-nvim: optional tools")

  -- abaplint = linting LOCAL opcional. El chequeo de sintaxis REAL lo hace SAP al activar,
  -- así que sin abaplint el plugin funciona igual. Necesita Node >= 18.
  if has("abaplint") then
    ok("abaplint: " .. vim.fn.exepath("abaplint"))
  else
    warn("abaplint not found (OPCIONAL: solo linting local; SAP valida al activar)", {
      "Necesita Node >= 18. Si lo quieres: npm install -g @abaplint/cli",
    })
  end

  if has("node") then
    ok("node: " .. vim.fn.exepath("node"))
  else
    info("node not found (solo lo necesita abaplint, que es opcional)")
  end

  if has("efm-langserver") then
    ok("efm-langserver found (enables vim.lsp.buf.format bridge)")
  else
    info("efm-langserver not found (optional; only needed for LSP-based formatting)")
  end

  start("sap-nvim: tree-sitter parsers (opcional)")

  -- Los parsers tree-sitter son OPCIONALES: el resaltado de ABAP/CDS usa la sintaxis
  -- nativa de Neovim (abap.vim), no tree-sitter. Sin parser todo funciona igual.
  for _, lang in ipairs({ "abap", "cds" }) do
    if ts_parser_present(lang) then
      ok("tree-sitter '" .. lang .. "' parser installed")
    else
      info("tree-sitter '" .. lang .. "' no instalado — OPCIONAL (resaltado nativo). Si lo quieres: :TSInstall " .. lang)
    end
  end

  start("sap-nvim: SAP connection")

  local cfg = vim.fn.expand("~/.sapcli/config.yml")
  if vim.fn.filereadable(cfg) == 1 then
    ok("sapcli config: " .. cfg)
    local f = io.open(cfg, "r")
    if f then
      local content = f:read("*a")
      f:close()
      local cur = content:match("current%-context:%s*([%w_%-]+)")
      if cur then
        ok("current-context: " .. cur)
      else
        warn("no current-context selected", { "Select one: sapcli config use-context <name>" })
      end
    end
  else
    warn("no sapcli config at ~/.sapcli/config.yml", {
      "Create a connection (single source of truth):",
      "  sapcli config set-connection dev --ashost HOST --port 44300 --client 100 --ssl",
      "  sapcli config set-user me --user SAPUSER --password ****",
      "  sapcli config set-context dev --connection dev --user me",
      "  sapcli config use-context dev",
      "Then verify with a read-only call: sapcli abap systeminfo",
    })
  end
end

return M
