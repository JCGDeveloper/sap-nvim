-- lua/sap-nvim/core/source.lua
-- Módulo de gestión de código fuente y activación masiva ADT (Ctrl + F3)
local M = {}
local adt_http = require("sap-nvim.core.adt_http")

local function notify(msg, level)
	vim.schedule(function()
		vim.notify("[sap-nvim Activación] " .. msg, level or vim.log.levels.INFO)
	end)
end

function M.cache_dir()
	return vim.fn.stdpath("cache") .. "/sap-nvim/sources"
end

-- Envía la orden de activación a SAP y analiza el árbol de errores sintácticos
function M.activate()
	local bufnr = vim.api.nvim_get_current_buf()
	local sap_obj = vim.b[bufnr].sap_obj

	if not sap_obj or not sap_obj.uri then
		notify("El archivo actual no está vinculado a un objeto SAP activo.", vim.log.levels.WARN)
		return
	end

	-- Forzamos el guardado del buffer antes de enviar la activación
	vim.cmd("write")
	notify("Guardando y activando objeto en el servidor SAP...", vim.log.levels.INFO)

	-- Payload XML oficial que exige ADT para activar métodos, programas e includes
	local xml_payload = string.format(
		[[
<?xml version="1.0" encoding="UTF-8"?>
<adtcore:objectReferences xmlns:adtcore="http://www.sap.com/adt/core">
    <adtcore:objectReference adtcore:uri="%s" adtcore:name="%s"/>
</adtcore:objectReferences>
  ]],
		sap_obj.uri,
		vim.fn.expand("%:t:r"):upper()
	)

	adt_http.request_async({
		method = "POST",
		path = "/sap/bc/adt/activation",
		query = { method = "activate", select = "inputs" },
		body = xml_payload,
		content_type = "application/xml",
		accept = "application/xml",
	}, function(resp, status)
		if status ~= 200 and status ~= 204 then
			notify("Fallo crítico en la comunicación con el servidor ADT.", vim.log.levels.ERROR)
			return
		end

		-- Parseo del XML de diagnóstico de SAP
		local qf_errors = {}
		for item in resp:gmatch("<chkrun:diagnosticMessage(.-)</chkrun:diagnosticMessage>") do
			local severity = item:match('severity="([^"]+)"')
			local text = item:match("<chkrun:text>([^<]+)</chkrun:text>")
			local line = tonumber(item:match('line="([^"]+)"')) or 1
			local offset = tonumber(item:match('offset="([^"]+)"')) or 0

			if text then
				table.insert(qf_errors, {
					bufnr = bufnr,
					lnum = line,
					col = offset + 1,
					text = "[" .. (severity or "ERROR") .. "] " .. text,
					type = (severity == "error") and "E" or "W",
				})
			end
		end

		-- Sincronización con Neovim UI
		vim.schedule(function()
			if #qf_errors > 0 then
				-- Mandamos los errores de compilación al panel inferior Quickfix de Neovim
				vim.fn.setqflist(qf_errors, "r")
				vim.cmd("copen") -- Abre la ventana de errores automáticamente
				notify(
					string.format("Activación completada con %d advertencias/errores de sintaxis.", #qf_errors),
					vim.log.levels.WARN
				)
			else
				vim.fn.setqflist({}, "r")
				pcall(vim.cmd, "cclose")
				notify(
					"¡Objeto ABAP activado con éxito en el servidor! (Versión activa actualizada)",
					vim.log.levels.INFO
				)
			end
		end)
	end)
end

return M
