-- lua/sap-nvim/core/search.lua
-- Buscador global de objetos SAP (Versión Estable Síncrona)

local M = {}
local adt_http = require("sap-nvim.core.adt_http")
local source = require("sap-nvim.core.source")

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
	return (
		str:gsub("[^%w_]", function(c)
			if c == "*" then
				return "*"
			end
			return string.format("%%%02X", string.byte(c))
		end)
	)
end

function M.open_picker()
	local ok, pickers = pcall(require, "telescope.pickers")
	if not ok then
		return
	end

	local finders = require("telescope.finders")
	local conf = require("telescope.config").values
	local actions = require("telescope.actions")
	local action_state = require("telescope.actions.state")

	local dynamic_finder = finders.new_dynamic({
		fn = function(prompt)
			-- LIMITADOR DE LAG: 3 letras mínimo para no colapsar la red
			if not prompt or #prompt < 3 then
				return { { name = "...", adt_type = "INFO", desc = "Escribe al menos 3 letras...", __prompt = prompt } }
			end
			if not adt_http.is_available() then
				return {
					{
						name = "ERROR",
						adt_type = "ERROR",
						desc = "ADT no disponible. Revisa tu conexión.",
						__prompt = prompt,
					},
				}
			end

			local query_str = prompt:upper():gsub("%*+", "*")
			if query_str:sub(-1) ~= "*" then
				query_str = query_str .. "*"
			end

			-- Magia vital: el parámetro operation=quickSearch que evita el crash del servidor
			local req_path = "/sap/bc/adt/repository/informationsystem/search?query="
				.. url_encode(query_str)
				.. "&maxResults=50&operation=quickSearch"

			local body = adt_http.request({
				method = "GET",
				path = req_path,
				accept = "application/vnd.sap.adt.repository.informationsystem.searchresult.v1+xml, application/xml",
			})

			if not body or body == "" then
				return {
					{
						name = "ERROR HTTP",
						adt_type = "ERROR",
						desc = "El servidor SAP no responde.",
						__prompt = prompt,
					},
				}
			end

			local results = {}
			local seen = {}

			-- Parseador Moderno (NetWeaver)
			for tag in body:gmatch("<[^>]+>") do
				local name = tag:match('adtcore:name="([^"]*)"')
				local typ = tag:match('adtcore:type="([^"]*)"')
				local desc = tag:match('adtcore:description="([^"]*)"')
				if name and typ and not seen[name] then
					seen[name] = true
					table.insert(
						results,
						{ name = unxml(name), adt_type = unxml(typ), desc = unxml(desc), __prompt = prompt }
					)
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
						table.insert(
							results,
							{ name = unxml(name), adt_type = unxml(typ), desc = unxml(desc or ""), __prompt = prompt }
						)
					end
				end
			end

			if #results == 0 then
				return {
					{
						name = "0 RESULTADOS",
						adt_type = "INFO",
						desc = "SAP no encontró objetos para tu búsqueda.",
						__prompt = prompt,
					},
				}
			end

			return results
		end,
		entry_maker = function(entry)
			local type_info = TYPE_MAP[entry.adt_type]
			local label = type_info and type_info.label or entry.adt_type

			local display_text = string.format("%-25s [%-15s] %s", entry.name, label, entry.desc)

			return {
				value = entry,
				display = display_text,
				-- Engañamos al sorter de Telescope para que no oculte los resultados de SAP
				ordinal = entry.name .. " " .. entry.desc .. " " .. (entry.__prompt or ""),
			}
		end,
	})

	pickers
		.new({}, {
			prompt_title = "🔍 Buscar Objeto SAP (ADT)",
			finder = dynamic_finder,
			sorter = conf.generic_sorter({}),
			attach_mappings = function(prompt_bufnr, map)
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
						notify(
							"No se puede abrir este objeto (" .. selection.value.adt_type .. ")",
							vim.log.levels.WARN
						)
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
