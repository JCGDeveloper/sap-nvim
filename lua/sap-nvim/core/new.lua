-- sap-nvim.core.new  (F13)
-- Crea objetos ABAP EN EL SISTEMA con `sapcli <group> create NAME DESC PKG [--corrnr]`
-- y los abre para editar con source.open (SAP genera el esqueleto). Reemplaza el viejo
-- comportamiento de escribir una plantilla local que nunca llegaba a SAP.

local M = {}
local sapcli = require("sap-nvim.core.sapcli")

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

local function creation_block_reason()
	local cfg = productive()
	if cfg.read_only == true or cfg.readonly == true then
		return "modo solo lectura activo"
	end
	if cfg.allow_create_objects == false then
		return "productive.allow_create_objects=false"
	end
	return nil
end

local function is_customer_namespace(name)
	name = (name or ""):upper()
	return name:match("^[ZY]") ~= nil or name:match("^/[A-Z0-9_]+/[A-Z0-9_]") ~= nil
end

local function normalize_name(name)
	return vim.trim(tostring(name or "")):upper()
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
	{ key = "include", label = "Include", group = "include" },
	{ key = "class", label = "Clase", group = "class" },
	{ key = "interface", label = "Interface", group = "interface" },
	{ key = "function_group", label = "Function Group", group = "functiongroup" },
	{ key = "function_module", label = "Function Module", group = "functionmodule", needs_group = true },
	{ key = "table", label = "Tabla (DDIC)", group = "table" },
	{ key = "structure", label = "Estructura", group = "structure" },
	{ key = "data_element", label = "Data Element", group = "dataelement" },
	{ key = "domain", label = "Dominio", group = "domain" },
	{ key = "table_type", label = "Table Type", group = "tabletype" },
	{ key = "search_help", label = "Search Help (DDIC)", group = "searchhelp", plan_only = true },
	{ key = "cds_view", label = "CDS View (DDL)", group = "ddl", open_group = "ddls" },
	{ key = "metadata_extension", label = "Metadata Extension (DDLX)", group = "ddlx" },
	{ key = "dcl", label = "Access Control (DCL)", group = "dcl" },
	{ key = "behavior_definition", label = "Behavior Definition (RAP)", group = "bdef" },
	{ key = "service_definition", label = "Service Definition (RAP)", group = "srvd" },
	{ key = "transaction", label = "Transacción", group = "transaction" },
	{ key = "report_variant", label = "Variante de report", group = "program_variant", needs_program = true },
	{ key = "message_class", label = "Message Class", group = "messageclass" },
	{ key = "number_range", label = "Number Range Object (SNRO)", group = "numberrange", plan_only = true },
	{ key = "package", label = "Paquete (DEVC)", group = "package" },
}

local NAME_RULES = {
	program = { max = 40 },
	include = { max = 40 },
	class = { max = 30 },
	interface = { max = 30 },
	function_group = { max = 26 },
	function_module = { max = 30 },
	table = { max = 30 },
	structure = { max = 30 },
	data_element = { max = 30 },
	domain = { max = 30 },
	table_type = { max = 30 },
	search_help = { max = 30 },
	cds_view = { max = 30 },
	metadata_extension = { max = 30 },
	dcl = { max = 30 },
	behavior_definition = { max = 30 },
	service_definition = { max = 30 },
	transaction = { max = 20 },
	report_variant = { max = 14, customer_required = false },
	message_class = { max = 20 },
	number_range = { max = 10 },
	package = { max = 30 },
}

local function validate_object_name(spec, name, opts)
	opts = opts or {}
	spec = spec or {}
	name = normalize_name(name)
	if name == "" then
		return false, "Nombre obligatorio."
	end
	local rule = NAME_RULES[spec.key] or { max = 30 }
	if #name > rule.max then
		return false, string.format("%s supera el máximo (%d caracteres).", name, rule.max)
	end
	if name:match("^/") then
		if not name:match("^/[A-Z0-9_]+/[A-Z0-9_][A-Z0-9_]*$") then
			return false, "Namespace inválido: usa /NAMESPACE/NOMBRE con letras, números o _."
		end
	elseif not name:match("^[A-Z][A-Z0-9_]*$") then
		return false, "Nombre inválido: usa letras, números o _; debe empezar por letra."
	end
	local customer_required = opts.customer_required
	if customer_required == nil then
		customer_required = rule.customer_required ~= false
	end
	if customer_required and safe_mode() and not is_customer_namespace(name) then
		return false, "Modo productivo: no se crea '" .. name .. "' fuera de namespace cliente Z/Y o /NAMESPACE/."
	end
	return true, nil
