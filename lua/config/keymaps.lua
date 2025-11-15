-- Keymaps
-- Clear highlights on search when pressing <Esc> in normal mode
vim.keymap.set('n', '<Esc>', '<cmd>nohlsearch<CR>')

-- V-block selection (WSL doesn't like <C-v>)
vim.keymap.set('n', '<M-v>', '<C-v>', { silent = true, desc = 'Start V-block selection' })

-- ============================================================================
-- Line/block movement
-- ============================================================================

-- Move lines up/down with Alt+Up/Down or Alt+j/k
vim.keymap.set('n', '<M-Down>', ':m .+1<CR>==', { silent = true, desc = 'Move line down' })
vim.keymap.set('n', '<M-j>', ':m .+1<CR>==', { silent = true, desc = 'Move line down' })
vim.keymap.set('n', '<M-Up>', ':m .-2<CR>==', { silent = true, desc = 'Move line up' })
vim.keymap.set('n', '<M-k>', ':m .-2<CR>==', { silent = true, desc = 'Move line up' })

vim.keymap.set('i', '<M-Down>', '<Esc>:m .+1<CR>==gi', { silent = true, desc = 'Move line down' })
vim.keymap.set('i', '<M-j>', '<Esc>:m .+1<CR>==gi', { silent = true, desc = 'Move line down' })
vim.keymap.set('i', '<M-Up>', '<Esc>:m .-2<CR>==gi', { silent = true, desc = 'Move line up' })
vim.keymap.set('i', '<M-k>', '<Esc>:m .-2<CR>==gi', { silent = true, desc = 'Move line up' })

vim.keymap.set('v', '<M-Down>', ":m '>+1<CR>gv=gv", { silent = true, desc = 'Move selection down' })
vim.keymap.set('v', '<M-j>', ":m '>+1<CR>gv=gv", { silent = true, desc = 'Move selection down' })
vim.keymap.set('v', '<M-Up>', ":m '<-2<CR>gv=gv", { silent = true, desc = 'Move selection up' })
vim.keymap.set('v', '<M-k>', ":m '<-2<CR>gv=gv", { silent = true, desc = 'Move selection up' })

-- ============================================================================
-- Word-wise navigation and editing
-- ============================================================================

-- Word-wise navigation
vim.keymap.set({ 'n', 'v' }, '<C-Left>', 'b', { silent = true, desc = 'Word left' })
vim.keymap.set({ 'n', 'v' }, '<C-Right>', 'w', { silent = true, desc = 'Word right' })
vim.keymap.set('i', '<C-Left>', '<C-o>b', { silent = true, desc = 'Word left' })
vim.keymap.set('i', '<C-Right>', '<C-o>w', { silent = true, desc = 'Word right' })

-- Word-wise delete in insert mode
vim.keymap.set('i', '<C-Del>', '<C-o>dw', { silent = true, desc = 'Delete next word' })
vim.keymap.set('i', '<C-BS>', '<C-o>db', { silent = true, desc = 'Delete previous word' })
