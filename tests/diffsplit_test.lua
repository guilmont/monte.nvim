-- Regression tests for lua/custom/diffsplit.lua (the side-by-side diff view
-- used by the Git and Perforce windows).
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/diffsplit_test.lua
--
-- Needs a POSIX file system for the symlink test. Exits with status 1 if any test fails.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)

local utils = require('custom.utils')
local diffsplit = require('custom.diffsplit')

-- ============================================================================
-- Fixtures and helpers
-- ============================================================================

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
dir = vim.fn.resolve(dir)

local function write_fixtures()
    vim.fn.writefile({ 'one', 'two', 'three' }, dir .. '/a.txt')
    vim.fn.writefile({ 'uno', 'dos', 'tres' }, dir .. '/b.txt')
    vim.fn.writefile({ 'real one', 'real two' }, dir .. '/real.txt')
    if vim.fn.getftype(dir .. '/link.txt') == '' then
        vim.uv.fs_symlink(dir .. '/real.txt', dir .. '/link.txt')
    end
end

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s: expected %s, got %s', what or 'value',
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
end

-- Run pending vim.schedule callbacks (WinClosed handlers schedule their cleanup)
local function flush() vim.wait(20) end

local function path(name) return dir .. '/' .. name end
local function edit(name) vim.cmd('edit ' .. vim.fn.fnameescape(path(name))) end
local function buf_of(name) return utils.find_buffer_by_path(path(name)) end
local function name_of(win) return vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))) end

-- Show a scratch "tool window" buffer in the current window, like the Git window
local function show_tool()
    local tool = utils.create_scratch_buffer('Tool Window', false)
    vim.bo[tool].buftype = 'nofile'
    utils.set_window_buffer(vim.api.nvim_get_current_win(), tool)
    return tool
end

local function open_diff(name, base)
    diffsplit.open_file_diffsplit({
        filepath = path(name),
        left_content = base or { 'one', 'TWO', 'three' },
        left_name = 'Diff Base',
    })
    return utils.find_buffer_by_name('Diff Base')
end

local function has_buffer_map(buf, key)
    return vim.api.nvim_buf_call(buf, function()
        return vim.fn.maparg(key, 'n', false, true).buffer == 1
    end)
end

local function wins_showing(buf)
    local wins = {}
    for _, w in ipairs(vim.api.nvim_list_wins()) do
        if vim.api.nvim_win_get_buf(w) == buf then table.insert(wins, w) end
    end
    return wins
end

