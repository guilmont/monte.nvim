-- LSP configuration with Mason and per-language servers
return {
  'neovim/nvim-lspconfig',
  dependencies = {
    { 'mason-org/mason.nvim', opts = {} },
    'mason-org/mason-lspconfig.nvim',
    'WhoIsSethDaniel/mason-tool-installer.nvim',
  },
  config = function()
    -- Keymaps on LSP attach
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('lsp-attach', { clear = true }),
      callback = function(event)
        local map = function(keys, func, desc)
          vim.keymap.set('n', keys, func, { buffer = event.buf, desc = 'LSP: ' .. desc })
        end
        map('gd', vim.lsp.buf.definition, 'Goto Definition')
        map('gr', vim.lsp.buf.references, 'References')
        map('K', vim.lsp.buf.hover, 'Hover')
        map('<leader>rn', vim.lsp.buf.rename, 'Rename')
        map('<leader>ca', vim.lsp.buf.code_action, 'Code Action')
      end,
    })

    -- Servers
    local servers = {
      clangd = {},
      rust_analyzer = {},
      pyright = {},
      ts_ls = {},
      lua_ls = { settings = { Lua = { completion = { callSnippet = 'Replace' } } } },
    }

    -- Capabilities (nvim-cmp integration if present)
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    pcall(function()
      capabilities = require('cmp_nvim_lsp').default_capabilities(capabilities)
    end)

    local ensure = vim.tbl_keys(servers)
    require('mason-tool-installer').setup { ensure_installed = ensure }
    require('mason-lspconfig').setup {
      handlers = {
        function(server)
          local cfg = vim.tbl_deep_extend('force', { capabilities = capabilities }, servers[server] or {})
          require('lspconfig')[server].setup(cfg)
        end,
      },
    }
  end,
}
