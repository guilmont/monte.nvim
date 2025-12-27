-- Telescope: files, buffers, grep
return {
  'nvim-telescope/telescope.nvim',
  event = 'VimEnter',
  dependencies = {
    'nvim-lua/plenary.nvim',
    { 'nvim-telescope/telescope-fzf-native.nvim', build = 'make', cond = function() return vim.fn.executable 'make' == 1 end },
  },
  config = function()
    local telescope = require 'telescope'
    local builtin = require 'telescope.builtin'
    telescope.setup({
      pickers = {
        buffers = {
          sort_lastused = true,
          ignore_current_buffer = true,
          mappings = {
            i = { ['<C-d>'] = 'delete_buffer' },
          },
        },
      },
    })
    pcall(telescope.load_extension, 'fzf')

    -- Quick navigation
    vim.keymap.set('n', '<C-p>', builtin.find_files, { desc = 'Find files (Ctrl+P)' })
    vim.keymap.set('n', '<C-b>', builtin.buffers, { desc = 'Switch buffer' })
    vim.keymap.set('n', '<C-g>', builtin.live_grep, { desc = 'Grep project' })
  end,
}
