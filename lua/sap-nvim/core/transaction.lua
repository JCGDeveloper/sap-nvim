-- Transacciones (TCODE): ver definición, dónde se usa y borrar (SE93).
--
-- Firmas sapcli:
--   sapcli transaction read NAME
--   sapcli transaction whereused NAME
--   sapcli transaction delete NAME [--corrnr T]

local M = {}
local source = require("sap-nvim.core.source")

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function remote_delete_allowed()
	local ok, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	return ok and cfg.allow_delete_objects == true
end

-- Muestra `lines` en un split de solo lectura con q/- para cerrar.
local function show(bufname, lines)
	local b = vim.api.nvim_create_buf(true, true)
	vim.api.nvim_buf_set_lines(b, 0, -1, false, lines)
	vim.bo[b].modifiable = false
	vim.bo[b].buftype = "nofile"
	pcall(vim.api.nvim_buf_set_name, b, bufname)
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, b)
	pcall(vim.api.nvim_win_set_height, 0, math.min(20, math.max(6, #lines + 1)))
	vim.keymap.set("n", "q", "<cmd>close<cr>", { buffer = b, nowait = true })
	vim.keymap.set("n", "-", "<cmd>close<cr>", { buffer = b, nowait = true })
end

-- Ejecuta sapcli async, acumula stdout/stderr y al terminar invoca on_done(code, stdout, stderr).
local function run(args, on_done)
	local stdout, stderr = {}, {}
	vim.fn.jobstart(args, {
		on_stdout = function(_, data)
			for _, line in ipairs(data) do
				if line ~= "" then
					table.insert(stdout, line)
				end
			end
		end,
		on_stderr = function(_, data)
			for _, line in ipairs(data) do
				if vim.trim(line) ~= "" then
					table.insert(stderr, line)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				on_done(code, stdout, stderr)
			end)
		end,
	})
end

-- VER la definición de una transacción (SE93) con `transaction read`.
function M.view(name)
	if not name or name == "" then
		return
	end
	name = name:upper()
	notify("Leyendo transacción " .. name .. "...")
	run({ "sapcli", "transaction", "read", name }, function(code, stdout, stderr)
		if code ~= 0 or #stdout == 0 then
			local msg = #stderr > 0 and stderr[1] or ("No se pudo leer la transacción " .. name)
			notify(msg, vim.log.levels.ERROR)
			return
		end
		show("sap-tran://" .. name, stdout)
	end)
end

-- VER dónde se usa una transacción con `transaction whereused`.
function M.where_used(name)
	if not name or name == "" then
		return
	end
	name = name:upper()
	notify("Buscando usos de la transacción " .. name .. "...")
	run({ "sapcli", "transaction", "whereused", name }, function(code, stdout, stderr)
		if code ~= 0 or #stdout == 0 then
			local msg = #stderr > 0 and stderr[1] or ("Sin usos o no accesible para " .. name)
			notify(msg, vim.log.levels.WARN)
			return
		end
		show("sap-tran-usos://" .. name, stdout)
	end)
end

-- BORRAR una transacción (§7 destructivo): confirma y resuelve transporte.
function M.delete(name)
	if not remote_delete_allowed() then
		notify(
			"Borrado remoto desactivado por seguridad. Para habilitarlo: productive.allow_delete_objects = true.",
			vim.log.levels.WARN
		)
		return
	end
	if not name or name == "" then
		return
	end
	name = name:upper()
	vim.ui.select({ "Sí, borrar " .. name, "No" }, {
		prompt = "¿Borrar la transacción " .. name .. "?",
	}, function(choice)
		if not choice or not choice:match("^Sí") then
			return
		end

		source.resolve_transport(function(corrnr)
			local args = { "sapcli", "transaction", "delete", name }
			if corrnr then
				vim.list_extend(args, { "--corrnr", corrnr })
			end

			notify("Borrando transacción " .. name .. (corrnr and (" [" .. corrnr .. "]") or "") .. "...")
			run(args, function(code, _, stderr)
				if code == 0 then
					notify("Transacción borrada: " .. name)
				else
					local msg = #stderr > 0 and stderr[1] or ("Error borrando " .. name)
					notify(msg, vim.log.levels.ERROR)
				end
			end)
		end)
	end)
end

-- Resuelve el nombre de la transacción: argumento -> <cword> (si parece TCODE) -> input.
local function resolve_name(arg, cb)
	if arg and arg ~= "" then
		cb(arg)
		return
	end
	local w = vim.fn.expand("<cword>")
	if w and #w >= 3 and w:match("^[%w_/]+$") then
		cb(w)
		return
	end
	vim.ui.input({ prompt = "Transacción (TCODE): " }, function(v)
		if v and v ~= "" then
			cb(v)
		end
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("SapTransactionView", function(a)
		resolve_name(a.args, M.view)
	end, { desc = "sap-nvim: Ver definición de una transacción (SE93)", nargs = "?" })

	vim.api.nvim_create_user_command("SapTransactionWhereUsed", function(a)
		resolve_name(a.args, M.where_used)
	end, { desc = "sap-nvim: Dónde se usa una transacción", nargs = "?" })

	vim.api.nvim_create_user_command("SapTransactionDelete", function(a)
		resolve_name(a.args, M.delete)
	end, { desc = "sap-nvim: Borrar una transacción (SE93)", nargs = "?" })
end

return M
