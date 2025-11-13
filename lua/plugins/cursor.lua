-- VS Code-like cursor behavior and multicursor setup
-- - Move lines/blocks up/down with Alt+Up/Down
-- - Duplicate lines/blocks with Shift+Alt+Up/Down
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
      ['Add Cursor Down'] = '<A-Down>',
      ['Add Cursor Up'] = '<A-Up>',
      ['Skip Region'] = '<C-k>',
      ['Remove Region'] = '<C-x>',
    }
  end,
  config = function()
    local function map(mode, lhs, rhs, opts)
      local options = { silent = true }
      if opts then options = vim.tbl_extend('force', options, opts) end
      vim.keymap.set(mode, lhs, rhs, options)
    end

    map('n', '<A-Down>', ':m .+1<CR>==', { desc = 'Move line down' })
    map('n', '<A-Up>', ':m .-2<CR>==', { desc = 'Move line up' })
    map('i', '<A-Down>', '<Esc>:m .+1<CR>==gi', { desc = 'Move line down' })
    map('i', '<A-Up>', '<Esc>:m .-2<CR>==gi', { desc = 'Move line up' })
    map('v', '<A-Down>', ":m '>+1<CR>gv=gv", { desc = 'Move selection down' })
    map('v', '<A-Up>', ":m '<-2<CR>gv=gv", { desc = 'Move selection up' })

    map('n', '<S-A-Down>', 'yyp', { desc = 'Duplicate line down' })
    map('n', '<S-A-Up>', 'yyP', { desc = 'Duplicate line up' })
    map('v', '<S-A-Down>', ":<C-u>'<,'>copy '><CR>gv", { desc = 'Duplicate selection down' })
    map('v', '<S-A-Up>', ":<C-u>'<,'>copy '<-1<CR>gv", { desc = 'Duplicate selection up' })

    map({ 'n', 'v' }, '<C-Left>', 'b', { desc = 'Word left' })
    map({ 'n', 'v' }, '<C-Right>', 'w', { desc = 'Word right' })
    map('i', '<C-Left>', '<C-o>b', { desc = 'Word left' })
    map('i', '<C-Right>', '<C-o>w', { desc = 'Word right' })

    map('i', '<C-Del>', '<C-o>dw', { desc = 'Delete next word' })
    map('i', '<C-BS>', '<C-o>db', { desc = 'Delete previous word' })
    map('i', '<C-Backspace>', '<C-o>db', { desc = 'Delete previous word' })

    map({ 'n', 'i' }, '<M-j>', function()
      if vim.fn.mode() == 'i' then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>:m .+1<CR>==gi', true, false, true), 'n', false)
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':m .+1<CR>==', true, false, true), 'n', false)
      end
    end, { desc = 'Move line down (Alt-j)' })
    map({ 'n', 'i' }, '<M-k>', function()
      if vim.fn.mode() == 'i' then
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>:m .-2<CR>==gi', true, false, true), 'n', false)
      else
        vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(':m .-2<CR>==', true, false, true), 'n', false)
      end
    end, { desc = 'Move line up (Alt-k)' })
    map('v', '<M-j>', ":m '>+1<CR>gv=gv", { desc = 'Move selection down (Alt-j)' })
    map('v', '<M-k>', ":m '<-2<CR>gv=gv", { desc = 'Move selection up (Alt-k)' })
  end,
}
