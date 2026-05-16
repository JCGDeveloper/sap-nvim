-- sap-nvim.core.lsp
-- Configuración de servidores LSP para ABAP y CDS

local M = {}

function M.setup(opts)
  opts = opts or {}

  -- abaplint via efm-langserver
  -- abaplint CLI no es un servidor LSP real, necesita efm-langserver como puente
  if opts.abaplint ~= false then
    local efm_opts = opts.abaplint or {}
    local efm_config = efm_opts.config
      or vim.fn.expand("~/Desktop/sap-nvim/config/efm-langserver.yaml")

    vim.lsp.config('abaplint', {
      cmd = { 'efm-langserver', '-c', efm_config },
      filetypes = { 'abap' },
      root_markers = efm_opts.root_markers or {
        'abaplint.json',
        '.git',
      },
      settings = efm_opts.settings or {},
      capabilities = vim.lsp.protocol.make_client_capabilities(),
    })

    vim.lsp.enable('abaplint')
  end

  -- CDS LSP: servidor de lenguaje para Core Data Services
  if opts.cds ~= false then
    local cds_opts = opts.cds or {}
    local lspconfig = require("lspconfig")
    local configs = require("lspconfig.configs")

    if not configs.cds_lsp then
      configs.cds_lsp = {
        default_config = {
          cmd = { cds_opts.cmd or "cds-lsp", "--stdio" },
          filetypes = { "cds" },
          root_dir = lspconfig.util.root_pattern(
            unpack(cds_opts.root_markers or { ".git", "package.json" })
          ),
          settings = cds_opts.settings or {},
        },
      }
    end

    lspconfig.cds_lsp.setup({
      on_attach = function(client, bufnr)
        -- Keymaps específicos para CDS
        local bufopts = { noremap = true, silent = true, buffer = bufnr }
        vim.keymap.set("n", "gd", vim.lsp.buf.definition, bufopts)
        vim.keymap.set("n", "K", vim.lsp.buf.hover, bufopts)
        vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, bufopts)
      end,
    })
  end

  -- Atajos LSP globales para ABAP
  vim.api.nvim_create_autocmd("FileType", {
    pattern = "abap",
    callback = function()
      local bufopts = { noremap = true, silent = true, buffer = true }

      -- Navegación
      vim.keymap.set("n", "gd", vim.lsp.buf.definition, bufopts)
      vim.keymap.set("n", "K", vim.lsp.buf.hover, bufopts)
      vim.keymap.set("n", "gr", vim.lsp.buf.references, bufopts)
      vim.keymap.set("n", "gi", vim.lsp.buf.implementation, bufopts)

      -- Diagnósticos
      vim.keymap.set("n", "<leader>e", vim.diagnostic.open_float, bufopts)
      vim.keymap.set("n", "[d", vim.diagnostic.goto_prev, bufopts)
      vim.keymap.set("n", "]d", vim.diagnostic.goto_next, bufopts)

      -- Acciones
      vim.keymap.set("n", "<leader>rn", vim.lsp.buf.rename, bufopts)
      vim.keymap.set("n", "<leader>ca", vim.lsp.buf.code_action, bufopts)
      vim.keymap.set("n", "<leader>f", function()
        vim.lsp.buf.format({ async = true })
      end, bufopts)
    end,
  })
end

return M
