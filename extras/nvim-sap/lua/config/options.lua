-- Opciones del editor (Neovim SAP)
local o = vim.opt

o.number = true
o.relativenumber = true
o.signcolumn = "yes"
o.cursorline = true
o.termguicolors = true
o.wrap = false
o.scrolloff = 6
o.sidescrolloff = 8

-- Indentación (ABAP suele ir a 2 espacios; el plugin reformatea a tu gusto)
o.expandtab = true
o.shiftwidth = 2
o.tabstop = 2
o.smartindent = true

-- Búsqueda
o.ignorecase = true
o.smartcase = true
o.hlsearch = true
o.incsearch = true

-- Portapapeles del sistema (WSL incluido)
o.clipboard = "unnamedplus"

-- Ficheros: la fuente real es SAP; nada de swap/backup que estorbe en la caché
o.swapfile = false
o.backup = false
o.undofile = true
o.updatetime = 250
o.timeoutlen = 400

-- Splits
o.splitright = true
o.splitbelow = true

-- UI
o.pumheight = 12
o.showmode = false
o.laststatus = 3
o.mouse = "a"
o.confirm = true
