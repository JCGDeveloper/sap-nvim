-- sap-nvim.core.type_resolver
-- Live ABAP naming convention validation.
--
-- Phase 1 (local, no SAP needed):
--   Validates TABLE OF, RANGE OF, and ABAP built-in types immediately.
-- Phase 2 (ADT, requires sapcli configured):
--   Calls sapcli abap search to resolve DDIC types (structures, transparent
--   tables, table types), then validates the variable prefix.
--   Results are cached per-session to avoid repeated network calls.
--
-- Results land in vim.diagnostic namespace "sap_nvim_naming" so they
-- appear alongside abaplint diagnostics without conflict.
--
-- !! parse_ddic_output() needs format verification on a live system !!
-- See the comment block above that function.

local M = {}
local adt = require("sap-nvim.core.adt")

local NS       = vim.api.nvim_create_namespace("sap_nvim_naming")
local cache    = {}   -- uppercase typename → category (persists across lints)
local inflight = {}   -- uppercase typename → true (dedup concurrent sapcli calls)
local timers   = {}   -- bufnr → uv timer

-- ─── Built-in ABAP scalar types ──────────────────────────────────────────────

local BUILTIN_SCALARS = {
  I=true, INT1=true, INT2=true, INT4=true, INT8=true,
  F=true, P=true, C=true, N=true, D=true, T=true,
  X=true, B=true, S=true,
  STRING=true, XSTRING=true, DECFLOAT16=true, DECFLOAT34=true,
}

-- Types to skip entirely (references, void, generic)
local SKIP_TYPES = { ANY=true, DATA=true, CLIKE=true, CSEQUENCE=true, NUMERIC=true }

-- ─── Naming convention ───────────────────────────────────────────────────────
-- Derived from company nomenclature table.

local VALID_PREFIXES = {
  scalar    = { "WG_", "WL_", "C_", "CL_", "P_", "PI_", "PO_", "PC_", "ST_", "STL_" },
  table     = { "T_", "TL_", "TT_", "TTL_", "PT_" },
  range     = { "R_", "RL_" },
  structure = { "WA_", "WAL_", "X_", "XL_" },
  ttype     = { "TT_", "TTL_", "TY_", "TYL_", "T_", "TL_" },
}

local CATEGORY_LABEL = {
  scalar    = "variable/escalar → WG_/WL_",
  table     = "tabla interna → T_/TL_",
  range     = "rango → R_/RL_",
  structure = "workarea/estructura → WA_/WAL_/X_/XL_",
  ttype     = "tipo tabla → TT_/TTL_/TY_/TYL_",
}

