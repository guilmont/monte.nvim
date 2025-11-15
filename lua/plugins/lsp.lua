-- LSP core setup
--
-- Philosophy:
--   The user should NOT edit this file to choose servers. Use `:Mason` UI to
--   install or uninstall language servers. Any server installed through Mason
--   (or already available on PATH and installed via Mason-lspconfig) is
--   automatically configured on startup with sensible defaults and overrides.
--
--   After installing a new server during a running session, run `:LspSetupInstalled`
--   (provided below) or restart Neovim to configure it.
--
-- Namespace keymaps under <leader>l...
-- Examples:
--   <leader>ld  Goto Definition
--   <leader>lD  Goto Declaration
--   <leader>lr  References
--   <leader>li  Goto Implementation
--   <leader>lh  Hover
--   <leader>ls  Signature Help
--   <leader>lR  Rename
--   <leader>la  Code Action
--   <leader>lf  Format Buffer
--   <leader>lS  Workspace Symbols
--   <leader>lwA Add Workspace Folder
--   <leader>lwR Remove Workspace Folder
--   <leader>lwl List Workspace Folders
--   <leader>lx  Line Diagnostics
--   <leader>lX  Restart LSP Clients
--   <leader>lH  Toggle Inlay Hints
--   [d / ]d     Previous / Next Diagnostic
--
return {
  'neovim/nvim-lspconfig',
  dependencies = {
    { 'mason-org/mason.nvim', opts = {} },
    'mason-org/mason-lspconfig.nvim',
  },
  config = function()
    -- Capabilities (augment with cmp if available)
    local capabilities = vim.lsp.protocol.make_client_capabilities()
    pcall(function()
      capabilities = require('cmp_nvim_lsp').default_capabilities(capabilities)
    end)

    -- Buffer-local keymaps on LSP attach
    vim.api.nvim_create_autocmd('LspAttach', {
      group = vim.api.nvim_create_augroup('lsp-attach', { clear = true }),
      callback = function(event)
        local buf = event.buf
        local function map(keys, fn, desc)
          vim.keymap.set('n', keys, fn, { buffer = buf, desc = 'LSP: ' .. desc })
        end
        map('<leader>ld', vim.lsp.buf.definition, 'Goto Definition')
        map('<leader>lD', vim.lsp.buf.declaration, 'Goto Declaration')
        map('<leader>lr', vim.lsp.buf.references, 'References')
        map('<leader>li', vim.lsp.buf.implementation, 'Goto Implementation')
        map('<leader>lh', vim.lsp.buf.hover, 'Hover')
        map('<leader>ls', vim.lsp.buf.signature_help, 'Signature Help')
        map('<leader>lR', vim.lsp.buf.rename, 'Rename')
        map('<leader>la', vim.lsp.buf.code_action, 'Code Action')
        map('<leader>lf', function() vim.lsp.buf.format { async = true } end, 'Format Buffer')
        map('<leader>lS', vim.lsp.buf.workspace_symbol, 'Workspace Symbols')
        map('<leader>lwA', vim.lsp.buf.add_workspace_folder, 'Add Workspace Folder')
        map('<leader>lwR', vim.lsp.buf.remove_workspace_folder, 'Remove Workspace Folder')
        map('<leader>lwl', function() print(vim.inspect(vim.lsp.buf.list_workspace_folders())) end, 'List Workspace Folders')
        map('<leader>lx', vim.diagnostic.open_float, 'Line Diagnostics')
        map('<leader>lX', function()
          for _, client in ipairs(vim.lsp.get_clients({ bufnr = buf })) do
            vim.lsp.stop_client(client.id)
          end
        end, 'Restart LSP Clients')
        map('<leader>lH', function() if vim.lsp.inlay_hint then vim.lsp.inlay_hint.enable(not vim.lsp.inlay_hint.is_enabled({ bufnr = buf }), { bufnr = buf }) end end, 'Toggle Inlay Hints')
        map('[d', vim.diagnostic.goto_prev, 'Previous Diagnostic')
        map(']d', vim.diagnostic.goto_next, 'Next Diagnostic')
      end,
    })

    -- Overrides for specific servers if they are installed via Mason
    local server_overrides = {
      lua_ls = { settings = { Lua = { completion = { callSnippet = 'Replace' } } } },
    }

    -- Setup mason-lspconfig with no auto-install list; user controls via :Mason
    require('mason-lspconfig').setup()

    -- Auto-configure any LSP servers installed via Mason
    -- This discovers installed servers, checks if they're already running,
    -- and configures them with merged capabilities + overrides if needed.
    local function setup_installed()
      -- Get list of all servers installed through Mason (e.g., clangd, lua_ls)
      local installed = require('mason-lspconfig').get_installed_servers()

      for _, name in ipairs(installed) do
        -- Check if this server is already active to avoid duplicate setup
        local active_clients = vim.lsp.get_clients({ name = name })

        if #active_clients == 0 then
          -- Merge base capabilities (with cmp support) and server-specific overrides
          local base = { capabilities = capabilities }
          local merged = vim.tbl_deep_extend('force', base, server_overrides[name] or {})

          -- Try new vim.lsp.config API first (nvim 0.11+), fallback to lspconfig
          if vim.lsp.config and vim.lsp.config[name] then
            vim.lsp.enable(name)
          else
            -- Fallback to lspconfig module for older nvim or servers not in new API
            local ok, lsp = pcall(require, 'lspconfig.' .. name)
            if ok then
              lsp.setup(merged)
            end
          end
        end
      end
    end

    -- Initial setup of any already-installed servers
    setup_installed()

    -- User command to configure newly installed servers without restart
    vim.api.nvim_create_user_command('LspSetupInstalled', function()
      setup_installed()
      print('[LSP] Configured Mason-installed servers.')
    end, { desc = 'Configure any Mason-installed LSP servers not yet active' })
  end,
}
