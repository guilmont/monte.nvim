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
    telescope.setup {}
    pcall(telescope.load_extension, 'fzf')

    -- Quick navigation
    vim.keymap.set('n', '<C-p>', function()
      builtin.find_files { cwd = vim.fn.getcwd(), hidden = true }
    end, { desc = 'Find files (Ctrl+P)' })
    vim.keymap.set('n', '<C-b>', builtin.buffers, { desc = 'Switch buffer' })
    vim.keymap.set('n', '<C-g>', function()
      builtin.live_grep { cwd = vim.fn.getcwd() }
    end, { desc = 'Grep project' })
  end,
}
