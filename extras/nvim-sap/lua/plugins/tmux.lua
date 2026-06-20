-- Navegación fluida entre ventanas de Neovim y panes de tmux con <C-h/j/k/l>
-- (igual que en tu config personal).
return {
	"alexghergh/nvim-tmux-navigation",
	event = "VeryLazy",
	config = function()
		local nav = require("nvim-tmux-navigation")
		nav.setup({ disable_when_zoomed = true })
		local map = vim.keymap.set
		map("n", "<C-h>", nav.NvimTmuxNavigateLeft, { desc = "Ir a ventana/pane izquierda" })
		map("n", "<C-j>", nav.NvimTmuxNavigateDown, { desc = "Ir a ventana/pane abajo" })
		map("n", "<C-k>", nav.NvimTmuxNavigateUp, { desc = "Ir a ventana/pane arriba" })
		map("n", "<C-l>", nav.NvimTmuxNavigateRight, { desc = "Ir a ventana/pane derecha" })
	end,
}
