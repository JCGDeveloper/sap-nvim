-- sap-nvim.core.treesitter
-- Configuración de parsers Tree-sitter para ABAP y CDS
-- Todo envuelto en pcall para no bloquear la carga de Neovim

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- Registrar parser ABAP
  local ok, parser_config = pcall(function()
    return require("nvim-treesitter.parsers").get_parser_configs()
  end)

  if not ok then
    vim.notify("sap-nvim: nvim-treesitter no disponible. Instálalo con Lazy.", vim.log.levels.WARN)
    return
  end

  parser_config.abap = {
    install_info = {
      url = opts.abap_url or "https://github.com/kennyhml/tree-sitter-abap",
      files = { "src/parser.c", "src/scanner.c" },
      branch = opts.abap_branch or "main",
    },
    filetype = "abap",
  }

  parser_config.cds = {
    install_info = {
      url = opts.cds_url or "https://github.com/cap-js-community/tree-sitter-cds",
      files = { "src/parser.c", "src/scanner.c" },
      branch = opts.cds_branch or "main",
    },
    filetype = "cds",
  }

  vim.notify("sap-nvim: Parsers ABAP y CDS registrados. Ejecuta :TSInstall abap", vim.log.levels.INFO)
end

return M