local function valid_prefix(varname, category)
  local prefixes = VALID_PREFIXES[category]
  if not prefixes then return true end
  local u = varname:upper()
  for _, p in ipairs(prefixes) do
    if u:sub(1, #p) == p then return true end
  end
  return false
end

local function make_diag(row, col, varname, category)
  return {
    lnum     = row,
    col      = col,
    end_lnum = row,
    end_col  = col + #varname,
    severity = vim.diagnostic.severity.WARN,
    message  = ("Nomenclatura: '%s' deberia usar prefijo de %s"):format(
      varname, CATEGORY_LABEL[category] or category
    ),
    source   = "sap-naming",
  }
end

-- ─── sapcli output parser ────────────────────────────────────────────────────
-- !! VERIFY THIS FORMAT ON A LIVE SYSTEM !!
--
-- Assumption: sapcli abap search returns lines like:
--   "VBAK        TABL   Sales Document: Header Data"
--   "ZMYSTRUC    STRU   My Z Structure"
--   "ZTTYP_ORD   TTYP   My Table Type"
--   "KUNNR       DTEL   Customer Number"
--
-- The function looks for the DDIC object type keyword (TABL, STRU, TTYP, DTEL,
-- DOMA) as a word in any line that also contains the typename.
--
-- If the format differs, update DDIC_MAP keys and/or the line matching below.

local DDIC_MAP = {
  TABL = "structure",  -- transparent table → use as workarea with WA_/X_
  STRU = "structure",
  TTYP = "ttype",      -- table type → internal table prefixes TT_/TY_
  DTEL = "scalar",
  DOMA = "scalar",
}

local function parse_ddic_output(typename_upper, lines)
  for _, line in ipairs(lines) do
    local u = line:upper()
    if u:find(typename_upper, 1, true) then
      for kind, cat in pairs(DDIC_MAP) do
        if u:find("%f[%w]" .. kind .. "%f[%W]") then
          return cat
        end
      end
    end
  end
  return nil
end

-- ─── Buffer declaration parser ───────────────────────────────────────────────
-- Handles single and chain-start DATA/CONSTANTS declarations.
-- Chain continuation lines (indented, no DATA keyword) are NOT handled in v1.

local TABLE_OF_PATS = {
  "STANDARD%s+TABLE%s+OF%s+",
  "SORTED%s+TABLE%s+OF%s+",
  "HASHED%s+TABLE%s+OF%s+",
  "ANY%s+TABLE%s+OF%s+",
  "INDEX%s+TABLE%s+OF%s+",
  "TABLE%s+OF%s+",
}

local function parse_declarations(lines)
  local decls = {}

  for lnum, line in ipairs(lines) do
    local u = line:upper()

    -- Skip comments and empty lines
    if u:match("^%s*[%*\"]") or u:match("^%s*$") then goto next end

    -- Require DATA or CONSTANTS keyword
    if not (u:find("^%s*DATA[%s:]") or u:find("^%s*CONSTANTS%s")) then
      goto next
    end

    -- Extract everything after the keyword (and optional chain colon)
    local after_kw = u:match("^%s*%w+[%s:]+(.+)$")
    if not after_kw then goto next end

    -- Variable name must be followed by TYPE
    local varname = after_kw:match("^([%w_]+)%s+TYPE%s+")
    if not varname or varname == "" then goto next end

    -- Find 0-based column of varname in original line
    local var_start = u:find(varname, 1, true) or 1
    local col = var_start - 1

    local after_type = after_kw:match("TYPE%s+(.+)$")
    if not after_type then goto next end

    -- RANGE OF
    if after_type:match("^RANGE%s+OF%s+") then
      table.insert(decls, { varname=varname, kind="range", row=lnum-1, col=col })
      goto next
    end

    -- TABLE OF variants
    for _, pat in ipairs(TABLE_OF_PATS) do
      if after_type:match("^" .. pat) then
        table.insert(decls, { varname=varname, kind="table", row=lnum-1, col=col })
        goto next
      end
    end

    -- REF TO → skip (reference type, own prefix rules)
    if after_type:match("^REF%s+TO%s+") then goto next end

    -- Plain TYPE: extract first token as typename
    local typename = after_type:match("^([%w_/]+)")
    if typename and typename ~= "" then
      table.insert(decls, {
        varname  = varname,
        kind     = "type",
        typename = typename,
        row      = lnum - 1,
        col      = col,
      })
    end

    ::next::
  end

  return decls
end

-- ─── Validation ──────────────────────────────────────────────────────────────

local function validate(bufnr, decls, on_done)
  local diags = {}
  local async_count = 0

  local function finish()
    if async_count == 0 then on_done(diags) end
  end

  for _, d in ipairs(decls) do
    local v = d.varname

    if d.kind == "table" then
      if not valid_prefix(v, "table") then
        table.insert(diags, make_diag(d.row, d.col, v, "table"))
      end

    elseif d.kind == "range" then
      if not valid_prefix(v, "range") then
        table.insert(diags, make_diag(d.row, d.col, v, "range"))
      end

    elseif d.kind == "type" then
      local u = d.typename:upper()

      if SKIP_TYPES[u] then
        -- generic type, skip

      elseif BUILTIN_SCALARS[u] then
        if not valid_prefix(v, "scalar") then
          table.insert(diags, make_diag(d.row, d.col, v, "scalar"))
        end

      elseif cache[u] then
        if not valid_prefix(v, cache[u]) then
          table.insert(diags, make_diag(d.row, d.col, v, cache[u]))
        end

      elseif adt.is_configured() and not inflight[u] then
        async_count = async_count + 1
        inflight[u] = true

        adt.fetch_objects(d.typename, function(results, err)
          inflight[u] = nil
          if not err and results then
            local cat = parse_ddic_output(u, results)
            if cat then
              cache[u] = cat
              -- Re-lint now that the cache has this type
              vim.schedule(function()
                if vim.api.nvim_buf_is_valid(bufnr) then M._run(bufnr) end
              end)
            end
          end
          async_count = async_count - 1
          finish()
        end)
      end
    end
  end

  finish()
end

-- ─── Public ──────────────────────────────────────────────────────────────────

function M._run(bufnr)
  if not vim.api.nvim_buf_is_valid(bufnr) then return end
  local lines = vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local decls = parse_declarations(lines)
  validate(bufnr, decls, function(diags)
    vim.schedule(function()
      if vim.api.nvim_buf_is_valid(bufnr) then
        vim.diagnostic.set(NS, bufnr, diags)
      end
    end)
  end)
end

local function debounce(bufnr)
  local t = timers[bufnr]
  if t then t:stop(); t:close(); timers[bufnr] = nil end
  local nt = vim.loop.new_timer()
  timers[bufnr] = nt
  nt:start(800, 0, vim.schedule_wrap(function()
    timers[bufnr] = nil
    M._run(bufnr)
  end))
end

function M.setup()
  local grp = vim.api.nvim_create_augroup("sap_nvim_naming", { clear = true })
  local pat  = { "*.abap", "*.cls", "*.intf", "*.prog" }

  vim.api.nvim_create_autocmd({ "BufEnter", "BufWritePost" }, {
    pattern = pat, group = grp,
    callback = function(ev) M._run(ev.buf) end,
  })

  vim.api.nvim_create_autocmd({ "TextChanged", "TextChangedI" }, {
    pattern = pat, group = grp,
    callback = function(ev) debounce(ev.buf) end,
  })

  vim.api.nvim_create_autocmd("BufDelete", {
    group = grp,
    callback = function(ev)
      local t = timers[ev.buf]
      if t then t:stop(); t:close(); timers[ev.buf] = nil end
      vim.diagnostic.reset(NS, ev.buf)
    end,
  })
end

return M
