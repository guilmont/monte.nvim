-- Minimal IntelliSense via nvim-cmp
return {
  'hrsh7th/nvim-cmp',
  event = 'InsertEnter',
  dependencies = {
    'hrsh7th/cmp-nvim-lsp',
    'L3MON4D3/LuaSnip',
  },
  config = function()
    local cmp = require 'cmp'
    cmp.setup {
            completion = {
              autocomplete = false,  -- Only show completion on manual trigger
            },
      mapping = cmp.mapping.preset.insert({
        ['<C-Space>'] = cmp.mapping.complete(),
        ['<CR>'] = cmp.mapping.confirm({ select = true }),
        ['j'] = cmp.mapping.select_next_item(),
        ['k'] = cmp.mapping.select_prev_item(),
      }),
      sources = {
        { name = 'nvim_lsp' },
      },
      snippet = {
        expand = function(args)
          require('luasnip').lsp_expand(args.body)
        end,
      },
    }
  end,
}
