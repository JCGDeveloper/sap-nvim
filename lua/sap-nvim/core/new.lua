-- sap-nvim.core.new  (F13)
-- Crea objetos ABAP EN EL SISTEMA con `sapcli <group> create NAME DESC PKG [--corrnr]`
-- y los abre para editar con source.open (SAP genera el esqueleto). Reemplaza el viejo
-- comportamiento de escribir una plantilla local que nunca llegaba a SAP.

local M = {}

local function notify(msg, level)
	vim.notify("[sap-nvim] " .. msg, level or vim.log.levels.INFO)
end

local function productive()
	local ok, cfg = pcall(function()
		return require("sap-nvim.core.config").productive()
	end)
	return ok and cfg or {}
end

local function safe_mode()
	return productive().safe_mode ~= false
end

local function is_customer_namespace(name)
	name = (name or ""):upper()
	return name:match("^[ZY]") ~= nil or name:match("^/[^/]+/") ~= nil
end

local function xml_escape(s)
	return tostring(s or "")
		:gsub("&", "&amp;")
		:gsub("<", "&lt;")
		:gsub(">", "&gt;")
		:gsub('"', "&quot;")
		:gsub("'", "&apos;")
end

local function xml_text(s)
	s = tostring(s or "")
	s = s:gsub("<[^>]+>", " ")
	s = s:gsub("&quot;", '"')
	s = s:gsub("&apos;", "'")
	s = s:gsub("&lt;", "<")
	s = s:gsub("&gt;", ">")
	s = s:gsub("&amp;", "&")
	return vim.trim((s:gsub("%s+", " ")))
end

local function adt_error_message(body, code)
	local msg = body
		and (
			body:match("<shortText>%s*<txt[^>]*>(.-)</txt>%s*</shortText>")
			or body:match("<longText>%s*<txt[^>]*>(.-)</txt>%s*</longText>")
			or body:match("<message[^>]*>(.-)</message>")
			or body:match("<title[^>]*>(.-)</title>")
		)
	msg = xml_text(msg or "")
	if msg ~= "" then
		return msg
	end
	return "HTTP " .. tostring(code or 0)
end

-- Tipos creables. group = primer positional de sapcli. needs_group: el function module
-- vive dentro de un grupo de funciones (firma `create GROUP NAME DESC`, sin paquete).
local TYPES = {
	{ key = "program", label = "Programa (REPORT)", group = "program" },
	{ key = "class", label = "Clase", group = "class" },
	{ key = "interface", label = "Interface", group = "interface" },
	{ key = "function_group", label = "Function Group", group = "functiongroup" },
	{ key = "function_module", label = "Function Module", group = "functionmodule", needs_group = true },
	{ key = "table", label = "Tabla (DDIC)", group = "table" },
	{ key = "structure", label = "Estructura", group = "structure" },
	{ key = "data_element", label = "Data Element", group = "dataelement" },
	{ key = "domain", label = "Dominio", group = "domain" },
	{ key = "cds_view", label = "CDS View (DDL)", group = "ddl", open_group = "ddls" },
	{ key = "transaction", label = "Transacción", group = "transaction" },
	{ key = "message_class", label = "Message Class", group = "messageclass" },
	{ key = "package", label = "Paquete (DEVC)", group = "package" },
}

-- ─── Lanzar la creación en SAP y abrir ──────────────────────────────────────

local function cds_seed_source(name, desc)
	return table.concat({
		"@EndUserText.label: '" .. (desc or name):gsub("'", "''") .. "'",
		"@AccessControl.authorizationCheck: #NOT_REQUIRED",
		"define view entity " .. name,
		"  as select from t000",
		"{",
		"  key mandt as Client",
		"}",
	}, "\n")
end