-- Fresh state: one window, an empty buffer, files reset on disk
local function reset()
    vim.v.errmsg = ''
    vim.cmd('silent! tabonly')
    vim.cmd('silent! only')
    vim.cmd('enew!')
    vim.cmd('set diff& scrollbind& cursorbind& foldmethod& foldcolumn&')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= vim.api.nvim_get_current_buf() then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    write_fixtures()
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('q closes the base and leaves the file in diff-free state', function()
    edit('a.txt')
    local win = vim.api.nvim_get_current_win()
    local left = open_diff('a.txt')
    eq(#vim.api.nvim_list_wins(), 2, 'windows during diff')
    eq(vim.wo[win].diff, true, 'diff on')
    keys('q')
    eq(#vim.api.nvim_list_wins(), 1, 'windows after q')
    eq(vim.api.nvim_buf_is_valid(left), false, 'base buffer gone')
    eq(name_of(win), 'a.txt', 'file still shown')
    eq(vim.wo[win].diff, false, 'diff off')
    eq(has_buffer_map(buf_of('a.txt'), 'q'), false, 'q map removed')
end)

test('Q from a tool window returns to it and drops a file it loaded', function()
    show_tool()
    local win = vim.api.nvim_get_current_win()
    open_diff('b.txt')
    keys('Q')
    eq(name_of(win), 'Tool Window', 'tool window restored')
    eq(#vim.api.nvim_list_wins(), 1, 'windows')
    local b = buf_of('b.txt')
    eq(b == nil or not vim.api.nvim_buf_is_loaded(b), true, 'b.txt buffer unloaded')
end)

test('Q keeps a modified file buffer and its unsaved edits', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(a, 0, 1, false, { 'edited' })
    show_tool()
    local win = vim.api.nvim_get_current_win()
    open_diff('a.txt')
    eq(vim.api.nvim_win_get_buf(win), a, 'diff shows the modified buffer')
    keys('Q')
    eq(vim.api.nvim_buf_is_valid(a), true, 'buffer kept')
    eq(vim.bo[a].modified, true, 'still modified')
    eq(vim.api.nvim_buf_get_lines(a, 0, 1, false), { 'edited' }, 'edits kept')
    eq(name_of(win), 'Tool Window', 'tool window restored')
    eq(has_buffer_map(a, 'Q'), false, 'Q map removed')
end)

test('Q keeps a file buffer that was already loaded', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    show_tool()
    open_diff('a.txt')
    keys('Q')
    eq(vim.api.nvim_buf_is_loaded(a), true, 'buffer still loaded')
end)

test('Q does not close other windows showing the file', function()
    edit('b.txt')
    local b = vim.api.nvim_get_current_buf()
    local other = vim.api.nvim_get_current_win()
    vim.cmd('vsplit')
    show_tool()
    open_diff('b.txt')
    keys('Q')
    eq(vim.api.nvim_win_is_valid(other), true, 'other window still open')
    eq(vim.api.nvim_win_get_buf(other), b, 'other window still shows the file')
end)

test('Q on a modified file opened directly keeps it shown', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_buf_set_lines(a, 0, 1, false, { 'edited' })
    open_diff('a.txt')
    keys('Q')
    eq(vim.api.nvim_buf_is_valid(a), true, 'buffer kept')
    eq(vim.api.nvim_buf_get_lines(a, 0, 1, false), { 'edited' }, 'edits kept')
    eq(vim.api.nvim_win_get_buf(win), a, 'file still shown')
    eq(#vim.api.nvim_list_wins(), 1, 'base closed')
end)

test(':close on the base pane still cleans up after a float closed first', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    local right = vim.api.nvim_get_current_win()
    local left = open_diff('a.txt')
    -- e.g. an LSP hover: closing it must not consume the diff's WinClosed handler
    local float = vim.api.nvim_open_win(vim.api.nvim_create_buf(false, true), false,
        { relative = 'editor', row = 1, col = 1, width = 10, height = 2 })
    vim.api.nvim_win_close(float, true)
    flush()
    eq(has_buffer_map(a, 'q'), true, 'maps still set while the diff is open')
    vim.api.nvim_set_current_win(vim.fn.bufwinid(left))
    vim.cmd('close')
    flush()
    eq(has_buffer_map(a, 'q'), false, 'q map removed')
    eq(has_buffer_map(a, ']'), false, '] map removed')
    eq(vim.wo[right].diff, false, 'diff off')
end)

test(':close on the file pane closes the base pane and removes the maps', function()
    edit('b.txt')
    vim.cmd('vsplit')
    local keep = vim.api.nvim_get_current_win()
    vim.cmd('wincmd p')
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    local right = vim.api.nvim_get_current_win()
    local left = open_diff('a.txt')
    vim.api.nvim_set_current_win(right)
    vim.cmd('close')
    flush()
    eq(vim.api.nvim_buf_is_valid(left), false, 'base buffer gone')
    eq(#wins_showing(left), 0, 'no window shows the base')
    eq(vim.api.nvim_win_is_valid(keep), true, 'unrelated window kept')
    eq(has_buffer_map(a, 'q'), false, 'q map removed')
end)

test(':close on the file pane when only the base is left', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    local right = vim.api.nvim_get_current_win()
    local left = open_diff('a.txt')
    vim.api.nvim_set_current_win(right)
    vim.cmd('close')
    flush()
    eq(vim.api.nvim_buf_is_valid(left), false, 'base buffer gone')
    eq(#vim.api.nvim_list_wins(), 1, 'windows')
    eq(vim.wo[vim.api.nvim_list_wins()[1]].diff, false, 'diff off in remaining window')
    eq(has_buffer_map(a, 'q'), false, 'q map removed')
end)

test('the file\'s own buffer-local maps are restored on close', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    local hits = 0
    vim.keymap.set('n', 'q', function() hits = hits + 1 end, { buffer = a, desc = 'user q' })
    vim.keymap.set('n', ']', '<Cmd>let g:user_bracket = 1<CR>', { buffer = a })
    open_diff('a.txt')
    eq(vim.fn.maparg('q', 'n', false, true).desc ~= 'user q', true, 'diff q active during diff')
    keys('q')
    eq(hits, 0, 'user q not called by diff q')
    local q = vim.fn.maparg('q', 'n', false, true)
    eq(q.buffer, 1, 'q is buffer-local again')
    eq(q.desc, 'user q', 'user q restored')
    keys('q')
    eq(hits, 1, 'user q works')
    keys(']')
    eq(vim.g.user_bracket, 1, 'user ] works')
    eq(has_buffer_map(a, 'Q'), false, 'Q map removed')
    eq(has_buffer_map(a, 'r'), false, 'r map removed')
end)

test('opening the diff through a symlink keeps the modified buffer', function()
    edit('link.txt')
    local link = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(link, 0, 1, false, { 'edited' })
    local ok, err = pcall(diffsplit.open_file_diffsplit, {
        filepath = vim.fn.resolve(path('link.txt')),
        left_content = { 'real one', 'real two' },
        left_name = 'Diff Base',
    })
    eq(ok, true, 'open without error (' .. tostring(err) .. ')')
    eq(#vim.api.nvim_list_wins(), 2, 'windows')
    local right = vim.fn.win_getid(vim.fn.winnr('l'))
    eq(vim.api.nvim_win_get_buf(right), link, 'file pane shows the symlink buffer')
    eq(vim.api.nvim_buf_get_lines(link, 0, 1, false), { 'edited' }, 'edits kept')
    eq(vim.wo[right].diff, true, 'diff on')
end)

test('diff opens an existing buffer for the file without :edit', function()
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(a, 0, 1, false, { 'edited' })
    show_tool()
    local win = vim.api.nvim_get_current_win()
    open_diff('a.txt')
    eq(vim.api.nvim_win_get_buf(win), a, 'reused buffer')
    eq(vim.api.nvim_buf_get_lines(a, 0, 1, false), { 'edited' }, 'edits kept')
end)

test('close restores scrollbind, cursorbind and fold settings', function()
    edit('a.txt')
    local win = vim.api.nvim_get_current_win()
    vim.wo[win].scrollbind = true
    vim.wo[win].cursorbind = true
    vim.wo[win].foldmethod = 'indent'
    vim.wo[win].foldcolumn = '1'
    open_diff('a.txt')
    eq(vim.wo[win].foldmethod, 'diff', 'diff folds during diff')
    keys('q')
    eq(vim.wo[win].scrollbind, true, 'scrollbind')
    eq(vim.wo[win].cursorbind, true, 'cursorbind')
    eq(vim.wo[win].diff, false, 'diff')
    eq(vim.wo[win].foldmethod, 'indent', 'foldmethod')
    eq(vim.wo[win].foldcolumn, '1', 'foldcolumn')
end)

test('close turns scrollbind and cursorbind off when they were off', function()
    edit('a.txt')
    local win = vim.api.nvim_get_current_win()
    open_diff('a.txt')
    keys('Q')
    eq(vim.wo[win].scrollbind, false, 'scrollbind')
    eq(vim.wo[win].cursorbind, false, 'cursorbind')
    eq(vim.wo[win].diff, false, 'diff')
    eq(vim.wo[win].foldmethod, 'manual', 'foldmethod')
end)

-- ============================================================================
-- Runner
-- ============================================================================

local failed = 0
for _, t in ipairs(tests) do
    reset()
    local ok, err = pcall(t.fn)
    if ok then
        io.stdout:write('PASS  ' .. t.name .. '\n')
    else
        failed = failed + 1
        io.stdout:write('FAIL  ' .. t.name .. '\n      ' .. tostring(err) .. '\n')
    end
end

vim.fn.delete(dir, 'rf')
io.stdout:write(string.format('\n%d passed, %d failed\n', #tests - failed, failed))
os.exit(failed > 0 and 1 or 0)
