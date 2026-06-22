-- EL PLUGIN: sap-nvim.
-- Aporta TODA la funcionalidad SAP y sus atajos: <leader>a* (IDE), <leader>c*
-- (CDS + CTS), <leader>d* (helpers debug/ALV), gd/K/gr, completado ADT + @anotaciones,
-- y —con sap_mode— el dashboard SAP, ␣␣ (buffers), `-` (backstop) y sesión solo-SAP.
--
-- DE DÓNDE SE CARGA (auto-detección, sin tener que editar nada):
--   • Si tienes una copia de trabajo local en ~/sap-nvim → la usa (modo desarrollo: lo
--     que retoques ahí se aplica al reiniciar). Es el flujo del mantenedor.
--   • Si NO existe ~/sap-nvim → lo baja de GitHub (JCGDeveloper/sap-nvim). Es lo que pasa
--     en la máquina de un compañero que solo quiere usarlo. Cero edición manual.
-- Override: define $SAP_NVIM_DIR para apuntar a otra ruta local.

local local_dir = vim.fn.expand(vim.env.SAP_NVIM_DIR or "~/sap-nvim")

local sap = {
	"JCGDeveloper/sap-nvim",
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
}

-- Solo si la copia local existe usamos `dir`; si no, lazy tira del repo de GitHub.
if vim.fn.isdirectory(local_dir) == 1 then
	sap.dir = local_dir
end

return {
	sap,

	-- Dependencia que el plugin declara
	{ "neovim/nvim-lspconfig", lazy = true },
}
