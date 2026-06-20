-- Debugger ABAP: el ADAPTADOR lo aporta sap-nvim.integrations.dap (servidor DAP
-- en proceso vía ADT). Aquí solo el motor nvim-dap + la UI.
return {
	{
		"mfussenegger/nvim-dap",
		config = function()
			-- Iconos en la barra de la izquierda (signcolumn): se definen al cargar dap,
			-- así el breakpoint SE VE en cuanto lo pones (antes de abrir el panel dap-ui).
			vim.fn.sign_define("DapBreakpoint", { text = "●", texthl = "DapBreakpoint", numhl = "" })
			vim.fn.sign_define(
				"DapBreakpointCondition",
				{ text = "◆", texthl = "DapBreakpointCondition", numhl = "" }
			)
			vim.fn.sign_define("DapBreakpointRejected", { text = "✗", texthl = "DiagnosticError", numhl = "" })
			vim.fn.sign_define("DapLogPoint", { text = "◆", texthl = "DapLogPoint", numhl = "" })
			vim.fn.sign_define("DapStopped", { text = "▶", texthl = "DapStopped", linehl = "Visual", numhl = "" })
			-- Colores de los iconos
			local set = vim.api.nvim_set_hl
			set(0, "DapBreakpoint", { fg = "#f7768e", bold = true }) -- rojo
			set(0, "DapBreakpointCondition", { fg = "#ff9e64", bold = true }) -- naranja
			set(0, "DapLogPoint", { fg = "#7dcfff" }) -- azul
			set(0, "DapStopped", { fg = "#9ece6a", bold = true }) -- verde
			-- Garantiza la barra izquierda siempre visible (para ver el breakpoint)
			vim.opt.signcolumn = "yes"
		end,
	},

	{
		"rcarriga/nvim-dap-ui",
		dependencies = { "mfussenegger/nvim-dap", "nvim-neotest/nvim-nio" },
		config = function()
			local dapui = require("dapui")
			dapui.setup()
			local dap = require("dap")
			dap.listeners.before.attach.dapui_config = function()
				dapui.open()
			end
			dap.listeners.before.launch.dapui_config = function()
				dapui.open()
			end
			dap.listeners.before.event_terminated.dapui_config = function()
				dapui.close()
			end
			dap.listeners.before.event_exited.dapui_config = function()
				dapui.close()
			end
		end,
	},

	-- Valores de variables inline mientras depuras
	{ "theHamsta/nvim-dap-virtual-text", dependencies = { "mfussenegger/nvim-dap" }, opts = {} },
}
