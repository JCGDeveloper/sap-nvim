-- lua/sap-nvim/core/search.lua
-- Buscador global de objetos SAP (en vivo, ASÍNCRONO — como VSCode).
--
-- El finder NO bloquea el hilo de UI: cada pulsación lanza la búsqueda con
-- adt_http.request_async (daemon/curl en jobstart). Para no inundar la red ni la UI:
--   • debounce de 200 ms (no busca hasta que dejas de teclear un instante),
--   • descarte de respuestas obsoletas (si sigues escribiendo, la respuesta vieja se ignora).
-- Antes era síncrono (vim.fn.system por tecla) y daba microlag.
--
-- FILTRO POR TIPO (como VSCode): el endpoint de ADT acepta `&objectType=<GRUPO>`
-- (DDLS, TABL, PROG, CLAS…). Dentro del picker, `<C-f>` abre el selector de tipo y
-- refresca la lista en vivo. `open_cds_picker()` arranca ya filtrado a CDS (DDLS).

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local source = require("sap-nvim.core.source")

local DEBOUNCE_MS = 200
local MAX_RESULTS = 50

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Traductor de tipos ADT (`adtcore:type`, p.ej. "CLAS/OC") a nombre humano + el
-- "group" con el que source.open/cds sabe abrirlo. Los grupos RAP (ddls/ddlx/dcl/
-- bdef/srvd) los enruta source.open hacia core/cds.
local TYPE_MAP = {
	["CLAS/OC"] = { label = "Class", group = "class" },
	["INTF/OI"] = { label = "Interface", group = "interface" },
	["PROG/P"] = { label = "Program", group = "program" },
	["PROG/I"] = { label = "Include", group = "include" },
	["FUGR/F"] = { label = "Function Group", group = "functiongroup" },
	["FUGR/FF"] = { label = "Function Module", group = "functionmodule" },
	["FUNC/FF"] = { label = "Function Module", group = "functionmodule" },
	["TABL/DT"] = { label = "Table", group = "table" },
	["TABL/DS"] = { label = "Structure", group = "structure" },
	["VIEW/DV"] = { label = "View (DDIC)", group = "table" },
	["TTYP/TT"] = { label = "Table Type", group = "tabletype" },
	["DTEL/DE"] = { label = "Data Element", group = "dataelement" },
	["DOMA/DO"] = { label = "Domain", group = "domain" },
	["ENQU/EL"] = { label = "Lock Object", group = nil },
	["MSAG/N"] = { label = "Message Class", group = "messageclass" },
	["TRAN/T"] = { label = "Transaction", group = nil },
	["DEVC/K"] = { label = "Package", group = nil },
	-- CDS / RAP (se abren por ADT directo vía core/cds)
	["DDLS/DF"] = { label = "CDS View", group = "ddls" },
	["DDLX/EX"] = { label = "Metadata Ext.", group = "ddlx" },
	["DCLS/DL"] = { label = "Access Control", group = "dcl" },
	["BDEF/BDO"] = { label = "Behavior Def.", group = "bdef" },
	["SRVD/SRV"] = { label = "Service Def.", group = "srvd" },
	["SRVB/SVB"] = { label = "Service Binding", group = nil },
	["INFO"] = { label = "Info", group = nil },
	["ERROR"] = { label = "Error", group = nil },
}

-- Tipos seleccionables en el filtro (`<C-f>`). `code` = valor de `objectType` en ADT
-- (prefijo del adtcore:type). `nil` = sin filtro (todos). Tomado de la lista que usa
-- la extensión de VSCode (abapSearchService.searchObjects).
local OBJECT_TYPES = {
	{ code = nil, label = "Todos los tipos" },
	{ code = "DDLS", label = "CDS View (DDL Source)" },
	{ code = "DDLX", label = "Metadata Extension" },
	{ code = "DCLS", label = "Access Control (DCL)" },
	{ code = "BDEF", label = "Behavior Definition" },
	{ code = "SRVD", label = "Service Definition" },
	{ code = "SRVB", label = "Service Binding" },
	{ code = "CLAS", label = "Class" },
	{ code = "INTF", label = "Interface" },
	{ code = "PROG", label = "Program / Report" },
	{ code = "FUGR", label = "Function Group" },
	{ code = "FUNC", label = "Function Module" },
	{ code = "TABL", label = "Database Table / Structure" },
	{ code = "VIEW", label = "View (DDIC)" },
	{ code = "TTYP", label = "Table Type" },
	{ code = "DTEL", label = "Data Element" },
	{ code = "DOMA", label = "Domain" },
	{ code = "ENQU", label = "Lock Object" },
	{ code = "MSAG", label = "Message Class" },
	{ code = "TRAN", label = "Transaction" },
	{ code = "DEVC", label = "Package" },
}

