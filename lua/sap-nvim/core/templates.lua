-- sap-nvim.core.templates  (R-D2)
-- Plantillas de código estilo Eclipse: store en disco editable, picker (Telescope con
-- preview; fallback vim.ui.select) y guardar plantillas nuevas desde la UI. Al insertar se
-- expanden las variables dinámicas ($DATE/$AUTHOR/$OBJECT/... via core/template_vars) y
-- los tabstops LSP `${1:...}` con el motor de snippets nativo (vim.snippet).
--
-- Store: $XDG_CONFIG_HOME/sap-nvim/templates/  (por defecto ~/.config/sap-nvim/templates/).
-- Cada archivo `*.abap` es una plantilla; su nombre = nombre de archivo sin extensión; su
-- cuerpo = contenido del archivo. Editable a mano por el usuario.

local M = {}

local function notify(msg, level)
  vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ─── Store en disco ───────────────────────────────────────────────────────────

function M.dir()
  local base = os.getenv("XDG_CONFIG_HOME")
  if not base or base == "" then base = vim.fn.expand("~/.config") end
  local dir = base .. "/sap-nvim/templates"
  vim.fn.mkdir(dir, "p")
  return dir
end

function M.list()
  local dir = M.dir()
  local out = {}
  for _, path in ipairs(vim.fn.glob(dir .. "/*", false, true)) do
    if vim.fn.isdirectory(path) == 0 then
      local body = table.concat(vim.fn.readfile(path), "\n")
      out[#out + 1] = { name = vim.fn.fnamemodify(path, ":t:r"), path = path, body = body }
    end
  end
  table.sort(out, function(a, b) return a.name < b.name end)
  return out
end

-- ─── Helpers puros (testeados offline) ────────────────────────────────────────

-- Quita los tabstops LSP de un cuerpo (fallback cuando no hay motor de snippets):
-- `${1:foo}` -> `foo`, `${0}`/`$1` -> "".
function M.strip_tabstops(body)
  body = body:gsub("%${%d+:([^}]*)}", "%1")
  body = body:gsub("%${%d+}", "")
  body = body:gsub("%$%d+", "")
  return body
end

-- Reemplaza TODAS las apariciones (token completo, case-insensitive) de `token` por
-- `first` en la 1ª y `rest` en las siguientes. Devuelve el texto y si hubo cambios.
local function replace_token(text, token, first, rest)
  if not token or token == "" then return text, false end
  local seen, changed = false, false
  local out = text:gsub("([%w_/~]+)", function(w)
    if w:upper() == token:upper() then
      changed = true
      if not seen then seen = true; return first end
      return rest
    end
    return w
  end)
  return out, changed
end

-- "Generaliza" un cuerpo para reutilizarlo, estilo Eclipse:
--  • el nombre del objeto (obj_name) → $OBJECT en TODAS partes (se rellena solo al insertar).
--  • cada identificador de `extras` → un tab-stop numerado y ESPEJADO `${i:nombre}` / `$i`
--    (escribes el nuevo valor una vez y cambia en todas sus apariciones).
function M.templatize(body, obj_name, extras)
  if obj_name and obj_name ~= "" then
    body = (replace_token(body, obj_name, "$OBJECT", "$OBJECT"))
  end
  for i, ex in ipairs(extras or {}) do
    if ex and ex ~= "" then
      body = (replace_token(body, ex, "${" .. i .. ":" .. ex .. "}", "$" .. i))
    end
  end
  return body
end

-- ─── Inserción ────────────────────────────────────────────────────────────────

local function insert_body(body)
  local tv = require("sap-nvim.core.template_vars")
  local expanded = tv.expand(body, tv.context(0))
  if vim.snippet and vim.snippet.expand then
    pcall(vim.snippet.expand, expanded)
  else
    local plain = M.strip_tabstops(expanded)
    vim.api.nvim_put(vim.split(plain, "\n"), "c", true, true)
  end
end

-- ─── Picker ───────────────────────────────────────────────────────────────────

local function pick_telescope(items)
  local pickers = require("telescope.pickers")
  local finders = require("telescope.finders")
  local conf = require("telescope.config").values
  local actions = require("telescope.actions")
  local action_state = require("telescope.actions.state")
  local previewers = require("telescope.previewers")

  pickers.new({}, {
    prompt_title = "Plantillas ABAP",
    finder = finders.new_table({
      results = items,
      entry_maker = function(it)
        return { value = it, display = it.name, ordinal = it.name }
      end,
    }),
    sorter = conf.generic_sorter({}),
    previewer = previewers.new_buffer_previewer({
      title = "Plantilla",
      define_preview = function(self, entry)
        vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(entry.value.body, "\n"))
        vim.bo[self.state.bufnr].filetype = "abap"
      end,
    }),
    attach_mappings = function(prompt_bufnr)
      actions.select_default:replace(function()
        local sel = action_state.get_selected_entry()
        actions.close(prompt_bufnr)
        if sel then insert_body(sel.value.body) end
      end)
      return true
    end,
  }):find()