end

local SOURCE_GROUPS = {
	program = true,
	include = true,
	class = true,
	interface = true,
	ddl = true,
	ddls = true,
	ddlx = true,
	dcl = true,
	bdef = true,
	srvd = true,
}

local ADT_CREATE_PATHS = {
	program = "/sap/bc/adt/programs/programs",
	class = "/sap/bc/adt/oo/classes",
	interface = "/sap/bc/adt/oo/interfaces",
	function_group = "/sap/bc/adt/functions/groups",
	table = "/sap/bc/adt/ddic/tables",
	structure = "/sap/bc/adt/ddic/structures",
	data_element = "/sap/bc/adt/ddic/dataelements",
	domain = "/sap/bc/adt/ddic/domains",
	table_type = "/sap/bc/adt/ddic/tabletypes",
	search_help = "/sap/bc/adt/ddic/searchhelps",
	number_range = "/sap/bc/adt/numberranges/objects",
	cds_view = "/sap/bc/adt/ddic/ddl/sources",
	metadata_extension = "/sap/bc/adt/ddic/ddlx/sources",
	dcl = "/sap/bc/adt/acm/dcl/sources",
	behavior_definition = "/sap/bc/adt/bo/behaviordefinitions",
	service_definition = "/sap/bc/adt/ddic/srvd/sources",
	package = "/sap/bc/adt/packages",
}

local function valid_adt_create_path(path)
	if type(path) ~= "string" then
		return false
	end
	for _, p in pairs(ADT_CREATE_PATHS) do
		if path == p then
			return true
		end
	end
	return false
end

local function type_by_key(key)
	for _, spec in ipairs(TYPES) do
		if spec.key == key or spec.group == key then
			return spec
		end
	end
	return nil
end

-- ─── Lanzar la creación en SAP y abrir ──────────────────────────────────────

local function abap_quote(s)
	return tostring(s or ""):gsub("'", "''")
end

local function initial_source(spec, name, desc)
	local group = spec and (spec.open_group or spec.group) or nil
	name = (name or ""):upper()
	desc = desc or name
	if group == "program" then
		return table.concat({
			"REPORT " .. name .. ".",
			"",
			"* " .. desc,
			"",
			"START-OF-SELECTION.",
			"  WRITE: / '" .. abap_quote(desc) .. "'.",
		}, "\n")
	elseif group == "include" then
		return table.concat({
			"*----------------------------------------------------------------------*",
			"* Include " .. name,
			"* " .. desc,
			"*----------------------------------------------------------------------*",
			"",
		}, "\n")
	elseif group == "class" then
		return table.concat({
			"CLASS " .. name .. " DEFINITION",
			"  PUBLIC",
			"  FINAL",
			"  CREATE PUBLIC.",
			"",
			"  PUBLIC SECTION.",
			"  PROTECTED SECTION.",
			"  PRIVATE SECTION.",
			"ENDCLASS.",
			"",
			"CLASS " .. name .. " IMPLEMENTATION.",
			"ENDCLASS.",
		}, "\n")
	elseif group == "interface" then
		return table.concat({
			"INTERFACE " .. name .. " PUBLIC.",
			"ENDINTERFACE.",
		}, "\n")
	elseif group == "ddls" or group == "ddl" then
		return table.concat({
			"@EndUserText.label: '" .. abap_quote(desc) .. "'",
			"@AccessControl.authorizationCheck: #NOT_REQUIRED",
			"define view entity " .. name,
			"  as select from t000",
			"{",
			"  key mandt as Client",
			"}",
		}, "\n")
	elseif group == "ddlx" then
		return table.concat({
			"@Metadata.layer: #CUSTOMER",
			"annotate view " .. name .. " with",
			"{",
			"}",
		}, "\n")
	elseif group == "dcl" then
		return table.concat({
			"@EndUserText.label: '" .. abap_quote(desc) .. "'",
			"@MappingRole: true",
			"define role " .. name .. " {",
			"  grant select on ZI_ENTITY",
			"    where ( 1 ) = aspect pfcg_auth( Z_AUTH, FIELD, ACTVT = '03' );",
			"}",
		}, "\n")
	elseif group == "bdef" then
		return table.concat({
			"managed implementation in class ZBP_" .. name:gsub("^Z[CI]_?", "") .. " unique;",
			"strict ( 2 );",
			"",
			"define behavior for ZI_ENTITY alias Entity",
			"  persistent table ztable",
			"  lock master",
			"{",
			"  create;",
			"  update;",
			"  delete;",
			"}",
		}, "\n")
	elseif group == "srvd" then
		return table.concat({
			"@EndUserText.label: '" .. abap_quote(desc) .. "'",
			"define service " .. name .. " {",
			"  expose ZI_ENTITY as Entity;",
			"}",
		}, "\n")
	end
	return nil
