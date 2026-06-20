-- ╔══════════════════════════════════════════════════════════════════════════╗
-- ║  NEOVIM · SAP  —  IDE completo y AISLADO (NVIM_APPNAME=nvim-sap)           ║
-- ║  No comparte config/plugins/sesión con tu Neovim personal.                ║
-- ║  Lánzalo con:   alias nvim-sap='NVIM_APPNAME=nvim-sap nvim'               ║
-- ╚══════════════════════════════════════════════════════════════════════════╝

-- Leader = espacio (ANTES de cargar plugins)
vim.g.mapleader = " "
vim.g.maplocalleader = " "

-- Enciende el "modo SAP" del plugin: dashboard, ␣␣, `-` backstop, sesión solo-SAP.
vim.g.sap_mode = true

require("config.options")

-- ── Bootstrap de lazy.nvim ──────────────────────────────────────────────────
local lazypath = vim.fn.stdpath("data") .. "/lazy/lazy.nvim"
if not (vim.uv or vim.loop).fs_stat(lazypath) then
	vim.fn.system({
		"git",
		"clone",
		"--filter=blob:none",
		"--branch=stable",
		"https://github.com/folke/lazy.nvim.git",
		lazypath,
	})
end
vim.opt.rtp:prepend(lazypath)

require("lazy").setup({
	spec = { { import = "plugins" } },
	install = { colorscheme = { "tokyonight-night" } },
	change_detection = { notify = false },
	ui = { border = "rounded" },
	checker = { enabled = false },
})

require("config.keymaps")