end

function M.pick()
  local items = M.list()
  if #items == 0 then
    notify("No hay plantillas. Usa :SapTemplateSave (o :'<,'>SapTemplateSave) para crear una.", vim.log.levels.WARN)
    return
  end
  if pcall(require, "telescope.pickers") then
    pick_telescope(items)
  else
    vim.ui.select(items, {
      prompt = "Plantilla ABAP:",
      format_item = function(it) return it.name end,
    }, function(choice)
      if choice then insert_body(choice.body) end
    end)
  end
end

-- ─── Guardar ──────────────────────────────────────────────────────────────────

-- line1/line2: rango opcional (visual). Sin rango => buffer completo.
function M.save(line1, line2)
  local bufnr = vim.api.nvim_get_current_buf()
  local lines = (line1 and line2)
    and vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
    or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
  local body = table.concat(lines, "\n")
  if vim.trim(body) == "" then
    notify("Nada que guardar.", vim.log.levels.WARN)
    return
  end

  vim.ui.input({ prompt = "Nombre de la plantilla: " }, function(name)
    if not name or vim.trim(name) == "" then return end
    name = vim.trim(name):gsub("[^%w_%-]", "_")
    local path = M.dir() .. "/" .. name .. ".abap"
    local obj = vim.b[bufnr].sap_obj and vim.b[bufnr].sap_obj.name

    local function write(final_body)
      local function do_write()
        local ok = pcall(vim.fn.writefile, vim.split(final_body, "\n"), path)
        if ok then notify("Plantilla guardada: " .. name .. "  (:SapTemplate para usarla)")
        else notify("No se pudo escribir " .. path, vim.log.levels.ERROR) end
      end
      if vim.fn.filereadable(path) == 1 then
        vim.ui.select({ "No", "Sí, sobrescribir " .. name }, { prompt = "Ya existe. ¿Sobrescribir?" },
          function(ch) if ch and ch:match("^Sí") then do_write() end end)
      else
        do_write()
      end
    end

    -- Otros identificadores a parametrizar (grupo de funciones, tabla, prefijo...): cada uno
    -- se convierte en un hueco numerado y espejado, así al reusar lo escribes una vez.
    vim.ui.input({ prompt = "Otros nombres a parametrizar (coma, vacío = ninguno): " }, function(extra_str)
      local extras = {}
      for tok in (extra_str or ""):gmatch("[%w_/~]+") do extras[#extras + 1] = tok end

      local function finish(use_obj)
        write(M.templatize(body, use_obj and obj or nil, extras))
      end

      if obj and obj ~= "" and body:upper():find(obj:upper(), 1, true) then
        vim.ui.select({ "Sí, " .. obj .. " → $OBJECT (automático)", "No, dejar literal" },
          { prompt = "¿Generalizar el nombre del objeto?" }, function(ch)
            if not ch then return end
            finish(ch:match("^Sí") ~= nil)
          end)
      else
        finish(false)
      end
    end)
  end)
end

-- ─── Seed (un ejemplo en el primer arranque) ─────────────────────────────────

local SEED = {
  ["cabecera"] = table.concat({
    "*&---------------------------------------------------------------------*",
    "*& $OBJECT",
    "*&---------------------------------------------------------------------*",
    "*& Autor:   $AUTHOR",
    "*& Fecha:   $DATE",
    "*& Sistema: $SYSTEM",
    "*& ${1:Descripción}",
    "*&---------------------------------------------------------------------*",
    "${0}",
  }, "\n"),
}

function M.seed()
  local dir = M.dir()
  if #M.list() > 0 then return end
  for name, body in pairs(SEED) do
    pcall(vim.fn.writefile, vim.split(body, "\n"), dir .. "/" .. name .. ".abap")
  end
end

-- ─── Setup ────────────────────────────────────────────────────────────────────

function M.setup()
  vim.api.nvim_create_user_command("SapTemplate", function() M.pick() end,
    { desc = "sap-nvim: Insertar plantilla (picker)" })
  vim.api.nvim_create_user_command("SapTemplateSave", function(o)
    if o.range == 2 then M.save(o.line1, o.line2) else M.save() end
  end, { range = true, desc = "sap-nvim: Guardar buffer/selección como plantilla" })
  vim.api.nvim_create_user_command("SapTemplatesDir", function()
    notify("Plantillas en: " .. M.dir())
  end, { desc = "sap-nvim: Ruta del store de plantillas" })

  vim.keymap.set("n", "<leader>aP", function() M.pick() end, { desc = "ABAP: Plantillas (picker)" })
  vim.keymap.set("v", "<leader>aP", function()
    -- guarda la selección visual como plantilla
    local s = vim.fn.line("v")
    local e = vim.fn.line(".")
    if s > e then s, e = e, s end
    M.save(s, e)
  end, { desc = "ABAP: Guardar selección como plantilla" })

  pcall(M.seed)
end

return M