end

local function build_write_args(spec, name, corrnr)
	local group = spec.open_group == "ddls" and "ddl" or spec.group
	local args = { "sapcli", group, "write", name, "-" }
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end
	return args
end

local function seed_source(spec, name, desc, corrnr, callback)
	if not SOURCE_GROUPS[spec.open_group or spec.group] then
		if callback then
			callback(false)
		end
		return
	end
	local source = initial_source(spec, name, desc)
	if not source or source == "" then
		if callback then
			callback(false)
		end
		return
	end
	local args = build_write_args(spec, name, corrnr)
	local out = {}
	local job = sapcli.jobstart(args, {
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
						name .. " creado, pero no pude escribir la plantilla inicial: "
							.. (out[1] or ("sapcli code " .. code)),
						vim.log.levels.WARN
					)
				end
				if callback then
					callback(code == 0)
				end
			end)
		end,
	})
	if job and job > 0 then
		vim.fn.chansend(job, source)
		vim.fn.chanclose(job, "stdin")
	else
		notify(name .. " creado, pero no pude lanzar sapcli write.", vim.log.levels.WARN)
		if callback then
			callback(false)
		end
	end
end

local function build_cds_adt_body(name, desc, lang, user, pkg)
	return table.concat({
		'<?xml version="1.0" encoding="UTF-8"?>',
		'<ddl:ddlSource xmlns:ddl="http://www.sap.com/adt/ddic/ddlsources" xmlns:adtcore="http://www.sap.com/adt/core"',
		' adtcore:type="DDLS/DF"',
		' adtcore:description="' .. xml_escape(desc) .. '"',
		' adtcore:language="' .. xml_escape(lang) .. '"',
		' adtcore:name="' .. xml_escape(name) .. '"',
		' adtcore:masterLanguage="' .. xml_escape(lang) .. '"',
		' adtcore:responsible="' .. xml_escape(user) .. '">',
		'<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>',
		"</ddl:ddlSource>",
	}, "\n")
end

