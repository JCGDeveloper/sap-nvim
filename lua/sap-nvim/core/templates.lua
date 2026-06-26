-- sap-nvim.core.templates
-- Plantillas de código estilo Eclipse con navegación por carpetas.

local M = {}

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- ─── Store en disco ───────────────────────────────────────────────────────────

function M.dir()
	local base = os.getenv("XDG_CONFIG_HOME")
	if not base or base == "" then
		base = vim.fn.expand("~/.config")
	end
	local dir = base .. "/sap-nvim/templates"
	vim.fn.mkdir(dir, "p")
	return dir
end

-- Lee un directorio concreto y devuelve carpetas y archivos ordenados
function M.list_dir(target_dir)
	local out = {}
	-- Buscamos solo en el primer nivel del directorio actual
	for _, path in ipairs(vim.fn.glob(target_dir .. "/*", false, true)) do
		local name = vim.fn.fnamemodify(path, ":t")
		if vim.fn.isdirectory(path) == 1 then
			out[#out + 1] = { is_dir = true, name = "📁 " .. name, path = path, raw_name = name }
		else
			if path:match("%.abap$") then
				local body = table.concat(vim.fn.readfile(path), "\n")
				out[#out + 1] = { is_dir = false, name = "📄 " .. name:gsub("%.abap$", ""), path = path, body = body }
			end
		end
	end

	-- Ordenamos: primero las carpetas, luego los archivos (alfabéticamente)
	table.sort(out, function(a, b)
		if a.is_dir ~= b.is_dir then
			return a.is_dir
		end
		return a.name:lower() < b.name:lower()
	end)
	return out
end

-- ─── Helpers puros ────────────────────────────────────────────────────────────

function M.strip_tabstops(body)
	body = body:gsub("%${%d+:([^}]*)}", "%1")
	body = body:gsub("%${%d+}", "")
	body = body:gsub("%$%d+", "")
	return body
end

local function replace_token(text, token, first, rest)
	if not token or token == "" then
		return text, false
	end
	local seen, changed = false, false
	local out = text:gsub("([%w_/~]+)", function(w)
		if w:upper() == token:upper() then
			changed = true
			if not seen then
				seen = true
				return first
			end
			return rest
		end
		return w
	end)
	return out, changed
end

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

-- ─── Picker Jerárquico ────────────────────────────────────────────────────────

local function pick_telescope(items, current_path)
	local pickers = require("telescope.pickers")
	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")
	local previewers = require("telescope.previewers")

	local title = "Plantillas ABAP"
	local rel_path = current_path:sub(#M.dir() + 2)
	if rel_path ~= "" then
		title = title .. " (" .. rel_path .. ")"
	end

	pickers
		.new({}, {
			prompt_title = title,
			finder = finders.new_table({
				results = items,
				entry_maker = function(it)
					return { value = it, display = it.name, ordinal = it.name }
				end,
			}),
			sorter = conf.generic_sorter({}),
			previewer = previewers.new_buffer_previewer({
				title = "Vista previa",
				define_preview = function(self, entry)
					if entry.value.is_dir then
						vim.api.nvim_buf_set_lines(
							self.state.bufnr,
							0,
							-1,
							false,
							{ "📁 Directorio:", "", entry.value.path }
						)
					elseif entry.value.is_back then
						vim.api.nvim_buf_set_lines(
							self.state.bufnr,
							0,
							-1,
							false,
							{ "🔙 Volver al directorio anterior" }
						)
					else
						vim.api.nvim_buf_set_lines(self.state.bufnr, 0, -1, false, vim.split(entry.value.body, "\n"))
						vim.bo[self.state.bufnr].filetype = "abap"
					end
				end,
			}),
			attach_mappings = function(prompt_bufnr)
				actions.select_default:replace(function()
					local sel = action_state.get_selected_entry()
					actions.close(prompt_bufnr)
					if sel then
						if sel.value.is_back then
							-- Navegar a la carpeta padre
							M.pick(vim.fn.fnamemodify(current_path, ":h"))
						elseif sel.value.is_dir then
							-- Entrar en la subcarpeta
							M.pick(sel.value.path)
						else
							-- Insertar el archivo
							insert_body(sel.value.body)
						end
					end
				end)
				return true
			end,
		})
		:find()
end

function M.pick(current_path)
	current_path = current_path or M.dir()
	local items = M.list_dir(current_path)

	-- Si no estamos en la raíz, añadimos el botón de volver
	if current_path ~= M.dir() then
		table.insert(items, 1, { is_back = true, name = "🔙 [Volver atrás]" })
	end

	if #items == 0 and current_path == M.dir() then
		notify("No hay plantillas. Usa :SapTemplateSave (o :'<,'>SapTemplateSave) para crear una.", vim.log.levels.WARN)
		return
	end

	if pcall(require, "telescope.pickers") then
		pick_telescope(items, current_path)
	else
		vim.ui.select(items, {
			prompt = "Plantillas ABAP:",
			format_item = function(it)
				return it.name
			end,
		}, function(choice)
			if choice then
				if choice.is_back then
					M.pick(vim.fn.fnamemodify(current_path, ":h"))
				elseif choice.is_dir then
					M.pick(choice.path)
				else
					insert_body(choice.body)
				end
			end
		end)
	end
end

-- ─── Guardar ──────────────────────────────────────────────────────────────────

function M.save(line1, line2)
	local bufnr = vim.api.nvim_get_current_buf()
	local lines = (line1 and line2) and vim.api.nvim_buf_get_lines(bufnr, line1 - 1, line2, false)
		or vim.api.nvim_buf_get_lines(bufnr, 0, -1, false)
	local body = table.concat(lines, "\n")
	if vim.trim(body) == "" then
		notify("Nada que guardar.", vim.log.levels.WARN)
		return
	end

	vim.ui.input({ prompt = "Nombre de la plantilla: " }, function(name)
		if not name or vim.trim(name) == "" then
			return
		end
		name = vim.trim(name):gsub("[^%w_%-]", "_")
		local path = M.dir() .. "/" .. name .. ".abap"
		local obj = vim.b[bufnr].sap_obj and vim.b[bufnr].sap_obj.name

		local function write(final_body)
			local function do_write()
				local ok = pcall(vim.fn.writefile, vim.split(final_body, "\n"), path)
				if ok then
					notify("Plantilla guardada: " .. name .. "  (:SapTemplate para usarla)")
				else
					notify("No se pudo escribir " .. path, vim.log.levels.ERROR)
				end
			end
			if vim.fn.filereadable(path) == 1 then
				vim.ui.select(
					{ "No", "Sí, sobrescribir " .. name },
					{ prompt = "Ya existe. ¿Sobrescribir?" },
					function(ch)
						if ch and ch:match("^Sí") then
							do_write()
						end
					end
				)
			else
				do_write()
			end
		end

		vim.ui.input({ prompt = "Otros nombres a parametrizar (coma, vacío = ninguno): " }, function(extra_str)
			local extras = {}
			for tok in (extra_str or ""):gmatch("[%w_/~]+") do
				extras[#extras + 1] = tok
			end

			local function finish(use_obj)
				write(M.templatize(body, use_obj and obj or nil, extras))
			end

			if obj and obj ~= "" and body:upper():find(obj:upper(), 1, true) then
				vim.ui.select(
					{ "Sí, " .. obj .. " → $OBJECT (automático)", "No, dejar literal" },
					{ prompt = "¿Generalizar el nombre del objeto?" },
					function(ch)
						if not ch then
							return
						end
						finish(ch:match("^Sí") ~= nil)
					end
				)
			else
				finish(false)
			end
		end)
	end)
end

-- ─── Seed ─────────────────────────────────────────────────────────────────────

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
	if #M.list_dir(dir) > 0 then
		return
	end
	for name, body in pairs(SEED) do
		pcall(vim.fn.writefile, vim.split(body, "\n"), dir .. "/" .. name .. ".abap")
	end
end

-- ─── Setup ────────────────────────────────────────────────────────────────────

function M.edit_dir()
	vim.cmd("edit " .. vim.fn.fnameescape(M.dir()))
end

local function save_visual()
	local s, e = vim.fn.line("v"), vim.fn.line(".")
	if s > e then
		s, e = e, s
	end
	M.save(s, e)
end

function M.setup()
	vim.api.nvim_create_user_command("SapTemplate", function()
		M.pick()
	end, { desc = "sap-nvim: Insertar plantilla (picker)" })
	vim.api.nvim_create_user_command("SapTemplateSave", function(o)
		if o.range == 2 then
			M.save(o.line1, o.line2)
		else
			M.save()
		end
	end, { range = true, desc = "sap-nvim: Guardar buffer/selección como plantilla" })
	vim.api.nvim_create_user_command("SapTemplatesDir", function()
		notify("Plantillas en: " .. M.dir())
	end, { desc = "sap-nvim: Ruta del store de plantillas" })
	vim.api.nvim_create_user_command("SapTemplateEdit", function()
		M.edit_dir()
	end, { desc = "sap-nvim: Abrir/editar la carpeta de plantillas" })

	vim.keymap.set("n", "<leader>aPi", function()
		M.pick()
	end, { desc = "Plantillas: insertar (picker)" })
	vim.keymap.set("n", "<leader>aPs", function()
		M.save()
	end, { desc = "Plantillas: guardar buffer" })
	vim.keymap.set("v", "<leader>aPs", save_visual, { desc = "Plantillas: guardar selección" })
	vim.keymap.set("v", "<leader>aP", save_visual, { desc = "Plantillas: guardar selección" })
	vim.keymap.set("n", "<leader>aPd", function()
		notify("Plantillas en: " .. M.dir())
	end, { desc = "Plantillas: carpeta (ruta)" })
	vim.keymap.set("n", "<leader>aPe", function()
		M.edit_dir()
	end, { desc = "Plantillas: editar carpeta" })

	pcall(M.seed)
end

return M
