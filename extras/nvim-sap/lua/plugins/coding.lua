-- Coding: completado, treesitter, pares/comentarios/surround, git
return {
	-- Completado (con las fuentes ADT del plugin). fuzzy lua = sin build de Rust.
	{
		"saghen/blink.cmp",
		version = "*",
		event = "InsertEnter",
		opts = {
			fuzzy = { implementation = "lua" },
			keymap = { preset = "default" },
			completion = {
				documentation = { auto_show = true },
				ghost_text = { enabled = true },
			},
			signature = { enabled = true },
			sources = {
				default = { "abap_local", "sap_adt", "path", "buffer" },
				per_filetype = {
					abap = { "abap_local", "sap_adt", "buffer" },
					cds = { "abap_local", "sap_adt", "buffer" },
					acds = { "abap_local", "sap_adt", "buffer" },
					ddls = { "abap_local", "sap_adt", "buffer" },
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

	-- Treesitter — rama clásica `master` (la `main` eliminó nvim-treesitter.configs).
	-- El plugin sap-nvim registra los parsers abap/cds en su propio setup.
	{
		"nvim-treesitter/nvim-treesitter",
		branch = "master",
		build = ":TSUpdate",
		event = { "BufReadPost", "BufNewFile" },
		opts = {
			highlight = { enable = true },
			indent = { enable = true },
			ensure_installed = { "lua", "vim", "vimdoc", "bash", "json", "yaml", "markdown", "sql" },
		},
		config = function(_, opts)
			require("nvim-treesitter.configs").setup(opts)
		end,
	},

	-- Telescope: lo usa el plugin para la búsqueda en vivo (<leader>aS) y el picker de
	-- plantillas. VeryLazy para que esté en el rtp cuando el plugin haga require.
	{
		"nvim-telescope/telescope.nvim",
		dependencies = { "nvim-lua/plenary.nvim" },
		event = "VeryLazy",
		config = true,
	},

	-- Pares, comentarios y surround (mini.nvim)
	{ "echasnovski/mini.pairs", event = "InsertEnter", opts = {} },
	{ "echasnovski/mini.comment", event = "VeryLazy", opts = {} },
	{ "echasnovski/mini.surround", event = "VeryLazy", opts = {} },

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
