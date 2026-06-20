-- Coding: completado, treesitter, pares/comentarios/surround, git
return {
	-- Completado. Alineado a tu config personal (que SÍ funciona): sin version pin ni
	-- fuzzy lua; usa el binario por defecto de blink. Fuentes ADT del plugin.
	{
		"saghen/blink.cmp",
		-- Pineado al MISMO commit que tu config personal (que funciona): el último main
		-- tiene una regresión que borra el identificador al aceptar la compleción.
		commit = "78336bc89ee5365633bcf754d93df01678b5c08f",
		event = "InsertEnter",
		opts = {
			sources = {
				default = { "abap_local", "sap_adt" },
				per_filetype = {
					abap = { "abap_local", "sap_adt" },
					cds = { "abap_local", "sap_adt" },
					acds = { "abap_local", "sap_adt" },
					ddls = { "abap_local", "sap_adt" },
				},
				providers = {
					sap_adt = {
						name = "SAP",
						module = "sap-nvim.integrations.adt_completion",
						async = true,
						score_offset = 100,
					},
					abap_local = {
						name = "ABAP",
						module = "sap-nvim.integrations.abap_local",
						score_offset = 95,
						enabled = function()
							local col = vim.api.nvim_win_get_cursor(0)[2]
							local before = vim.api.nvim_get_current_line():sub(1, col)
							if before:match("[=%-]>$") or before:match("~$") then
								return false
							end
							return true
						end,
					},
				},
			},
		},
	},

	-- Treesitter — rama `main` (la `master` NO es compatible con Neovim 0.12 y peta el
	-- highlighter, p.ej. al renderizar el markdown del hover). Los objetos SAP no tienen
	-- parser (van con la sintaxis nativa abap.vim); esto es para lua/markdown/sql/etc.
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "main",
		-- MISMO commit que tu config personal (que NO crashea en Neovim 0.12). El último
		-- main rompe el highlighter (vim/treesitter query_predicates) al renderizar el hover.
		commit = "4916d6592ede8c07973490d9322f187e07dfefac",
		lazy = false,
		config = function()
			-- NO llamamos a require('nvim-treesitter').install(): en la rama main compila los
			-- parsers con el CLI `tree-sitter`, que no está instalado, y peta en cada arranque.
			-- Usamos los parsers que YA trae Neovim (markdown/lua/vim/vimdoc… → sirven para el
			-- hover). En main el highlight no se auto-activa: lo arrancamos por buffer; el pcall
			-- absorbe los filetypes sin parser (ABAP/CDS van con abap.vim; SQL/JSON con sintaxis).
			vim.api.nvim_create_autocmd("FileType", {
				group = vim.api.nvim_create_augroup("sapnvim_ts_start", { clear = true }),
				callback = function(ev)
					pcall(vim.treesitter.start, ev.buf)
				end,
			})
		end,
	},

	-- Pares, comentarios y surround (mini.nvim)
	{ "echasnovski/mini.pairs", event = "InsertEnter", opts = {} },
	{ "echasnovski/mini.comment", event = "VeryLazy", opts = {} },
	{ "echasnovski/mini.surround", event = "VeryLazy", opts = {} },

	-- Telescope: lo usa el plugin para la búsqueda en vivo (<leader>aS) y plantillas.
	{
		"nvim-telescope/telescope.nvim",
		dependencies = { "nvim-lua/plenary.nvim" },
		event = "VeryLazy",
		config = true,
	},

	-- Git en el margen
	{
		"lewis6991/gitsigns.nvim",
		event = { "BufReadPost", "BufNewFile" },
		opts = {
			on_attach = function(buf)
				local gs = package.loaded.gitsigns
				local function map(l, r, d)
					vim.keymap.set("n", l, r, { buffer = buf, desc = d })
				end
				map("]h", gs.next_hunk, "Git: siguiente cambio")
				map("[h", gs.prev_hunk, "Git: cambio anterior")
				map("<leader>gp", gs.preview_hunk, "Git: previsualizar cambio")
				map("<leader>gb", gs.blame_line, "Git: blame línea")
			end,
		},
	},
}