local function create_cds_adt(name, desc, pkg, corrnr)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
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
	local body = build_cds_adt_body(name, desc, lang, c.user:upper(), pkg)

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
	seed_source(type_by_key("cds_view"), name, desc, corrnr, function()
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

local function package_ref(pkg)
	return '<adtcore:packageRef adtcore:name="' .. xml_escape(pkg) .. '"/>'
end

local function adt_source_body(root, ns, objtype, desc, lang, name, user, pkg)
	return adt_create_body(root, ns, objtype, "", desc, lang, name, user, package_ref(pkg))
end

local function ddic_create_body(root, ns, objtype, desc, lang, name, user, pkg, children)
	local nodes = { package_ref(pkg) }
	for _, child in ipairs(children or {}) do
		if child and child ~= "" then
			nodes[#nodes + 1] = child
		end
	end
	return adt_create_body(root, ns, objtype, ' adtcore:version="inactive"', desc, lang, name, user, table.concat(nodes, "\n"))
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
	cds_view = {
		path = "/sap/bc/adt/ddic/ddl/sources",
		content_type = "application/vnd.sap.adt.ddlSource+xml; charset=utf-8",
		build = build_cds_adt_body,
	},
	metadata_extension = {
		path = "/sap/bc/adt/ddic/ddlx/sources",
		content_type = "application/vnd.sap.adt.ddlxSource+xml; charset=utf-8",
		fallback_sapcli = true,
		build = function(name, desc, lang, user, pkg)
			return adt_source_body(
				"ddlx:ddlxSource",
				'xmlns:ddlx="http://www.sap.com/adt/ddic/ddlx/sources"',
				"DDLX/EX",
				desc,
				lang,
				name,
				user,
				pkg
			)
		end,
	},
	dcl = {
		path = "/sap/bc/adt/acm/dcl/sources",
		content_type = "application/vnd.sap.adt.acm.dcl.source+xml; charset=utf-8",
		fallback_sapcli = true,
		build = function(name, desc, lang, user, pkg)
			return adt_source_body(
				"dcl:dclSource",
				'xmlns:dcl="http://www.sap.com/adt/acm/dcl"',
				"DCLS/DL",
				desc,
				lang,
				name,
				user,
				pkg
			)
		end,
	},
	behavior_definition = {
		path = "/sap/bc/adt/bo/behaviordefinitions",
		content_type = "application/vnd.sap.adt.behaviordefinitions.v1+xml; charset=utf-8",
		fallback_sapcli = true,
		build = function(name, desc, lang, user, pkg)
			return adt_source_body(
				"bdef:behaviorDefinition",
				'xmlns:bdef="http://www.sap.com/adt/bo/behaviordefinitions"',
				"BDEF/BDO",
				desc,
				lang,
				name,
				user,
				pkg
			)
		end,
	},
	service_definition = {
		path = "/sap/bc/adt/ddic/srvd/sources",
		content_type = "application/vnd.sap.adt.srvd.source.v1+xml; charset=utf-8",
		fallback_sapcli = true,
		build = function(name, desc, lang, user, pkg)
			return adt_source_body(
				"srvd:serviceDefinition",
				'xmlns:srvd="http://www.sap.com/adt/ddic/srvd"',
				"SRVD/SRV",
				desc,
				lang,
				name,
				user,
				pkg
			)
		end,
	},
}

-- Builders DDIC puros para validación viva. No se usan como camino por defecto todavía:
-- sapcli sigue siendo la vía probada para crear DDIC, y estos payloads permiten comparar
-- rutas/XML contra un sistema real sin hacer POST accidental.
local DDIC_CREATE = {
	domain = {
		path = "/sap/bc/adt/ddic/domains",
		content_type = "application/vnd.sap.adt.ddic.domains.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local datatype = (opts.datatype or "CHAR"):upper()
			local length = tostring(opts.length or 10)
			return ddic_create_body(
				"ddic:domain",
				'xmlns:ddic="http://www.sap.com/adt/ddic/domains"',
				"DOMA/DO",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:technicalSettings ddic:dataType="' .. xml_escape(datatype) .. '" ddic:length="' .. xml_escape(length) .. '"/>',
				}
			)
		end,
	},
	data_element = {
		path = "/sap/bc/adt/ddic/dataelements",
		content_type = "application/vnd.sap.adt.ddic.dataelements.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local domain = (opts.domain or opts.reference or "ZDUMMY_CHAR10"):upper()
			return ddic_create_body(
				"ddic:dataElement",
				'xmlns:ddic="http://www.sap.com/adt/ddic/dataelements"',
				"DTEL/DE",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:domainRef adtcore:name="' .. xml_escape(domain) .. '"/>',
					'<ddic:fieldLabels ddic:short="' .. xml_escape(desc) .. '" ddic:medium="' .. xml_escape(desc) .. '" ddic:long="' .. xml_escape(desc) .. '"/>',
				}
			)
		end,
	},
	table_type = {
		path = "/sap/bc/adt/ddic/tabletypes",
		content_type = "application/vnd.sap.adt.ddic.tabletypes.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local rowtype = (opts.rowtype or opts.line_type or "SFLIGHT"):upper()
			return ddic_create_body(
				"ddic:tableType",
				'xmlns:ddic="http://www.sap.com/adt/ddic/tabletypes"',
				"TTYP/TT",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:rowTypeRef adtcore:name="' .. xml_escape(rowtype) .. '"/>',
					'<ddic:accessMode ddic:kind="standard"/>',
				}
			)
		end,
	},
	search_help = {
		path = "/sap/bc/adt/ddic/searchhelps",
		content_type = "application/vnd.sap.adt.ddic.searchhelps.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local selection_method = (opts.selection_method or opts.table or "T000"):upper()
			local parameter = (opts.parameter or "MANDT"):upper()
			local element = (opts.element or "MANDT"):upper()
			return ddic_create_body(
				"ddic:searchHelp",
				'xmlns:ddic="http://www.sap.com/adt/ddic/searchhelps"',
				"SHLP/SH",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:selectionMethod adtcore:name="' .. xml_escape(selection_method) .. '"/>',
					'<ddic:parameters><ddic:parameter ddic:name="'
						.. xml_escape(parameter)
						.. '" ddic:import="true" ddic:export="true"><ddic:typeRef adtcore:name="'
						.. xml_escape(element)
						.. '"/></ddic:parameter></ddic:parameters>',
				}
			)
		end,
	},
	table = {
		path = "/sap/bc/adt/ddic/tables",
		content_type = "application/vnd.sap.adt.ddic.tables.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local key_field = (opts.key_field or "MANDT"):upper()
			local key_type = (opts.key_type or "MANDT"):upper()
			return ddic_create_body(
				"ddic:table",
				'xmlns:ddic="http://www.sap.com/adt/ddic/tables"',
				"TABL/DT",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:fields><ddic:field ddic:name="' .. xml_escape(key_field) .. '" ddic:key="true" ddic:notNull="true"><ddic:typeRef adtcore:name="' .. xml_escape(key_type) .. '"/></ddic:field></ddic:fields>',
				}
			)
		end,
	},
	structure = {
		path = "/sap/bc/adt/ddic/structures",
		content_type = "application/vnd.sap.adt.ddic.structures.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local field = (opts.field or "DUMMY"):upper()
			local elem = (opts.element or "CHAR10"):upper()
			return ddic_create_body(
				"ddic:structure",
				'xmlns:ddic="http://www.sap.com/adt/ddic/structures"',
				"TABL/DS",
				desc,
				lang,
				name,
				user,
				pkg,
				{
					'<ddic:fields><ddic:field ddic:name="' .. xml_escape(field) .. '"><ddic:typeRef adtcore:name="' .. xml_escape(elem) .. '"/></ddic:field></ddic:fields>',
				}
			)
		end,
	},
	number_range = {
		path = "/sap/bc/adt/numberranges/objects",
		content_type = "application/vnd.sap.adt.numberranges.object.v1+xml; charset=utf-8",
		build = function(name, desc, lang, user, pkg, opts)
			opts = opts or {}
			local length = tostring(opts.length or 10)
			return adt_create_body(
				"nrob:numberRangeObject",
				'xmlns:nrob="http://www.sap.com/adt/numberranges"',
				"NROB/O",
				' adtcore:version="inactive"',
				desc,
				lang,
				name,
				user,
				table.concat({
					package_ref(pkg),
					'<nrob:attributes nrob:objectLength="' .. xml_escape(length) .. '" nrob:buffering="mainMemory"/>',
					"<nrob:intervals/>",
				}, "\n")
			)
		end,
	},
}

