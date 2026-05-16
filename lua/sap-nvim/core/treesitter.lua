-- sap-nvim.core.treesitter
-- Configuración de parsers Tree-sitter para ABAP y CDS

local M = {}

function M.setup(opts)
  opts = opts or {}

  local parser_config = require("nvim-treesitter.parsers").get_parser_configs()

  -- tree-sitter-abap
  parser_config.abap = {
    install_info = {
      url = opts.abap_url or "https://github.com/kennyhml/tree-sitter-abap",
      files = { "src/parser.c", "src/scanner.c" },
      branch = opts.abap_branch or "main",
    },
    filetype = "abap",
  }

  -- tree-sitter-cds
  parser_config.cds = {
    install_info = {
      url = opts.cds_url or "https://github.com/cap-js-community/tree-sitter-cds",
      files = { "src/parser.c", "src/scanner.c" },
      branch = opts.cds_branch or "main",
    },
    filetype = "cds",
  }

  -- Configurar textobjects para ABAP
  if opts.textobjects ~= false then
    require("nvim-treesitter.configs").setup({
      textobjects = {
        select = {
          enable = true,
          lookahead = true,
          keymaps = {
            ["af"] = "@function.outer",
            ["if"] = "@function.inner",
            ["ac"] = "@class.outer",
            ["ic"] = "@class.inner",
            ["am"] = "@method.outer",
            ["im"] = "@method.inner",
          },
        },
        move = {
          enable = true,
          set_jumps = true,
          goto_next_start = {
            ["]m"] = "@method.outer",
            ["]f"] = "@function.outer",
          },
          goto_previous_start = {
            ["[m"] = "@method.outer",
            ["[f"] = "@function.outer",
          },
        },
      },
    })
  end

  -- Asegurar que el parser se compile si es necesario
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      -- TSInstallSync si no está instalado
      local has_parser = pcall(vim.treesitter.get_parser, 0, "abap")
      if not has_parser then
        vim.cmd("TSInstallSync abap")
      end
    end,
    once = true,
  })
end

return M