local function seed_cds_source(name, desc, corrnr, callback)
	local ok_adt, adt_http = pcall(require, "sap-nvim.core.adt_http")
	local c = ok_adt and adt_http.creds and adt_http.creds() or nil
	if c then
		vim.env.SAP_USER = c.user
		vim.env.SAP_PASSWORD = c.pass
	end

	local args = { "sapcli", "ddl", "write", name, "-" }
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end
	local source = cds_seed_source(name, desc)
	local out = {}
	local job = vim.fn.jobstart(args, {
		on_stdout = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					out[#out + 1] = vim.trim(l)
				end
			end
		end,
		on_stderr = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					out[#out + 1] = vim.trim(l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if code ~= 0 then
					notify(
						"CDS creada, pero no pude escribir la plantilla inicial: "
							.. (out[1] or ("sapcli code " .. code)),
						vim.log.levels.ERROR
					)
				end
				callback(code == 0)
			end)
		end,
	})
	if job and job > 0 then
		vim.fn.chansend(job, source)
		vim.fn.chanclose(job, "stdin")
	else
		notify("CDS creada, pero no pude lanzar sapcli ddl write.", vim.log.levels.ERROR)
		callback(false)
	end
end

local function create_cds_adt(name, desc, pkg, corrnr)
	local adt_http = require("sap-nvim.core.adt_http")
	local connection = require("sap-nvim.core.connection")
	if not adt_http.ready() then
		connection.ensure(function(ok)
			if ok then
				create_cds_adt(name, desc, pkg, corrnr)
			else
				notify("Conexión SAP no lista. Usa :SapLogin o :SapRelogin.", vim.log.levels.ERROR)
			end
		end)
		return
	end

	local cfg = require("sap-nvim.core.config").new()
	local c = adt_http.creds()
	local lang = ((cfg.language or vim.g.sap_nvim_language or "ES") .. ""):upper()
	local body = table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<ddl:ddlSource xmlns:ddl="http://www.sap.com/adt/ddic/ddlsources" xmlns:adtcore="http://www.sap.com/adt/core"',
		' adtcore:type="DDLS/DF"',
		' adtcore:description="' .. xml_escape(desc) .. '"',
		' adtcore:language="' .. xml_escape(lang) .. '"',
		' adtcore:name="' .. xml_escape(name) .. '"',
		' adtcore:masterLanguage="' .. xml_escape(lang) .. '"',
		' adtcore:responsible="' .. xml_escape(c.user:upper()) .. '">',
		'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>',
		"</ddl:ddlSource>",
	}, "\n")

	local query = {}
	if corrnr and corrnr ~= "" then
		query.corrNr = corrnr
	end

	notify("Creando CDS " .. name .. " en " .. pkg .. " por ADT (" .. lang .. ")...")
	local resp, _, code = adt_http.raw({
		method = "POST",
		path = "/sap/bc/adt/ddic/ddl/sources",
		query = query,
		body = body,
		content_type = "application/vnd.sap.adt.ddlSource+xml; charset=utf-8",
		accept = "application/vnd.sap.adt.ddlSource+xml, application/xml, text/xml",
	})
	if code < 200 or code >= 300 then
		notify("No se pudo crear " .. name .. ": " .. adt_error_message(resp, code), vim.log.levels.ERROR)
		return
	end

	notify(name .. " creado. Escribiendo plantilla CDS inicial...")
	seed_cds_source(name, desc, corrnr, function()
		require("sap-nvim.core.source").open(name, "ddls")
	end)
end