local do_create
local run_create_sapcli

-- Abre/siembra el objeto recién creado (igual para la ruta ADT y la sapcli). CDS lleva su
-- plantilla inicial (seed); el resto se abre directamente con source.open.
local function open_after_create(spec, name, desc, corrnr)
	if spec.group == "messageclass" then
		notify(name .. " (SE91) creada. Abriendo gestor de mensajes...")
		local ok, message = pcall(require, "sap-nvim.core.message")
		if ok and message.manage then
			message.manage(name)
		else
			vim.cmd("SapMessageClass " .. name)
		end
		return
	end
	if spec.group == "program_variant" then
		notify(name .. " (variante) creada.")
		return
	end
	if SOURCE_GROUPS[spec.open_group or spec.group] then
		notify(name .. " creado. Escribiendo plantilla inicial...")
		seed_source(spec, name, desc, corrnr, function()
			require("sap-nvim.core.source").open(name, spec.open_group or spec.group)
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
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
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
	if not meta or not valid_adt_create_path(meta.path) then
		notify("Ruta ADT de creación no validada para " .. spec.label .. "; usando fallback sapcli.", vim.log.levels.WARN)
		return do_create(spec, name, desc, pkg, corrnr)
	end
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
		if meta.fallback_sapcli and run_create_sapcli then
			notify(
				"ADT no pudo crear "
					.. name
					.. " ("
					.. adt_error_message(resp, code)
					.. "). Reintentando con sapcli...",
				vim.log.levels.WARN
			)
			return run_create_sapcli(spec, name, desc, pkg, corrnr)
		end
		notify("No se pudo crear " .. name .. ": " .. adt_error_message(resp, code), vim.log.levels.ERROR)
		return
	end

	open_after_create(spec, name, desc, corrnr)
end

local function build_create_args(spec, name, desc, pkg, corrnr, fgroup, opts)
	opts = opts or {}
	local args = { "sapcli", spec.group, "create" }
	if spec.needs_group then
		vim.list_extend(args, { fgroup, name, desc })
	elseif spec.group == "program_variant" then
		args = { "sapcli", "program", "variant", "create", opts.program, name, desc }
	else
		vim.list_extend(args, { name, desc, pkg })
	end
	if corrnr and corrnr ~= "" then
		vim.list_extend(args, { "--corrnr", corrnr })
	end
	return args
end

run_create_sapcli = function(spec, name, desc, pkg, corrnr, fgroup)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	local args = build_create_args(spec, name, desc, pkg, corrnr, fgroup)

	notify("Creando " .. spec.label .. " " .. name .. " en " .. (spec.needs_group and fgroup or pkg) .. "...")
	local err = {}
	sapcli.jobstart(args, {
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

do_create = function(spec, name, desc, pkg, corrnr, fgroup)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	-- Tipos con creación por ADT directo: evitan el idioma EN hardcodeado de sapcli.
	-- DDIC clásico sigue por sapcli; sus builders ADT se exponen como plan validable.
	if not spec.needs_group and ADT_CREATE[spec.key] then
		create_object_adt(spec, name, desc, pkg, corrnr)
		return
	end
	return run_create_sapcli(spec, name, desc, pkg, corrnr, fgroup)
end

-- ─── Creadores específicos: transacción y paquete ──────────────────────────
-- Estos objetos tienen firmas sapcli propias y NO son código editable, así que
-- no llaman a source.open (a diferencia del do_create genérico).

-- Crea una transacción (firma: transaction create NAME DESC PKG -t TYPE [--report-name PROG] [--corrnr T]).
local function build_transaction_args(name, desc, pkg, corrnr, ttype, prog)
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
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
	return args
end

local function create_transaction(name, desc, pkg, corrnr, ttype, prog)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not is_customer_namespace(name) then
		notify("Aviso: '" .. name .. "' no está en namespace cliente Z/Y o /NAMESPACE/.", vim.log.levels.WARN)
	end
	local args = build_transaction_args(name, desc, pkg, corrnr, ttype, prog)

	notify("Creando transacción " .. name .. " en " .. pkg .. "...")
	local out, err = {}, {}
	sapcli.jobstart(args, {
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

-- Crea una variante de report/programa cuando sapcli expone ese subcomando. Es un
-- best-effort: algunos sistemas/versions no tienen API ADT para variantes; en ese caso
-- el error guía al usuario hacia SE38/SA38 sin intentar escrituras alternativas.
local function create_report_variant(name, desc, corrnr, program)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	if not program or program == "" then
		notify("La variante necesita un programa/report destino.", vim.log.levels.WARN)
		return
	end
	local spec = type_by_key("report_variant")
	local args = build_create_args(spec, name, desc, nil, corrnr, nil, { program = program:upper() })

	notify("Creando variante " .. name .. " para " .. program:upper() .. "...")
	local out, err = {}, {}
	sapcli.jobstart(args, {
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
						"No se pudo crear la variante por sapcli: "
							.. msg
							.. ". Si tu sistema no expone variantes por ADT, usa SE38/SA38.",
						vim.log.levels.ERROR
					)
					return
				end
				open_after_create(spec, name, desc, corrnr)
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
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not is_customer_namespace(name) then
		notify("Aviso: '" .. name .. "' no está en namespace cliente Z/Y o /NAMESPACE/.", vim.log.levels.WARN)
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
	sapcli.jobstart(args, {
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
local function build_package_adt_body(name, desc, super, lang, user)
	local superref = (super and super ~= "")
			and ('<pak:superPackage adtcore:name="' .. xml_escape(super:upper()) .. '"/>')
		or "<pak:superPackage/>"
	return adt_create_body(
		"pak:package",
		'xmlns:pak="http://www.sap.com/adt/packages"',
		"DEVC/K",
		' adtcore:version="active"',
		desc,
		lang,
		name,
		user,
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
end

local function create_package_adt(name, desc, super, corrnr)
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
	-- Seguridad §7: aviso si el nombre no parece de cliente (Z/Y o namespace /).
	if not is_customer_namespace(name) then
		notify("Aviso: '" .. name .. "' no está en namespace cliente Z/Y o /NAMESPACE/.", vim.log.levels.WARN)
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
	local body = build_package_adt_body(name, desc, super, lang, c.user:upper())

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

local function all_create_metas()
	local out = {}
	for key, meta in pairs(ADT_CREATE) do
		out[#out + 1] = vim.tbl_extend("force", { key = key, mode = "adt" }, meta)
	end
	for key, meta in pairs(DDIC_CREATE) do
		out[#out + 1] = vim.tbl_extend("force", { key = key, mode = "ddic-plan" }, meta)
	end
	table.sort(out, function(a, b)
		return a.key < b.key
	end)
	return out
end

local function build_adt_plan(kind, name, desc, pkg, opts)
	opts = opts or {}
	local spec = type_by_key(kind)
	if not spec then
		return nil, "Tipo no soportado: " .. tostring(kind)
	end
	local key = spec.key
	local meta = ADT_CREATE[key] or DDIC_CREATE[key]
	if not meta then
		return nil, "Sin builder ADT para " .. spec.label .. " (usa sapcli)."
	end
	name = (name and name ~= "" and name or "ZDEMO"):upper()
	desc = desc and desc ~= "" and desc or name
	pkg = (pkg and pkg ~= "" and pkg or "$TMP"):upper()
	local lang = ((opts.lang or "ES") .. ""):upper()
	local user = ((opts.user or "DEVELOPER") .. ""):upper()
	return {
		key = key,
		label = spec.label,
		name = name,
		desc = desc,
		pkg = pkg,
		lang = lang,
		user = user,
		path = meta.path,
		content_type = meta.content_type,
		body = meta.build(name, desc, lang, user, pkg, opts),
		default_path = ADT_CREATE[key] ~= nil,
	}
end

local function open_adt_plan(plan)
	local lines = {
		"== sap-nvim ADT create plan (sin POST) ==",
		"type        : " .. plan.key .. " (" .. plan.label .. ")",
		"name        : " .. plan.name,
		"package     : " .. plan.pkg,
		"language    : " .. plan.lang,
		"method      : POST",
		"path        : " .. plan.path,
		"content-type: " .. plan.content_type,
		"default     : " .. (plan.default_path and "sí" or "no, validación DDIC offline"),
		"",
	}
	for _, line in ipairs(vim.split(tostring(plan.body or ""):gsub("\r", ""), "\n", { plain = true })) do
		lines[#lines + 1] = line
	end
	local buf = vim.api.nvim_create_buf(false, true)
	vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
	vim.bo[buf].bufhidden = "wipe"
	vim.bo[buf].filetype = "xml"
	vim.cmd("botright split")
	vim.api.nvim_win_set_buf(0, buf)
end

local function show_adt_plan(args)
	local parts = {}
	for p in tostring(args or ""):gmatch("%S+") do
		parts[#parts + 1] = p
	end
	local plan, err = build_adt_plan(parts[1] or "cds_view", parts[2], parts[2], parts[3])
	if not plan then
		notify(err, vim.log.levels.WARN)
		return
	end
	open_adt_plan(plan)
end

local function validate_create_routes(filter)
	local adt_http = require("sap-nvim.core.adt_http")
	if not adt_http.is_available() then
		notify("ADT no disponible (config.yml).", vim.log.levels.WARN)
		return
	end
	filter = (filter and filter ~= "" and filter:lower()) or nil
	notify("Validando rutas ADT de creación por discovery (GET, sin crear objetos)...")
	adt_http.request_async(
		{ method = "GET", path = "/sap/bc/adt/discovery", accept = "application/atomsvc+xml" },
		function(body)
			vim.schedule(function()
				local lines = { "== sap-nvim ADT create routes (discovery, sin POST) ==" }
				for _, meta in ipairs(all_create_metas()) do
					if not filter or meta.key:lower():find(filter, 1, true) or meta.path:lower():find(filter, 1, true) then
						local ok = body and body:find(meta.path, 1, true) ~= nil
						lines[#lines + 1] = string.format("%-20s %-10s %-7s %s", meta.key, meta.mode, ok and "OK" or "MISSING", meta.path)
					end
				end
				if #lines == 1 then
					lines[#lines + 1] = "(sin coincidencias)"
				end
				local buf = vim.api.nvim_create_buf(false, true)
				vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
				vim.bo[buf].bufhidden = "wipe"
				vim.bo[buf].filetype = "text"
				vim.cmd("botright split")
				vim.api.nvim_win_set_buf(0, buf)
			end)
		end
	)
end

M._test = {
	types = TYPES,
	type_by_key = type_by_key,
	normalize_name = normalize_name,
	is_customer_namespace = is_customer_namespace,
	validate_object_name = validate_object_name,
	creation_block_reason = creation_block_reason,
	xml_escape = xml_escape,
	adt_create_body = adt_create_body,
	adt_create = ADT_CREATE,
	ddic_create = DDIC_CREATE,
	adt_create_paths = ADT_CREATE_PATHS,
	valid_adt_create_path = valid_adt_create_path,
	initial_source = initial_source,
	build_cds_adt_body = build_cds_adt_body,
	build_adt_plan = build_adt_plan,
	all_create_metas = all_create_metas,
	build_write_args = build_write_args,
	build_create_args = build_create_args,
	build_transaction_args = build_transaction_args,
	build_package_adt_body = build_package_adt_body,
}

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
	local block = creation_block_reason()
	if block then
		notify("Creación bloqueada: " .. block .. ".", vim.log.levels.WARN)
		return
	end
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
			name = normalize_name(name)
			local valid, name_err = validate_object_name(spec, name)
			if not valid then
				notify(name_err, vim.log.levels.ERROR)
				return
			end
			if not is_customer_namespace(name) and (NAME_RULES[spec.key] or {}).customer_required ~= false then
				notify("Aviso: '" .. name .. "' no está en namespace cliente Z/Y o /NAMESPACE/.", vim.log.levels.WARN)
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
							fg = normalize_name(fg)
							local ok_fg, fg_err = validate_object_name(type_by_key("function_group"), fg)
							if not ok_fg then
								notify(fg_err, vim.log.levels.ERROR)
								return
							end
							do_create(spec, name, desc, nil, nil, fg)
						end
					)
					return
				end

				if spec.plan_only then
					ask_package(function(pkg)
						local plan, err = build_adt_plan(spec.key, name, desc, pkg)
						if not plan then
							notify(err, vim.log.levels.WARN)
							return
						end
						open_adt_plan(plan)
						notify(spec.label .. ": plan offline mostrado; no se ha enviado ningún POST.", vim.log.levels.INFO)
					end)
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
												prog = normalize_name(prog)
												if prog ~= "" then
													local ok_prog, prog_err =
														validate_object_name(type_by_key("program"), prog, { customer_required = false })
													if not ok_prog then
														notify(prog_err, vim.log.levels.ERROR)
														return
													end
												end
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

				if spec.group == "program_variant" then
					vim.ui.input({ prompt = "Programa/report destino: ", default = cfg.report or "Z" }, function(program)
						if not program or program == "" then
							return
						end
						program = normalize_name(program)
						local ok_prog, prog_err =
							validate_object_name(type_by_key("program"), program, { customer_required = false })
						if not ok_prog then
							notify(prog_err, vim.log.levels.ERROR)
							return
						end
						ask_transport(function(corrnr)
							create_report_variant(name, desc, corrnr, program)
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
	vim.api.nvim_create_user_command("SapNewAdtPlan", function(a)
		show_adt_plan(a.args)
	end, {
		nargs = "*",
		desc = "sap-nvim: mostrar payload/ruta ADT calculada sin crear objetos",
	})
	vim.api.nvim_create_user_command("SapNewValidateRoutes", function(a)
		validate_create_routes(a.args)
	end, {
		nargs = "?",
		desc = "sap-nvim: validar rutas ADT de creación vía discovery (solo GET)",
	})
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
