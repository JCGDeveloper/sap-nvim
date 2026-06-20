-- EL PLUGIN: sap-nvim (tu copia local de ~/sap-nvim).
-- Aporta TODA la funcionalidad SAP y sus atajos: <leader>a* (IDE), <leader>c*
-- (CDS + CTS), <leader>d* (helpers debug/ALV), gd/K/gr, completado ADT + @anotaciones,
-- y —con sap_mode— el dashboard SAP, ␣␣ (buffers), `-` (backstop) y sesión solo-SAP.
return {
	{
		"JCGDeveloper/sap-nvim",
		-- dir = tu COPIA DE TRABAJO local: lazy carga el plugin DESDE ~/sap-nvim (no del
		-- clon de GitHub). Cualquier cosa que retoques o añadas ahí se aplica en nvim-sap
		-- al reiniciar. Es el mismo proyecto que editamos/commiteamos.
		dir = vim.fn.expand("~/sap-nvim"),
		lazy = false,
		priority = 800,
		dependencies = {
			"nvim-treesitter/nvim-treesitter",
			"neovim/nvim-lspconfig",
			"saghen/blink.cmp",
		},
		config = function()
			require("sap-nvim").setup({
				sap_mode = true,
				-- Formatear al guardar: CDS por llaves (local) y ABAP con el Pretty Printer
				-- de SAP. Si el auto-formato de ABAP te molesta, pon on_save = false.
				format = { on_save = true },
			})
		end,
	},

	-- Dependencia que el plugin declara
	{ "neovim/nvim-lspconfig", lazy = true },
}
