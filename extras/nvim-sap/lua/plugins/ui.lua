-- UI: tema, statusline, menú de teclas y utilidades (snacks)
return {
	-- Tema SAP (colores propios, distintos a tu Neovim personal)
	{
		"folke/tokyonight.nvim",
		priority = 1000,
		config = function()
			require("tokyonight").setup({ style = "night" })
			pcall(vim.cmd.colorscheme, "tokyonight-night")
		end,
	},

	-- Statusline con info SAP (objeto + estado del debug)
	{
		"nvim-lualine/lualine.nvim",
		dependencies = { "nvim-tree/nvim-web-devicons" },
		event = "VeryLazy",
		opts = function()
			local function sap_obj()
				local m = vim.b.sap_obj
				if not m then
					return ""
				end
				return "  " .. (m.name or "?") .. " [" .. (m.group or "?") .. "]"
			end
			local function dap_status()
				local ok, dap = pcall(require, "dap")
				if ok and dap.status() ~= "" then
					return "  " .. dap.status()
				end
				return ""
			end
			return {
				options = {
					theme = "tokyonight",
					globalstatus = true,
					section_separators = "",
					component_separators = "│",
				},
				sections = {
					lualine_a = { "mode" },
					lualine_b = { "branch", "diff" },
					lualine_c = { { sap_obj, color = { fg = "#7fd3f7", gui = "bold" } }, "diagnostics" },
					lualine_x = { { dap_status, color = { fg = "#ffca28" } }, "filetype" },
					lualine_y = { "progress" },
					lualine_z = { "location" },
				},
			}
		end,
	},

	-- which-key: menú de <leader> (descubre TODOS los atajos del IDE SAP)
	{
		"folke/which-key.nvim",
		event = "VeryLazy",
		opts = {
			preset = "modern",
			spec = {
				{ "<leader>a", group = "SAP" },
				{ "<leader>af", group = "Buscar / Favoritos" },
				{ "<leader>aP", group = "Plantillas" },
				{ "<leader>as", group = "Sistema / Setup" },
				{ "<leader>at", group = "Transportes (ADT)" },
				{ "<leader>av", group = "Ver / Datos" },
				{ "<leader>c", group = "CTS / CDS" },
				{ "<leader>d", group = "Debug" },
				{ "<leader>f", group = "Buscar (pickers)" },
				{ "<leader>b", group = "Buffers" },
				{ "<leader>g", group = "Git" },
				{ "<leader>w", group = "Ventanas" },
			},
		},
	},

	-- snacks: pickers, input/select, notificaciones, indent (sin dashboard: usamos
	-- el dashboard SAP de core/home).
	{
		"folke/snacks.nvim",
		priority = 900,
		lazy = false,
		opts = {
			-- bigfile OFF: los objetos SAP de la caché disparaban "Big file detected" y
			-- desactivaban treesitter/features. No queremos eso aquí.
			bigfile = { enabled = false },
			quickfile = { enabled = true },
			picker = { enabled = true },
			input = { enabled = true },
			notifier = { enabled = true },
			indent = { enabled = true },
			scope = { enabled = true },
			explorer = { enabled = true },
			dashboard = { enabled = false },
		},
	},
}
