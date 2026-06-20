-- Keymaps GENERALES del editor (Neovim SAP).
-- OJO: los atajos SAP (<leader>a*, <leader>c* CDS+CTS, <leader>d* helpers, gd/K/gr,
-- completado) los aporta el PLUGIN sap-nvim — aquí NO se duplican. Esto añade lo que
-- el plugin no trae: navegación de editor, pickers (snacks) y el stepping de nvim-dap.

local map = vim.keymap.set

-- ── Básicos ─────────────────────────────────────────────────────────────────
map("n", "<C-s>", "<cmd>w<cr>", { desc = "Guardar" })
map("i", "<C-s>", "<esc><cmd>w<cr>", { desc = "Guardar" })
map("n", "<esc>", "<cmd>nohlsearch<cr>", { desc = "Quitar resaltado" })
map("n", "<leader>qq", "<cmd>qa<cr>", { desc = "Salir de todo" })
map("n", "<leader>w", "<cmd>w<cr>", { desc = "Guardar" })

-- ── Ventanas ────────────────────────────────────────────────────────────────
map("n", "<C-h>", "<C-w>h", { desc = "Ventana izquierda" })
map("n", "<C-j>", "<C-w>j", { desc = "Ventana abajo" })
map("n", "<C-k>", "<C-w>k", { desc = "Ventana arriba" })
map("n", "<C-l>", "<C-w>l", { desc = "Ventana derecha" })
map("n", "<leader>-", "<C-w>s", { desc = "Split horizontal" })
map("n", "<leader>|", "<C-w>v", { desc = "Split vertical" })

-- ── Buffers ─────────────────────────────────────────────────────────────────
map("n", "<S-l>", "<cmd>bnext<cr>", { desc = "Buffer siguiente" })
map("n", "<S-h>", "<cmd>bprevious<cr>", { desc = "Buffer anterior" })
map("n", "<leader>bd", "<cmd>bdelete<cr>", { desc = "Cerrar buffer" })
-- Nota: ␣␣ (buffers SAP) lo mapea core/home en modo SAP.

-- ── Mover líneas ────────────────────────────────────────────────────────────
map("n", "<A-j>", "<cmd>m .+1<cr>==", { desc = "Bajar línea" })
map("n", "<A-k>", "<cmd>m .-2<cr>==", { desc = "Subir línea" })
map("v", "<A-j>", ":m '>+1<cr>gv=gv", { desc = "Bajar selección" })
map("v", "<A-k>", ":m '<-2<cr>gv=gv", { desc = "Subir selección" })
map("v", "<", "<gv")
map("v", ">", ">gv")

-- ── Pickers (snacks) ────────────────────────────────────────────────────────
local function pick(fn)
	return function()
		local ok, Snacks = pcall(require, "snacks")
		if ok and Snacks.picker and Snacks.picker[fn] then
			Snacks.picker[fn]()
		end
	end
end
map("n", "<leader>ff", pick("files"), { desc = "Buscar ficheros (caché)" })
map("n", "<leader>fg", pick("grep"), { desc = "Grep en ficheros" })
map("n", "<leader>fb", pick("buffers"), { desc = "Buffers abiertos" })
map("n", "<leader>fr", pick("recent"), { desc = "Recientes" })
map("n", "<leader>fh", pick("help"), { desc = "Ayuda (:help)" })
map("n", "<leader>fk", pick("keymaps"), { desc = "Keymaps" })
map("n", "<leader>fe", function()
	local ok, Snacks = pcall(require, "snacks")
	if ok and Snacks.explorer then
		Snacks.explorer()
	end
end, { desc = "Explorador de ficheros" })

-- ── Debugger (nvim-dap) — STEPPING estándar (no está en el plugin) ───────────
-- Iniciar la sesión ABAP: <leader>ad (plugin). Cerrar todas: <leader>dX (plugin).
local dap = function(fn)
	return function()
		require("dap")[fn]()
	end
end
map("n", "<leader>db", function()
	require("dap").toggle_breakpoint()
end, { desc = "Debug: breakpoint on/off" })
map("n", "<leader>dB", function()
	require("dap").set_breakpoint(vim.fn.input("Condición del breakpoint: "))
end, { desc = "Debug: breakpoint condicional" })
map("n", "<leader>dc", dap("continue"), { desc = "Debug: continuar (F5)" })
map("n", "<leader>di", dap("step_into"), { desc = "Debug: step into (F11)" })
map("n", "<leader>do", dap("step_out"), { desc = "Debug: step out (F12)" })
map("n", "<leader>dO", dap("step_over"), { desc = "Debug: step over (F10)" })
map("n", "<leader>dr", function()
	require("dap").repl.toggle()
end, { desc = "Debug: REPL" })
map("n", "<leader>dt", dap("terminate"), { desc = "Debug: terminar (esta)" })
map("n", "<leader>du", function()
	require("dapui").toggle()
end, { desc = "Debug: panel dap-ui" })
map("n", "<leader>de", function()
	require("dapui").eval()
end, { desc = "Debug: evaluar expresión" })
map("n", "<F5>", dap("continue"), { desc = "DAP: continuar" })
map("n", "<F10>", dap("step_over"), { desc = "DAP: step over" })
map("n", "<F11>", dap("step_into"), { desc = "DAP: step into" })
map("n", "<F12>", dap("step_out"), { desc = "DAP: step out" })
