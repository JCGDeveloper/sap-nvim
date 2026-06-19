-- lua/sap-nvim/core/search.lua
-- Buscador global de objetos SAP (en vivo, ASÍNCRONO — como VSCode).
--
-- El finder NO bloquea el hilo de UI: cada pulsación lanza la búsqueda con
-- adt_http.request_async (daemon/curl en jobstart). Para no inundar la red ni la UI:
--   • debounce de 200 ms (no busca hasta que dejas de teclear un instante),
--   • descarte de respuestas obsoletas (si sigues escribiendo, la respuesta vieja se ignora).
-- Antes era síncrono (vim.fn.system por tecla) y daba microlag.

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local source = require("sap-nvim.core.source")

local DEBOUNCE_MS = 200
local MAX_RESULTS = 50

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

-- Traductor de tipos ADT a nombres humanos y su "group" para abrir
local TYPE_MAP = {
	["CLAS/OC"] = { label = "Class", group = "class" },
	["INTF/OI"] = { label = "Interface", group = "interface" },
	["PROG/P"] = { label = "Program", group = "program" },
	["PROG/I"] = { label = "Include", group = "include" },
	["FUGR/F"] = { label = "Function Group", group = "functiongroup" },
	["FUGR/FF"] = { label = "Function Module", group = "functionmodule" },
	["TABL/DT"] = { label = "Table", group = "table" },
	["TTYP/TT"] = { label = "Table Type", group = "tabletype" },
	["DTEL/DE"] = { label = "Data Element", group = "dataelement" },
	["DOMA/DO"] = { label = "Domain", group = "domain" },
	["MSAG/N"] = { label = "Message Class", group = "messageclass" },
	["INFO"] = { label = "Info", group = nil },
	["ERROR"] = { label = "Error", group = nil },
}

local function unxml(s)
	return (s or ""):gsub("&lt;", "<"):gsub("&gt;", ">"):gsub("&quot;", '"'):gsub("&apos;", "'"):gsub("&amp;", "&")
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

function M.open_picker()
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		notify("Telescope no está disponible.", vim.log.levels.WARN)
		return
	end
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

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
			if #prompt < 3 then
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

				local query = prompt:upper():gsub("%*+", "*")
				if query:sub(-1) ~= "*" then
					query = query .. "*"
				end
				local req_path = "/sap/bc/adt/repository/informationsystem/search?query="
					.. url_encode(query)
					.. "&maxResults=" .. MAX_RESULTS
					.. "&operation=quickSearch"

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
						if #results == 0 then
							process_result(info("SAP no encontró objetos.", "INFO", prompt))
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
			prompt_title = "🔍 Buscar Objeto SAP (ADT)",
			finder = finder,
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr)
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

function M.setup()
	vim.api.nvim_create_user_command("SapSearchLive", function()
		M.open_picker()
	end, { desc = "sap-nvim: Búsqueda global" })
	vim.keymap.set("n", "<leader>aS", function()
		M.open_picker()
	end, { desc = "ABAP: Buscar objeto" })
end

return M
