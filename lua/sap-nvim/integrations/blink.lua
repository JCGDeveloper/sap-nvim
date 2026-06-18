-- sap-nvim.integrations.blink
-- Integración con blink.cmp para snippets ABAP y autocompletado del sistema (ADT)

local M = {}

local snippets = require("sap-nvim.core.snippets")

function M.setup(opts)
	opts = opts or {}

	local ok, blink = pcall(require, "blink.cmp")
	if not ok then
		return
	end

	-- Crear fuente de snippets ABAP para blink
	local abap_snippets = {}

	for key, snip in pairs(snippets) do
		table.insert(abap_snippets, {
			trigger = snip.trig,
			body = snip.body,
			name = snip.name,
		})
	end

	-- Registrar snippets y el motor de SAP ADT en blink
	blink.setup({
		sources = {
			-- IMPORTANTE: Añadimos 'sap_adt' y 'abap_snippets' a la lista para que se muestren
			default = { "lsp", "path", "snippets", "buffer", "abap_snippets", "sap_adt" },
			providers = {
				-- Tu provider original de snippets
				abap_snippets = {
					name = "abap_snippets",
					module = "blink.cmp.sources.snippets",
					enabled = function()
						return vim.bo.filetype == "abap"
					end,
					opts = {
						snippets = abap_snippets,
					},
				},

				-- NUEVO: El provider que se conecta a SAP para los métodos
				sap_adt = {
					name = "SAP",
					module = "sap-nvim.core.blink_source", -- Apunta al archivo nuevo que creaste
					score_offset = 100, -- Prioridad alta para que los métodos salgan los primeros
					enabled = function()
						return vim.bo.filetype == "abap"
					end,
				},
			},
		},
	})
end

return M
