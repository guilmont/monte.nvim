-- Regression tests for the window helpers in lua/custom/utils.lua.
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/utils_test.lua
--
-- Exits with status 1 if any test fails.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)

local utils = require('custom.utils')

-- ============================================================================
-- Fixtures and helpers
-- ============================================================================

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
dir = vim.fn.resolve(dir)
vim.fn.writefile({ 'a1', 'a2' }, dir .. '/a.txt')
vim.fn.writefile({ 'b1', 'b2' }, dir .. '/b.txt')
vim.fn.writefile({ 'c1', 'c2' }, dir .. '/c.txt')
vim.fn.writefile({ 'r1' }, dir .. '/real.txt')
vim.uv.fs_symlink(dir .. '/real.txt', dir .. '/link.txt')
vim.uv.fs_symlink(dir, dir .. '/linkdir')

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s: expected %s, got %s', what or 'value',
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function edit(name) vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/' .. name)) end

local function tab_of(win) return vim.api.nvim_win_get_tabpage(win) end

-- Fresh state: one tab, one window, no buffers but an empty one
local function reset()
    vim.cmd('silent! tabonly')
    vim.cmd('silent! only')
    vim.cmd('enew')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= vim.api.nvim_get_current_buf() then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
end

-- Tab 1: a.txt | b.txt. Tab 2 (current): c.txt
local function two_tabs()
    edit('a.txt')
    vim.cmd('vsplit ' .. vim.fn.fnameescape(dir .. '/b.txt'))
    local tab1 = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabnew ' .. vim.fn.fnameescape(dir .. '/c.txt'))
    return tab1, vim.api.nvim_get_current_tabpage()
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('close_other_windows only closes windows in the current tab', function()
    local tab1, tab2 = two_tabs()
    vim.cmd('vsplit')
    local target = utils.close_other_windows()
    eq(#vim.api.nvim_tabpage_list_wins(tab1), 2, 'windows left in tab 1')
    eq(#vim.api.nvim_tabpage_list_wins(tab2), 1, 'windows left in tab 2')
    eq(tab_of(target), tab2, 'returned window is in the current tab')
end)

test('create_window_for_buffer does not reuse an empty window from another tab', function()
    -- Tab 1 keeps the empty starting buffer, tab 2 shows a file
    local tab1 = vim.api.nvim_get_current_tabpage()
    vim.cmd('tabnew ' .. vim.fn.fnameescape(dir .. '/c.txt'))
    local tab2 = vim.api.nvim_get_current_tabpage()
    eq(utils.find_empty_buffer_window(), nil, 'empty window in the current tab')
    local tool = utils.create_scratch_buffer('Tool', false)
    local win = utils.create_window_for_buffer(tool)
    eq(tab_of(win), tab2, 'tool window tab')
    eq(vim.api.nvim_get_current_tabpage(), tab2, 'current tab')
    eq(#vim.api.nvim_tabpage_list_wins(tab1), 1, 'tab 1 windows')
    eq(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(vim.api.nvim_tabpage_list_wins(tab1)[1])), '',
        'tab 1 still shows the empty buffer')
end)

test('find_alternate_real_window ignores windows in other tabs', function()
    two_tabs()
    eq(utils.find_alternate_real_window(vim.api.nvim_get_current_win()), nil, 'alternate window')
end)

test('find_window_by_buffer prefers the current tab, then falls back to others', function()
    two_tabs()
    local a = vim.fn.bufnr(dir .. '/a.txt')
    -- a.txt only in tab 1: still found, for callers that just need some window showing it
    local win = utils.find_window_by_buffer(a)
    eq(win ~= nil and vim.api.nvim_win_get_buf(win) == a, true, 'found in another tab')
    -- a.txt in both tabs: the current tab's window wins
    vim.cmd('vsplit ' .. vim.fn.fnameescape(dir .. '/a.txt'))
    local here = vim.api.nvim_get_current_win()
    eq(utils.find_window_by_buffer(a), here, 'window in current tab')
end)

test('reuse_or_create_window_for_buffer stays in the current tab', function()
    local _, tab2 = two_tabs()
    local a = vim.fn.bufnr(dir .. '/a.txt')
    local win = utils.reuse_or_create_window_for_buffer(a)
    eq(vim.api.nvim_get_current_tabpage(), tab2, 'current tab')
    eq(tab_of(win), tab2, 'window tab')
    eq(vim.api.nvim_win_get_buf(win), a, 'window buffer')
end)

test('dismiss_buffer_window counts real windows in the window\'s own tab', function()
    local _, tab2 = two_tabs()
    -- Lone tool window in tab 2: swap c.txt back in rather than closing the tab
    local tool = utils.create_scratch_buffer('Tool', false)
    local win = vim.api.nvim_get_current_win()
    utils.set_window_buffer(win, tool)
    utils.dismiss_buffer_window(win, tool)
    eq(vim.api.nvim_tabpage_is_valid(tab2), true, 'tab 2 still open')
    eq(vim.api.nvim_win_is_valid(win), true, 'window still open')
    eq(vim.fs.basename(vim.api.nvim_buf_get_name(vim.api.nvim_win_get_buf(win))), 'c.txt', 'window buffer')
    eq(vim.api.nvim_buf_is_valid(tool), false, 'tool buffer deleted')
end)

test('is_buffer_displayed still sees windows in other tabs', function()
    two_tabs()
    eq(utils.is_buffer_displayed(vim.fn.bufnr(dir .. '/a.txt')), true, 'a.txt displayed in tab 1')
end)

test('dismiss_buffer_window keeps a buffer that is shown in another tab', function()
    two_tabs()
    local a = vim.fn.bufnr(dir .. '/a.txt')
    vim.cmd('vsplit')
    local win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(win, a)
    utils.dismiss_buffer_window(win, a)
    eq(vim.api.nvim_buf_is_valid(a), true, 'a.txt buffer kept')
end)

test('find_buffer_by_path sees a buffer opened through a file symlink', function()
    edit('link.txt')
    local link = vim.api.nvim_get_current_buf()
    edit('a.txt')
    eq(utils.find_buffer_by_path(dir .. '/real.txt'), link, 'real name finds the symlink buffer')
    vim.api.nvim_buf_delete(link, { force = true })
    edit('real.txt')
    local real = vim.api.nvim_get_current_buf()
    edit('a.txt')
    eq(utils.find_buffer_by_path(dir .. '/link.txt'), real, 'symlink name finds the real buffer')
end)

test('find_buffer_by_path sees a buffer opened through a directory symlink', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/linkdir/a.txt'))
    local a = vim.api.nvim_get_current_buf()
    edit('b.txt')
    eq(utils.find_buffer_by_path(dir .. '/a.txt'), a, 'real path')
    eq(utils.find_buffer_by_path(dir .. '//./a.txt'), a, 'unnormalized path')
    eq(utils.find_buffer_by_path(dir .. '/c.txt'), nil, 'file without a buffer')
end)

test('find_buffer_by_path checks the current buffer first', function()
    edit('real.txt')
    edit('link.txt')
    local link = vim.api.nvim_get_current_buf()
    eq(utils.find_buffer_by_path(dir .. '/real.txt'), link, 'current buffer')
end)

test('confirm runs on_yes only for y or Y', function()
    local orig = vim.ui.input
    local prompts, yes = {}, 0
    for _, answer in ipairs({ 'y', 'Y', 'n', '', 'yes', false }) do
        vim.ui.input = function(opts, cb)
            table.insert(prompts, opts.prompt)
            cb(answer or nil)
        end
        utils.confirm('Delete? (y/N): ', function() yes = yes + 1 end)
    end
    vim.ui.input = orig
    eq(yes, 2, 'on_yes calls')
    eq(prompts[1], 'Delete? (y/N): ', 'prompt')
end)

test('notify_error prefixes and trims the message', function()
    local orig = vim.notify
    local got = {}
    vim.notify = function(msg, level) table.insert(got, { msg, level }) end
    local _, err = pcall(error, 'status failed\n', 0)
    utils.notify_error('Git: ', err)
    utils.notify_error('Git: ', 42)
    vim.notify = orig
    eq(got, { { 'Git: status failed', vim.log.levels.ERROR }, { 'Git: 42', vim.log.levels.ERROR } }, 'notifications')
end)

test('get_or_create_scratch_buffer reuses a loaded cached buffer', function()
    local buf, created = utils.get_or_create_scratch_buffer('Tool', nil, false)
    eq(created, true, 'first call creates')
    eq(vim.bo[buf].modifiable, false, 'modifiable')
    local again, created_again = utils.get_or_create_scratch_buffer('Tool', buf, false)
    eq({ again, created_again }, { buf, false }, 'second call')
end)

test('get_or_create_scratch_buffer replaces an unloaded buffer with the name', function()
    local buf = utils.create_scratch_buffer('Tool', true)
    vim.cmd('bdelete ' .. buf)
    eq(vim.api.nvim_buf_is_valid(buf) and not vim.api.nvim_buf_is_loaded(buf), true, 'unloaded leftover')
    local new, created = utils.get_or_create_scratch_buffer('Tool', buf, true)
    eq(created, true, 'created')
    eq(new ~= buf and vim.api.nvim_buf_is_loaded(new), true, 'fresh buffer')
    eq(vim.api.nvim_buf_is_valid(buf), false, 'leftover wiped')
    eq(vim.fs.basename(vim.api.nvim_buf_get_name(new)), 'Tool', 'name')
    eq(vim.bo[new].modifiable, true, 'modifiable')
end)

test('create_scratch_buffer takes the name from a stale hidden buffer', function()
    local stale = utils.create_scratch_buffer('Tool', false)
    local buf = utils.create_scratch_buffer('Tool', false)
    eq(vim.api.nvim_buf_is_valid(stale), false, 'stale buffer wiped')
    eq(utils.find_buffer_by_name('Tool'), buf, 'new buffer holds the name')
end)

test('create_scratch_buffer leaves a displayed or modified buffer with the name alone', function()
    local nbufs = #vim.api.nvim_list_bufs()
    local shown = utils.create_scratch_buffer('Shown', false)
    vim.api.nvim_win_set_buf(0, shown)
    local ok, err = pcall(utils.create_scratch_buffer, 'Shown', false)
    eq(ok, false, 'fails')
    eq(err, 'Buffer "Shown" is already open', 'error')
    eq(utils.release_buffer_name('Shown'), false, 'name not released')

    -- A hidden file buffer with unsaved edits (scratch buffers never count as modified)
    edit('a.txt')
    local edited = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { 'work' })
    vim.api.nvim_win_set_buf(0, shown)
    eq(pcall(utils.create_scratch_buffer, dir .. '/a.txt', true), false, 'fails')
    eq(vim.api.nvim_buf_is_valid(shown), true, 'displayed buffer kept')
    eq(vim.api.nvim_buf_get_lines(edited, 0, -1, false), { 'work' }, 'modified buffer kept')
    eq(#vim.api.nvim_list_bufs(), nbufs + 2, 'no buffer leaked')
end)

test('drop_buffers_of_missing_files drops unmodified buffers of deleted files', function()
    vim.fn.writefile({ 'g' }, dir .. '/gone.txt')
    vim.fn.writefile({ 'e' }, dir .. '/edited.txt')
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/gone.txt'))
    local gone = vim.api.nvim_get_current_buf()
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/edited.txt'))
    local edited = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(edited, 0, -1, false, { 'unsaved' })
    edit('a.txt')
    local a = vim.api.nvim_get_current_buf()
    vim.fn.delete(dir .. '/gone.txt')
    vim.fn.delete(dir .. '/edited.txt')
    -- Through the directory symlink, as a VCS might spell it
    utils.drop_buffers_of_missing_files({ dir .. '/linkdir/gone.txt', dir .. '/edited.txt', dir .. '/a.txt', '' })
    eq(vim.api.nvim_buf_is_valid(gone), false, 'deleted file buffer dropped')
    eq(vim.api.nvim_buf_get_lines(edited, 0, -1, false), { 'unsaved' }, 'modified buffer kept')
    eq(vim.api.nvim_buf_is_loaded(a), true, 'existing file buffer kept')
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