-- Conjunto de grupos que componen "CDS/RAP" para el picker dedicado.
local CDS_TYPES = {
	{ code = "DDLS", label = "CDS View (DDL Source)" },
	{ code = "DDLX", label = "Metadata Extension" },
	{ code = "DCLS", label = "Access Control (DCL)" },
	{ code = "BDEF", label = "Behavior Definition" },
	{ code = "SRVD", label = "Service Definition" },
	{ code = "SRVB", label = "Service Binding" },
}

local function unxml(s)
	return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
end

-- Filtro de DESCRIPCIÓN (cliente): el quickSearch de ADT solo matchea por NOMBRE técnico,
-- no por descripción (verificado contra el sistema). Así que el servidor busca por nombre y
-- aquí refinamos por la descripción. Patrón tipo glob: `*` = comodín; sin `*` = «contiene».
local function glob_to_pat(glob)
	return (glob:lower():gsub("[%(%)%.%%%+%-%?%[%]%^%$]", "%%%1"):gsub("%*", ".*"))
end
local function desc_matches(desc, glob)
	if not glob or glob == "" then
		return true
	end
	return (desc or ""):lower():find(glob_to_pat(glob)) ~= nil
end

local function url_encode(str)
	if not str then
		return ""
	end
	return (str:gsub("[^%w_]", function(c)
		if c == "*" then
			return "*"
		end
		return string.format("%%%02X", string.byte(c))
	end))
end

