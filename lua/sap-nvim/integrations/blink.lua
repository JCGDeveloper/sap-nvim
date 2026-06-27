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
			-- SAP primero: en CDS los campos del DDIC deben salir antes que keywords/snippets.
			default = { "sap_adt", "lsp", "path", "snippets", "buffer", "abap_snippets" },
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
					score_offset = 1000, -- Prioridad alta para campos/métodos SAP
					enabled = function()
						local ok_intel, intel = pcall(require, "sap-nvim.core.intel")
						local ok_cds, cds = pcall(require, "sap-nvim.core.cds")
						return (ok_intel and intel.is_sap_ft(vim.bo.filetype))
							or (ok_cds and cds.is_cds_buf(vim.api.nvim_get_current_buf()))
					end,
				},
			},
		},
	})
end

return M
