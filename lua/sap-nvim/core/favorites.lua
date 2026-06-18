-- sap-nvim.core.favorites
-- Favoritos de objetos ABAP (replica abapfs.addfavourite / deletefavourite): acceso rápido a
-- los objetos que más usas. Store LOCAL en JSON (por sistema/contexto). Abrir = source.open.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function store_path()
  local dir = vim.fn.stdpath("data") .. "/sap-nvim"
  vim.fn.mkdir(dir, "p")
  return dir .. "/favorites.json"
end

local function load()
  local f = io.open(store_path(), "r")
  if not f then return {} end
  local txt = f:read("*a"); f:close()
  local ok, data = pcall(vim.json.decode, txt)
  return (ok and type(data) == "table") and data or {}
end

local function save(list)
  local f = io.open(store_path(), "w")
  if not f then return end
  f:write(vim.json.encode(list)); f:close()
end

-- Añade el objeto del buffer actual (o nombre+grupo dados) a favoritos.
function M.add(name, group)
  local meta = vim.b.sap_obj
  name = name or (meta and meta.name)
  group = group or (meta and meta.group)
  if not name or not group then
    notify("Abre un objeto SAP (o indica nombre y grupo) para añadirlo a favoritos.", vim.log.levels.WARN)
    return
  end
  local list = load()
  for _, it in ipairs(list) do
    if it.name == name and it.group == group then notify(name .. " ya está en favoritos."); return end
  end
  list[#list + 1] = { name = name, group = group }
  save(list)
  notify("★ " .. name .. " (" .. group .. ") añadido a favoritos.")
end

-- Picker de favoritos; Enter abre el objeto. `for_delete` => borra el elegido.
local function pick(prompt, on_choice)
  local list = load()
  if #list == 0 then notify("No tienes favoritos. Usa :SapFavoriteAdd."); return end
  vim.ui.select(list, {
    prompt = prompt,
    format_item = function(it) return string.format("★ %-14s %s", it.group, it.name) end,
  }, function(choice) if choice then on_choice(choice, list) end end)
end

-- Abrir un favorito.
function M.open()
  pick("Favoritos:", function(choice)
    require("sap-nvim.core.source").open(choice.name, choice.group)
  end)
end

-- Quitar un favorito.
function M.remove()
  pick("Quitar de favoritos:", function(choice, list)
    local out = {}
    for _, it in ipairs(list) do
      if not (it.name == choice.name and it.group == choice.group) then out[#out + 1] = it end
    end
    save(out)
    notify("Quitado de favoritos: " .. choice.name)
  end)
end

function M.setup()
  vim.api.nvim_create_user_command("SapFavoriteAdd", function() M.add() end,
    { desc = "sap-nvim: Añadir el objeto actual a favoritos" })
  vim.api.nvim_create_user_command("SapFavorites", function() M.open() end,
    { desc = "sap-nvim: Abrir un objeto favorito" })
  vim.api.nvim_create_user_command("SapFavoriteRemove", function() M.remove() end,
    { desc = "sap-nvim: Quitar un objeto de favoritos" })

  vim.keymap.set("n", "<leader>aff", function() M.open() end, { desc = "ABAP: Favoritos (abrir)" })
  vim.keymap.set("n", "<leader>afa", function() M.add() end, { desc = "ABAP: Añadir a favoritos" })
end

return M