-- Parsea el XML de resultados (NetWeaver moderno; fallback Atom). Devuelve filas crudas.
local function parse_body(body, prompt)
	local results, seen = {}, {}
	if not body or body == "" then
		return results
	end
	-- Parseador Moderno (NetWeaver)
	for tag in body:gmatch("<[^>]+>") do
		local name = tag:match('adtcore:name="([^"]*)"')
		local typ = tag:match('adtcore:type="([^"]*)"')
		local desc = tag:match('adtcore:description="([^"]*)"')
		if name and typ and not seen[name] then
			seen[name] = true
			results[#results + 1] = { name = unxml(name), adt_type = unxml(typ), desc = unxml(desc or ""), __prompt = prompt }
		end
	end
	-- Parseador Antiguo (Atom Feed) por compatibilidad
	if #results == 0 then
		for entry in body:gmatch("<[a-zA-Z0-9:]*entry>(.-)</[a-zA-Z0-9:]*entry>") do
			local name = entry:match("<[a-zA-Z0-9:]*title[^>]*>([^<]*)</")
			local typ = entry:match('term="([^"]*)"')
			local desc = entry:match("<[a-zA-Z0-9:]*summary[^>]*>([^<]*)</")
			if name and typ and not seen[name] then
				seen[name] = true
				results[#results + 1] =
					{ name = unxml(name), adt_type = unxml(typ), desc = unxml(desc or ""), __prompt = prompt }
			end
		end
	end
	return results
end

-- opts:
--   object_type  string|nil  filtro inicial (código ADT: "DDLS", "TABL"…). nil = todos.
--   title        string|nil  título base del picker.
--   types        table|nil   subconjunto de tipos elegibles en <C-f> (default OBJECT_TYPES).
--   desc_filter  string|nil  patrón de descripción inicial (glob con `*`); filtra en cliente.
--   default_text string|nil  texto inicial del prompt (para reabrir conservando lo escrito).
function M.open_picker(opts)
	opts = opts or {}
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		notify("Telescope no está disponible.", vim.log.levels.WARN)
		return
	end
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	-- Estado mutable que lee el finder en cada llamada (lo cambian <C-f>/<C-d>).
	local state = {
		object_type = opts.object_type, -- código ADT o nil
		desc_filter = opts.desc_filter, -- patrón glob de descripción o nil
		base_title = opts.title or "🔍 Buscar Objeto SAP (ADT)",
		type_list = opts.types or OBJECT_TYPES,
	}

	local function type_label()
		if not state.object_type then
			return "Todos"
		end
		for _, t in ipairs(OBJECT_TYPES) do
			if t.code == state.object_type then
				return t.label
			end
		end
		return state.object_type
	end

	local function current_title()
		local t = string.format("%s  ·  Tipo: %s", state.base_title, type_label())
		if state.desc_filter and state.desc_filter ~= "" then
			t = t .. "  ·  Descr: " .. state.desc_filter
		end
		return t .. "  ·  <C-f> tipo · <C-d> descr"
	end

	local function entry_maker(entry)
		local type_info = TYPE_MAP[entry.adt_type]
		local label = type_info and type_info.label or entry.adt_type
		return {
			value = entry,
			display = string.format("%-25s [%-15s] %s", entry.name, label, entry.desc or ""),
			-- Engañamos al sorter de Telescope para que no oculte los resultados de SAP.
			ordinal = entry.name .. " " .. (entry.desc or "") .. " " .. (entry.__prompt or ""),
		}
	end
	local function info(desc, adt_type, prompt)
		return entry_maker({ name = "…", adt_type = adt_type, desc = desc, __prompt = prompt })
	end

	-- Estado por picker: generación (para descartar obsoletas) + timer de debounce.
	local gen, timer = 0, nil
	local function stop_timer()
		if timer then
			pcall(function() timer:stop() end)
			pcall(function() timer:close() end)
			timer = nil
		end
	end

	-- Finder ASÍNCRONO: __call(self, prompt, process_result, process_complete).
	local finder = setmetatable({ close = stop_timer }, {
		__call = function(_, prompt, process_result, process_complete)
			prompt = prompt or ""
			local has_desc = state.desc_filter ~= nil and state.desc_filter ~= ""
			-- Con filtro de descripción se puede buscar aunque el nombre esté vacío (name=`*`).
			if #prompt < 3 and not has_desc then
				process_result(info("Escribe al menos 3 letras…", "INFO", prompt))
				process_complete()
				return
			end
			if not adt_http.is_available() then
				process_result(info("ADT no disponible. Revisa tu conexión.", "ERROR", prompt))
				process_complete()
				return
			end

			gen = gen + 1
			local my_gen = gen
			stop_timer()
			timer = vim.loop.new_timer()
			timer:start(DEBOUNCE_MS, 0, vim.schedule_wrap(function()
				stop_timer()
				if my_gen ~= gen then
					return -- seguiste escribiendo: esta búsqueda ya no interesa
				end

				local query
				if #prompt >= 1 then
					query = prompt:upper():gsub("%*+", "*")
					if query:sub(-1) ~= "*" then
						query = query .. "*"
					end
				else
					query = "*" -- solo filtro de descripción: pedimos todo (acotado por tipo)
				end
				-- Con filtro de descripción el servidor devuelve por nombre y refinamos en
				-- cliente, así que pedimos MÁS candidatos para tener de dónde filtrar.
				local max = has_desc and 200 or MAX_RESULTS
				local req_path = "/sap/bc/adt/repository/informationsystem/search?query="
					.. url_encode(query)
					.. "&maxResults=" .. max
					.. "&operation=quickSearch"
				if state.object_type then
					req_path = req_path .. "&objectType=" .. url_encode(state.object_type)
				end

				adt_http.request_async({
					method = "GET",
					path = req_path,
					accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
				}, function(body)
					vim.schedule(function()
						if my_gen ~= gen then
							return -- respuesta obsoleta: el prompt ya cambió
						end
						local results = parse_body(body, prompt)
						-- Refinado por descripción en cliente (el servidor solo matchea nombre).
						if has_desc then
							local filtered = {}
							for _, r in ipairs(results) do
								if desc_matches(r.desc, state.desc_filter) then
									filtered[#filtered + 1] = r
								end
							end
							results = filtered
						end
						if #results == 0 then
							local msg = has_desc and "Ningún objeto con esa descripción."
								or "SAP no encontró objetos."
							process_result(info(msg, "INFO", prompt))
						else
							for _, r in ipairs(results) do
								if process_result(entry_maker(r)) then
									break
								end
							end
						end
						process_complete()
					end)
				end)
			end))
		end,
	})

	pickers
		.new({}, {
			prompt_title = current_title(),
			default_text = opts.default_text,
			finder = finder,
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
				-- Cambiar el filtro de tipo: CERRAMOS el picker, elegimos el tipo y lo
				-- REABRIMOS con el mismo texto escrito. Abrir un vim.ui.select ENCIMA del
				-- picker de Telescope hacía que este se cerrara al perder el foco (el bug
				-- "se sale de la pantalla de buscar"); este flujo secuencial es estable.
				local function pick_type()
					local items = {}
					for _, t in ipairs(state.type_list) do
						items[#items + 1] = t
					end
					local typed = action_state.get_current_line() -- lo que llevas escrito
					actions.close(prompt_bufnr)
					vim.schedule(function()
						vim.ui.select(items, {
							prompt = "Filtrar por tipo de objeto:",
							format_item = function(t)
								return t.label
							end,
						}, function(choice)
							-- choice nil = cancelado (deja el tipo igual); si eligió, choice.code
							-- puede ser nil = "Todos los tipos" (quita el filtro).
							local ot = state.object_type
							if choice then
								ot = choice.code
							end
							M.open_picker({
								object_type = ot,
								title = state.base_title,
								types = state.type_list,
								desc_filter = state.desc_filter,
								default_text = typed,
							})
						end)
					end)
				end

				-- Filtrar por DESCRIPCIÓN: mismo patrón (cerrar→pedir→reabrir). Glob con `*`;
				-- vacío = quita el filtro. El servidor busca por nombre y refinamos en cliente.
				local function pick_desc()
					local typed = action_state.get_current_line()
					actions.close(prompt_bufnr)
					vim.schedule(function()
						vim.ui.input({
							prompt = "Filtrar por descripción (usa * como comodín; vacío = sin filtro): ",
							default = state.desc_filter or "",
						}, function(input)
							-- input nil = cancelado (conserva el filtro); "" = lo quita.
							local df = state.desc_filter
							if input ~= nil then
								df = vim.trim(input) ~= "" and vim.trim(input) or nil
							end
							M.open_picker({
								object_type = state.object_type,
								title = state.base_title,
								types = state.type_list,
								desc_filter = df,
								default_text = typed,
							})
						end)
					end)
				end

				map("i", "<C-f>", pick_type)
				map("n", "<C-f>", pick_type)
				map("i", "<C-d>", pick_desc)
				map("n", "<C-d>", pick_desc)

				actions.select_default:replace(function()
					local selection = action_state.get_selected_entry()
					if not selection then
						return
					end
					if selection.value.adt_type == "INFO" or selection.value.adt_type == "ERROR" then
						return
					end
					actions.close(prompt_bufnr)
					local type_info = TYPE_MAP[selection.value.adt_type]
					if type_info and type_info.group then
						source.open(selection.value.name, type_info.group)
					else
						notify("No se puede abrir este objeto (" .. selection.value.adt_type .. ")", vim.log.levels.WARN)
					end
				end)
				return true
			end,
		})
		:find()
end

-- Picker dedicado a CDS/RAP: arranca filtrado a DDLS y el <C-f> solo ofrece grupos CDS.
function M.open_cds_picker()
	M.open_picker({
		object_type = "DDLS",
		title = "🧩 Buscar CDS / RAP (ADT)",
		types = CDS_TYPES,
	})
end

function M.setup()
	vim.api.nvim_create_user_command("SapSearchLive", function()
		M.open_picker()
	end, { desc = "sap-nvim: Búsqueda global (filtro de tipo <C-f>, descripción <C-d>)" })

	vim.api.nvim_create_user_command("SapSearchCds", function()
		M.open_cds_picker()
	end, { desc = "sap-nvim: Búsqueda en vivo de CDS / RAP" })

	vim.keymap.set("n", "<leader>aS", function()
		M.open_picker()
	end, { desc = "ABAP: Buscar objeto (tipo <C-f>, descripción <C-d>)" })
end

return M
