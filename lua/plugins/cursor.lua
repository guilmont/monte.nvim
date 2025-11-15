-- VS Code-like cursor behavior and multicursor setup
-- - Move lines/blocks up/down with Alt+Up/Down or Alt+j/k
-- - Word-wise navigation with Ctrl+Left/Right
-- - Word-wise delete with Ctrl+Backspace/Delete in insert mode
-- - Multicursor with Ctrl+D (via vim-visual-multi)

return {
  'mg979/vim-visual-multi',
  branch = 'master',
  lazy = false,
  init = function()
    vim.g.VM_default_mappings = 0
    vim.g.VM_mouse_mappings = 1
    vim.g.VM_maps = {
      ['Find Under'] = '<C-d>',
      ['Find Subword Under'] = '<C-d>',
      ['Skip Region'] = '<C-k>',
      ['Remove Region'] = '<C-x>',
    }
  end,
  config = function()
    local map = function(mode, lhs, rhs, desc)
      vim.keymap.set(mode, lhs, rhs, { silent = true, desc = desc })
    end

    -- Move lines/blocks up/down
    local move_mappings = {
      { keys = { '<M-Down>', '<M-j>' }, dir = 'down', offset = '.+1', voffset = "'>+1" },
      { keys = { '<M-Up>', '<M-k>' }, dir = 'up', offset = '.-2', voffset = "'<-2" },
    }

    for _, move in ipairs(move_mappings) do
      for _, key in ipairs(move.keys) do
        map('n', key, ':m ' .. move.offset .. '<CR>==', 'Move line ' .. move.dir)
        map('i', key, '<Esc>:m ' .. move.offset .. '<CR>==gi', 'Move line ' .. move.dir)
        map('v', key, ":m " .. move.voffset .. "<CR>gv=gv", 'Move selection ' .. move.dir)
      end
    end

    -- Word-wise navigation
    map({ 'n', 'v' }, '<C-Left>', 'b', 'Word left')
    map({ 'n', 'v' }, '<C-Right>', 'w', 'Word right')
    map('i', '<C-Left>', '<C-o>b', 'Word left')
    map('i', '<C-Right>', '<C-o>w', 'Word right')

    -- Word-wise delete in insert mode
    map('i', '<C-Del>', '<C-o>dw', 'Delete next word')
    map('i', '<C-BS>', '<C-o>db', 'Delete previous word')
  end,
}