-- ─── Creación por ADT directo (evita el idioma EN hardcodeado de sapcli) ────────
-- sapcli fija `language='EN'`/`master_language='EN'` al crear (ver sap/cli/*.py): en
-- sistemas con idioma original ES eso hace FALLAR la creación. CDS ya se migró por esto;
-- aquí extendemos el mismo enfoque a programas, clases, interfaces, function groups y
-- paquetes. El idioma sale SIEMPRE de config (default "ES"), nunca hardcodeado.

-- Construye el XML de creación ADT con la cabecera adtcore común (type/description/
-- language/name/masterLanguage/responsible), idéntica a la que serializa sapcli pero con
-- el idioma de config. `root` = elemento raíz con prefijo (p.ej. "class:abapClass"),
-- `ns` = su declaración xmlns, `objtype` = código adtcore (p.ej. "CLAS/OC"), `root_extra`
-- = atributos extra del raíz, `children` = nodos hijos ya serializados (incluye packageRef).
local function adt_create_body(root, ns, objtype, root_extra, desc, lang, name, user, children)
	return table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		"<"
			.. root
			.. " "
			.. ns
			.. ' xmlns:adtcore="http://www.sap.com/adt/core"'
			.. ' adtcore:type="'
			.. objtype
			.. '"'
			.. ' adtcore:description="'
			.. xml_escape(desc)
			.. '"'
			.. ' adtcore:language="'
			.. xml_escape(lang)
			.. '"'
			.. ' adtcore:name="'
			.. xml_escape(name)
			.. '"'
			.. ' adtcore:masterLanguage="'
			.. xml_escape(lang)
			.. '"'
			.. ' adtcore:responsible="'
			.. xml_escape(user)
			.. '"'
			.. (root_extra or "")
			.. ">",
		children,
		"</" .. root .. ">",
	}, "\n")
end

-- Tabla de creación ADT por tipo (key = spec.key). path = basepath del POST,
-- content_type = MIME de creación (versión v2 = la más compatible), build = constructor
-- del XML. Endpoints y XML calcados de sapcli (sap/adt/{programs,objects,function}.py).
local ADT_CREATE = {
	program = {
		path = "/sap/bc/adt/programs/programs",
		content_type = "application/vnd.sap.adt.programs.programs.v2+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg)
			return adt_create_body(
				"program:abapProgram",
				'xmlns:program="http://www.sap.com/adt/programs/programs"',
				"PROG/P",
				' adtcore:version="active"',
				desc,
				lang,
				name,
				user,
				table.concat({
					'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>',
					"<program:logicalDatabase>",
					"<program:ref/>",
					"</program:logicalDatabase>",
				}, "\n")
			)
		end,
	},
	class = {
		path = "/sap/bc/adt/oo/classes",
		content_type = "application/vnd.sap.adt.oo.classes.v2+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg)
			return adt_create_body(
				"class:abapClass",
				'xmlns:class="http://www.sap.com/adt/oo/classes"',
				"CLAS/OC",
				' class:final="true" class:visibility="public"',
				desc,
				lang,
				name,
				user,
				table.concat({
					'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>',
					'<class:include adtcore:name="CLAS/OC" adtcore:type="CLAS/OC" class:includeType="testclasses"/>',
					"<class:superClassRef/>",
				}, "\n")
			)
		end,
	},
	interface = {
		path = "/sap/bc/adt/oo/interfaces",
		content_type = "application/vnd.sap.adt.oo.interfaces.v2+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg)
			return adt_create_body(
				"intf:abapInterface",
				'xmlns:intf="http://www.sap.com/adt/oo/interfaces"',
				"INTF/OI",
				"",
				desc,
				lang,
				name,
				user,
				'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>'
			)
		end,
	},
	function_group = {
		path = "/sap/bc/adt/functions/groups",
		content_type = "application/vnd.sap.adt.functions.groups.v2+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg)
			return adt_create_body(
				"group:abapFunctionGroup",
				'xmlns:group="http://www.sap.com/adt/functions/groups"',
				"FUGR/F",
				"",
				desc,
				lang,
				name,
				user,
				'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>'
			)
		end,
	},
}

-- Abre/siembra el objeto recién creado (igual para la ruta ADT y la sapcli). CDS lleva su
-- plantilla inicial (seed); el resto se abre directamente con source.open.
local function open_after_create(spec, name, desc, corrnr)
	if spec.open_group == "ddls" then
		notify(name .. " creado. Escribiendo plantilla CDS inicial...")
		seed_cds_source(name, desc, corrnr, function()
			require("sap-nvim.core.source").open(name, spec.open_group)
		end)
	else
		notify(name .. " creado. Abriendo para editar...")
		require("sap-nvim.core.source").open(name, spec.open_group or spec.group)
	end
end

-- Crea un objeto (programa/clase/interface/function group) por ADT directo y lo abre.
-- Mismo patrón que create_cds_adt: exige conexión validada (ready) o la pide; POST con
-- CSRF/cookies vía adt_http.raw; el idioma viene de config.
local function create_object_adt(spec, name, desc, pkg, corrnr)
	local adt_http = require("sap-nvim.core.adt_http")
	local connection = require("sap-nvim.core.connection")
	if not adt_http.ready() then
		connection.ensure(function(ok)
			if ok then
				create_object_adt(spec, name, desc, pkg, corrnr)
			else
				notify("Conexión SAP no lista. Usa :SapLogin o :SapRelogin.", vim.log.levels.ERROR)
			end
		end)
		return
	end

	local meta = ADT_CREATE[spec.key]
	local cfg = require("sap-nvim.core.config").new()
	local c = adt_http.creds()
	local lang = ((cfg.language or vim.g.sap_nvim_language or "ES") .. ""):upper()
	local body = meta.build(name, desc, lang, c.user:upper(), pkg)

	local query = {}
	if corrnr and corrnr ~= "" then
		query.corrNr = corrnr
	end

	notify("Creando " .. spec.label .. " " .. name .. " en " .. pkg .. " por ADT (" .. lang .. ")...")
	local resp, _, code = adt_http.raw({
		method = "POST",
		path = meta.path,
		query = query,
		body = body,
		content_type = meta.content_type,
		accept = "application/*",
	})
	if code < 200 or code >= 300 then
		notify("No se pudo crear " .. name .. ": " .. adt_error_message(resp, code), vim.log.levels.ERROR)
		return
	end

	open_after_create(spec, name, desc, corrnr)
end

local function do_create(spec, name, desc, pkg, corrnr, fgroup)
	-- Tipos con creación por ADT directo (programa/clase/interface/function group): evitan el
	-- idioma EN hardcodeado de sapcli. Los module functions (needs_group) y DDIC (tabla,
	-- estructura, data element, dominio, message class) NO tienen endpoint ADT de creación
	-- fiable aquí, así que siguen por sapcli.
	if not spec.needs_group and ADT_CREATE[spec.key] then
		create_object_adt(spec, name, desc, pkg, corrnr)
		return
	end

	local args = { "sapcli", spec.group, "create" }
	if spec.needs_group then
		vim.list_extend(args, { fgroup, name, desc }) -- functionmodule: GROUP NAME DESC
	else
		vim.list_extend(args, { name, desc, pkg }) -- resto: NAME DESC PACKAGE
	end
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end

	notify("Creando " .. spec.label .. " " .. name .. " en " .. (spec.needs_group and fgroup or pkg) .. "...")
	local err = {}
	vim.fn.jobstart(args, {
		on_stderr = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					err[#err + 1] = vim.trim(l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if code ~= 0 then
					notify("No se pudo crear " .. name .. ": " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR)
					return
				end
				open_after_create(spec, name, desc, corrnr)
			end)
		end,
	})
end

-- ─── Creadores específicos: transacción y paquete ──────────────────────────
-- Estos objetos tienen firmas sapcli propias y NO son código editable, así que
-- no llaman a source.open (a diferencia del do_create genérico).

-- Crea una transacción (firma: transaction create NAME DESC PKG -t TYPE [--report-name PROG] [--corrnr T]).
local function create_transaction(name, desc, pkg, corrnr, ttype, prog)
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not name:match("^[ZY]") and not name:match("^/") then
		notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
	end
	local args = { "sapcli", "transaction", "create", name, desc, pkg, "-t", ttype }
	if prog and prog ~= "" then
		vim.list_extend(args, { "--report-name", prog })
	end
	-- sapcli EXIGE el nº de pantalla para report (y dialog): por defecto 1000.
	if ttype == "report" then
		vim.list_extend(args, { "--report-dynnr", vim.g.sap_report_dynnr or "1000" })
	elseif ttype == "dialog" then
		vim.list_extend(args, { "--program-dynnr", vim.g.sap_report_dynnr or "1000" })
	end
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end

	notify("Creando transacción " .. name .. " en " .. pkg .. "...")
	local out, err = {}, {}
	vim.fn.jobstart(args, {
		on_stdout = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					out[#out + 1] = vim.trim(l)
				end
			end
		end,
		on_stderr = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					err[#err + 1] = vim.trim(l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if code ~= 0 then
					local msg = (#err > 0 and table.concat(err, " | "))
						or (#out > 0 and table.concat(out, " | "))
						or ("code " .. code)
					notify(
						"No se pudo crear " .. name .. " (-t " .. tostring(ttype) .. "): " .. msg,
						vim.log.levels.ERROR
					)
					-- Si el sistema NO tiene el endpoint ADT de creación de transacciones (IAM/blue,
					-- /sap/bc/adt/aps/iam/tran), ofrecemos crearla en SE93 por SAP GUI (vía nativa).
					if msg:find("aps/iam/tran", 1, true) or msg:lower():find("resourcenotfound", 1, true) then
						vim.ui.select({ "Sí, abrir SE93 en SAP GUI", "No" }, {
							prompt = "Tu sistema no permite crear transacciones por ADT. ¿Crearla en SE93 (SAP GUI)?",
						}, function(ch)
							if ch and ch:match("^Sí") then
								require("sap-nvim.core.sapgui").transaction("SE93")
							end
						end)
					end
					return
				end
				notify(name .. " (transacción) creada.")
			end)
		end,
	})
end

-- Tras crear un paquete: no es código (no source.open). Ofrecemos explorarlo.
local function package_explore_prompt(name)
	notify(name .. " (paquete) creado.")
	vim.ui.select({ "Sí, explorar " .. name, "No" }, { prompt = "¿Explorar el paquete?" }, function(ch)
		if ch and ch:match("^Sí") then
			pcall(function()
				require("sap-nvim.core.browser").browse_package(name)
			end)
		end
	end)
end

-- Crea un paquete por sapcli (firma: package create NAME DESC [--super-package SUPER]
-- [--corrnr T]). FALLBACK: solo se usa si ADT no pudo crearlo (ver create_package_adt).
-- OJO: sapcli fija el idioma a EN (sap/cli/package.py); por eso preferimos ADT.
local function create_package(name, desc, super, corrnr)
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not name:match("^[ZY]") and not name:match("^/") then
		notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
	end
	local args = { "sapcli", "package", "create", name, desc }
	if super and super ~= "" then
		vim.list_extend(args, { "--super-package", super:upper() })
	end
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end

	notify("Creando paquete " .. name .. "...")
	local err = {}
	vim.fn.jobstart(args, {
		on_stderr = function(_, data)
			for _, l in ipairs(data) do
				if vim.trim(l) ~= "" then
					err[#err + 1] = vim.trim(l)
				end
			end
		end,
		on_exit = function(_, code)
			vim.schedule(function()
				if code ~= 0 then
					notify("No se pudo crear " .. name .. ": " .. (err[1] or ("code " .. code)), vim.log.levels.ERROR)
					return
				end
				package_explore_prompt(name)
			end)
		end,
	})
end

-- Crea un paquete por ADT directo (endpoint /sap/bc/adt/packages). El XML es calcado del
-- que serializa sapcli (sap/adt/package.py) pero con el idioma de config en vez de EN. Si
-- ADT falla (p.ej. el sistema no expone el endpoint o rechaza el XML), CAE a sapcli como
-- fallback explícito. softwareComponent=LOCAL y packageType=development = mismos defaults
-- que `sapcli package create`, para no cambiar el comportamiento más allá del idioma.
-- NOTA: el XML de paquete es el de mayor riesgo de validar en vivo (mejor esfuerzo); el
-- fallback a sapcli garantiza que la creación siga funcionando si SAP rechaza el payload.
local function create_package_adt(name, desc, super, corrnr)
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not name:match("^[ZY]") and not name:match("^/") then
		notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
	end

	local adt_http = require("sap-nvim.core.adt_http")
	local connection = require("sap-nvim.core.connection")
	if not adt_http.ready() then
		connection.ensure(function(ok)
			if ok then
				create_package_adt(name, desc, super, corrnr)
			else
				notify("Conexión SAP no lista. Usa :SapLogin o :SapRelogin.", vim.log.levels.ERROR)
			end
		end)
		return
	end

	local cfg = require("sap-nvim.core.config").new()
	local c = adt_http.creds()
	local lang = ((cfg.language or vim.g.sap_nvim_language or "ES") .. ""):upper()
	local superref = (super and super ~= "")
			and ('<pak:superPackage adtcore:name="' .. xml_escape(super:upper()) .. '"/>')
		or "<pak:superPackage/>"
	local body = adt_create_body(
		"pak:package",
		'xmlns:pak="http://www.sap.com/adt/packages"',
		"DEVC/K",
		' adtcore:version="active"',
		desc,
		lang,
		name,
		c.user:upper(),
		table.concat({
			'<adtcore:packageRef adtcore:name="' .. xml_escape(name) .. '"/>',
			'<pak:attributes pak:packageType="development"/>',
			superref,
			"<pak:applicationComponent/>",
			"<pak:transport>",
			'<pak:softwareComponent pak:name="LOCAL"/>',
			"<pak:transportLayer/>",
			"</pak:transport>",
			"<pak:translation/>",
			"<pak:useAccesses/>",
			"<pak:packageInterfaces/>",
			"<pak:subPackages/>",
		}, "\n")
	)

	local query = {}
	if corrnr and corrnr ~= "" then
		query.corrNr = corrnr
	end

	notify("Creando paquete " .. name .. " por ADT (" .. lang .. ")...")
	local resp, _, code = adt_http.raw({
		method = "POST",
		path = "/sap/bc/adt/packages",
		query = query,
		body = body,
		content_type = "application/vnd.sap.adt.packages.v1+xml; charset=utf-8",
		accept = "application/*",
	})
	if code < 200 or code >= 300 then
		notify(
			"ADT no pudo crear el paquete (" .. adt_error_message(resp, code) .. "). Reintentando con sapcli...",
			vim.log.levels.WARN
		)
		create_package(name, desc, super, corrnr) -- fallback sapcli (idioma EN)
		return
	end
	package_explore_prompt(name)
end

-- ─── Pickers de paquete y transporte (desde el sistema) ─────────────────────

local function extract_transport_id(line)
	return line:match("%u%u%uK%d+") or line:match("%u%u%u%uK%d+") or line:match("^(%S+)")
end

-- Búsqueda SÍNCRONA de paquetes (informationsystem/search, objectType=DEVC), igual que
-- VSCode, para autocompletar el paquete AL TECLEAR (Tab) en el prompt. Sync porque la
-- completion de vim.fn.input ha de devolver la lista en el acto.
local function package_search_sync(prefix)
	local adt_http = require("sap-nvim.core.adt_http")
	if not adt_http.is_available() then
		return {}
	end
	prefix = (prefix or ""):upper()
	local q = (prefix == "" and "*" or prefix .. "*")
	local ok, body = pcall(adt_http.request, {
		method = "GET",
		path = "/sap/bc/adt/repository/informationsystem/search",
		query = { operation = "quickSearch", query = q, maxResults = 50, objectType = "DEVC" },
		accept = "application/*",
	})
	if not ok or not body then
		return {}
	end
	local names, seen = {}, {}
	for nm in body:gmatch('adtcore:name="([^"]*)"') do
		nm = (nm:match("^(%S+)") or nm):upper() -- a veces "ZPKG (PACKAGE)"
		if nm ~= "" and not seen[nm] then
			seen[nm] = true
			names[#names + 1] = nm
		end
	end
	table.sort(names)
	return names
end

-- Expuesta para la completion de vim.fn.input (la llama SapNvimPkgComplete).
function M.package_complete(arglead)
	return package_search_sync(arglead or "")
end

-- Picker EN VIVO (snacks): según escribes, busca paquetes en el sistema (estilo VSCode).
-- Devuelve true si lo abrió; false si no hay snacks (para caer al input con Tab).
local function pick_package_live(default, cb)
	local ok, Snacks = pcall(require, "snacks")
	if not (ok and Snacks.picker) then
		return false
	end
	return (
		pcall(Snacks.picker.pick, {
			source = "sap_packages",
			title = "Paquete SAP (escribe para buscar · $TMP = local)",
			live = true, -- re-busca en el servidor según escribes
			search = default or "Z",
			limit_live = 200,
			finder = function(_, fctx)
				local q = ((fctx.filter and fctx.filter.search) or ""):gsub("%s+", "")
				local items = { { text = "$TMP", package = "$TMP" } }
				for _, n in ipairs(package_search_sync(q)) do
					items[#items + 1] = { text = n, package = n }
				end
				return items
			end,
			format = "text",
			confirm = function(picker, item)
				picker:close()
				cb(item and item.package or "$TMP")
			end,
		})
	)
end

-- callback(pkg)  — "$TMP" para local. Picker en vivo si hay snacks; si no, input con Tab.
local function ask_package(callback)
	local adt = require("sap-nvim.core.adt")
	local cfg = require("sap-nvim.core.config").new()
	local default_pkg = cfg.package or cfg.package_prefix or "Z"
	if
		adt.is_configured()
		and pick_package_live(default_pkg, function(pkg)
			callback(((pkg and pkg ~= "") and pkg or "$TMP"):upper())
		end)
	then
		return
	end
	-- Fallback: input con autocompletado por Tab.
	local opts = { prompt = "Paquete (Tab=autocompletar · $TMP=local): ", default = default_pkg, cancelreturn = "\0" }
	if adt.is_configured() then
		opts.completion = "customlist,SapNvimPkgComplete"
	end
	local pkg = vim.fn.input(opts)
	if pkg == "\0" then
		return
	end
	pkg = vim.trim(pkg or "")
	callback(((pkg ~= "" and pkg) or "$TMP"):upper())
end

-- callback(transport_id)  — "" para ninguno. Solo se llama si pkg ~= "$TMP".
local function ask_transport(callback)
	local adt = require("sap-nvim.core.adt")
	if not adt.is_configured() then
		vim.ui.input({ prompt = "Orden de transporte (vacío = ninguna): " }, function(t)
			t = vim.trim(t or "")
			if safe_mode() and t == "" then
				notify("Modo productivo: se requiere transporte para paquete no local.", vim.log.levels.WARN)
				return
			end
			callback(t:upper())
		end)
		return
	end
	notify("Obteniendo órdenes de transporte...")
	adt.fetch_transport_orders(function(transports, err)
		vim.schedule(function()
			local items = {}
			if not safe_mode() then
				items[#items + 1] = "[ Sin transporte ]"
			end
			items[#items + 1] = "[ Ingresar manualmente ]"
			for _, t in ipairs(transports or {}) do
				items[#items + 1] = t
			end
			vim.ui.select(items, {
				prompt = "Orden de transporte:",
				format_item = function(i)
					return i
				end,
			}, function(choice)
				if not choice or choice == "[ Sin transporte ]" then
					callback("")
					return
				end
				if choice == "[ Ingresar manualmente ]" then
					vim.ui.input({ prompt = "Orden: " }, function(t)
						t = vim.trim(t or "")
						if safe_mode() and t == "" then
							notify("Modo productivo: se requiere transporte para paquete no local.", vim.log.levels.WARN)
							return
						end
						callback(t:upper())
					end)
					return
				end
				callback((extract_transport_id(choice) or ""):upper())
			end)
		end)
	end)
end

-- ─── Flujo principal ────────────────────────────────────────────────────────

function M.new_object()
	if not require("sap-nvim.core.adt").is_configured() then
		notify("No hay conexión SAP. Usa :SapSetup primero.", vim.log.levels.WARN)
		return
	end

	local cfg = require("sap-nvim.core.config").new()

	vim.ui.select(TYPES, {
		prompt = "Nuevo objeto ABAP en SAP:",
		format_item = function(it)
			return it.label
		end,
	}, function(spec)
		if not spec then
			return
		end

		vim.ui.input({ prompt = spec.label .. " — nombre: ", default = cfg.name_prefix or "Z" }, function(name)
			if not name or name == "" then
				return
			end
			name = name:upper()
			if not is_customer_namespace(name) then
				if safe_mode() then
					notify("Modo productivo: no se crea '" .. name .. "' fuera de namespace Z/Y o /.../.", vim.log.levels.ERROR)
					return
				end
				notify("Aviso: '" .. name .. "' no empieza por Z/Y; SAP puede rechazarlo.", vim.log.levels.WARN)
			end

			vim.ui.input({ prompt = "Descripción: ", default = name }, function(desc)
				desc = (desc and desc ~= "") and desc or name

				-- Function module: pide el grupo de funciones, sin paquete/transporte propio.
				if spec.needs_group then
					vim.ui.input(
						{ prompt = "Function Group destino: ", default = cfg.function_group or "Z" },
						function(fg)
							if not fg or fg == "" then
								return
							end
							do_create(spec, name, desc, nil, nil, fg:upper())
						end
					)
					return
				end

				-- Transacción: tras el paquete y el transporte, pide el TIPO (y el programa
				-- si es de tipo report). Firma propia de sapcli (-t obligatorio).
				if spec.group == "transaction" then
					ask_package(function(pkg)
						local function pick_type(corrnr)
							vim.ui.select(
								{ "report", "parameter", "dialog", "oo", "variant" },
								{ prompt = "Tipo de transacción:" },
								function(ttype)
									ttype = ttype or "report"
									if ttype == "report" then
										vim.ui.input(
											{ prompt = "Programa (report) de la transacción: ", default = "" },
											function(prog)
												create_transaction(name, desc, pkg, corrnr, ttype, prog)
											end
										)
									else
										create_transaction(name, desc, pkg, corrnr, ttype, nil)
									end
								end
							)
						end
						if pkg == "$TMP" then
							pick_type("")
						else
							ask_transport(function(corrnr)
								pick_type(corrnr)
							end)
						end
					end)
					return
				end

				-- Paquete: no se crea DENTRO de otro paquete por este flujo. Pregunta un
				-- super-paquete opcional y el transporte, y llama a create_package.
				if spec.group == "package" then
					vim.ui.input({ prompt = "Super-paquete (vacío = ninguno): ", default = "" }, function(super)
						ask_transport(function(corrnr)
							create_package_adt(name, desc, super, corrnr)
						end)
					end)
					return
				end

				ask_package(function(pkg)
					local function create_with(corrnr)
						if spec.open_group == "ddls" then
							create_cds_adt(name, desc, pkg, corrnr)
						else
							do_create(spec, name, desc, pkg, corrnr)
						end
					end
					if pkg == "$TMP" then
						create_with("")
					else
						ask_transport(function(corrnr)
							create_with(corrnr)
						end)
					end
				end)
			end)
		end)
	end)
end

function M.setup()
	vim.api.nvim_create_user_command("SapNew", function()
		M.new_object()
	end, { desc = "sap-nvim: Crear objeto ABAP en el sistema y abrirlo" })
	vim.keymap.set("n", "<leader>an", function()
		M.new_object()
	end, { desc = "ABAP: Nuevo objeto (crear en SAP)" })

	-- Función global para la completion (Tab) del prompt de paquete (vim.fn.input).
	vim.cmd([[
    function! SapNvimPkgComplete(A, L, P) abort
      return luaeval("require('sap-nvim.core.new').package_complete(_A)", a:A)
    endfunction
  ]])

	-- :SapDiscovery [filtro] — lista los endpoints ADT que SÍ existen en este sistema (para
	-- saber qué funciones de sapcli son compatibles). Ej.: :SapDiscovery iam
	vim.api.nvim_create_user_command("SapDiscovery", function(a)
		local adt_http = require("sap-nvim.core.adt_http")
		if not adt_http.is_available() then
			notify("ADT no disponible (config.yml).", vim.log.levels.WARN)
			return
		end
		notify("Consultando /sap/bc/adt/discovery ...")
		adt_http.request_async(
			{ method = "GET", path = "/sap/bc/adt/discovery", accept = "application/atomsvc+xml" },
			function(body)
				vim.schedule(function()
					local filter = (a.args ~= "" and a.args:lower()) or nil
					local seen, lines = {}, {}
					for href in (body or ""):gmatch('href="([^"]*)"') do
						if (not filter or href:lower():find(filter, 1, true)) and not seen[href] then
							seen[href] = true
							lines[#lines + 1] = href
						end
					end
					table.sort(lines)
					table.insert(
						lines,
						1,
						"== ADT discovery · "
							.. #lines
							.. " endpoints"
							.. (filter and (" · filtro: " .. filter) or "")
							.. " =="
					)
					if #lines == 1 then
						lines[#lines + 1] = "(sin coincidencias — prueba sin filtro)"
					end
					local buf = vim.api.nvim_create_buf(false, true)
					vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
					vim.bo[buf].bufhidden = "wipe"
					vim.cmd("botright split")
					vim.api.nvim_win_set_buf(0, buf)
				end)
			end
		)
	end, { nargs = "?", desc = "sap-nvim: lista los endpoints ADT del sistema (discovery)" })
end

return M
