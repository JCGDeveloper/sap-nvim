-- sap-nvim.core.objtype
-- Maps a file (extension / abapGit double-extension) to the sapcli object
-- "group" — the first positional of `sapcli <group> <action> <name>`.
--
-- This is the single source of truth for ext → sapcli command group, used by
-- activation, ATC, where-used, read/diff and create flows. Verified against
-- the real sapcli 1.0.0 CLI surface.

local M = {}

-- abapGit double extensions take precedence (e.g. zcl_x.clas.abap → class).
local DOUBLE = {
  ["clas.abap"] = "class",
  ["intf.abap"] = "interface",
  ["prog.abap"] = "program",
  ["func.abap"] = "functionmodule",
  ["fugr.abap"] = "functiongroup",
}

-- Single extensions.
local SINGLE = {
  abap = "program",
  prog = "program",
  cls  = "class",
  clas = "class",
  intf = "interface",
  func = "functionmodule",
  fugr = "functiongroup",
  tabl = "table",
  stru = "structure",
  dtel = "dataelement",
  dome = "domain",
  ddls = "ddl",
  ddl  = "ddl",
  dcl  = "dcl",
  bdef = "bdef",
  inc  = "include",
}

-- sapcli object groups that expose an `activate` subcommand.
local ACTIVATABLE = {
  program = true, class = true, interface = true, table = true,
  structure = true, dataelement = true, domain = true, ddl = true,
  functiongroup = true, functionmodule = true, include = true,
}

-- atc run accepts only these positional types.
local ATC_TYPES = {
  program = "program", class = "class",
  functiongroup = "package", -- fall back to package for group-level
}

-- Return the sapcli object group for a filename, or nil if unknown.
-- Pass an absolute path or a bare filename.
function M.group(filename)
  filename = filename or vim.api.nvim_buf_get_name(0)
  local base = vim.fn.fnamemodify(filename, ":t"):lower()

  -- Try double extension first (last two dot-segments).
  local two = base:match("%.([%w]+%.[%w]+)$")
  if two and DOUBLE[two] then return DOUBLE[two] end

  local one = base:match("%.([%w]+)$")
  if one and SINGLE[one] then return SINGLE[one] end

  return nil
end

-- Object name without path or extension(s).
function M.name(filename)
  filename = filename or vim.api.nvim_buf_get_name(0)
  return vim.fn.fnamemodify(filename, ":t:r"):gsub("%.%w+$", "")
end

-- True if the object type can be activated via `sapcli <group> activate`.
function M.is_activatable(group)
  return group ~= nil and ACTIVATABLE[group] == true
end

-- Map a group to a valid `atc run` positional type (default: program).
function M.atc_type(group)
  return ATC_TYPES[group] or "program"
end

-- Inverse of DOUBLE/SINGLE: sapcli group -> abapGit-style extension.
-- Used to name the local cache file so filetype/treesitter/abaplint pick up.
local GROUP_TO_EXT = {
  class         = "clas.abap",
  interface     = "intf.abap",
  program       = "prog.abap",
  functionmodule = "func.abap",
  functiongroup = "fugr.abap",
  include       = "abap",
}

-- abapGit-style file name for an object, e.g. ("class","ZCL_X") -> "zcl_x.clas.abap".
function M.gitfile(group, name)
  local ext = GROUP_TO_EXT[group] or "abap"
  return name:lower() .. "." .. ext
end

return M
