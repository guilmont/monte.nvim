-- Regression tests for lua/custom/run.lua (the :Run command runner).
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/run_test.lua
--
-- Runs real shell commands (printf, sleep, seq), so it needs a POSIX shell.
-- Exits with status 1 if any test fails.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)
vim.opt.termguicolors = true
vim.o.columns = 160

local utils = require('custom.utils')
require('custom.run')

-- ============================================================================
-- Fixtures and helpers
-- ============================================================================

local dir = vim.fn.tempname()
vim.fn.mkdir(dir, 'p')
dir = vim.fn.resolve(dir)
-- Lines are long enough that wrong cursor columns aren't hidden by clamping
vim.fn.writefile({ 'line one of foo', 'line two of foo', 'line three of foo' }, dir .. '/foo.c')
vim.fn.writefile({ 'p1', 'p2' }, dir .. '/foo.cpp')
vim.fn.writefile({ 'o1', 'o2' }, dir .. '/other.txt')

local ns = vim.api.nvim_create_namespace('ansi_hl')

local function run_buf() return utils.find_buffer_by_name('[Run Output]') end
local function out_lines() return vim.api.nvim_buf_get_lines(run_buf(), 0, -1, false) end
local function finished() return table.concat(out_lines(), '\n'):find('Process exited') ~= nil end

-- Start a command and wait for it to finish
local function run(cmd)
    vim.cmd('Run ' .. cmd)
    assert(vim.wait(5000, finished), 'command did not finish: ' .. cmd)
    vim.wait(50)
end

local function wait_finished()
    assert(vim.wait(5000, finished), 'command did not finish')
    vim.wait(50)
end

local function focus_run()
    local win = vim.fn.bufwinid(run_buf())
    vim.api.nvim_set_current_win(win)
    return win
end

local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
end

-- Jump to the first location in the output, as a user would with gg]<CR>
local function jump_first()
    focus_run()
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    keys(']<CR>')
end

local function ansi_marks()
    local marks = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(run_buf(), ns, 0, -1, { details = true })) do
        if m[4].hl_group:match('^Ansi') then
            table.insert(marks, { row = m[2], col = m[3], end_col = m[4].end_col, hl = m[4].hl_group })
        end
    end
    return marks
end

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s: expected %s, got %s', what or 'value',
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function current_file() return vim.api.nvim_buf_get_name(0) end
local function cursor() return vim.api.nvim_win_get_cursor(0) end

-- Fresh editor state for each test: one window on other.txt, cwd = fixture dir
local function reset()
    vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    vim.cmd('silent! only')
    vim.cmd('enew')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= vim.api.nvim_get_current_buf() then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/other.txt'))
    vim.v.errmsg = ''
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('find_buffer_by_name matches the name, not substrings', function()
    local buf = utils.create_scratch_buffer('Git Window', false)
    eq(utils.find_buffer_by_name('Git Window'), buf, 'exact name')
    eq(utils.find_buffer_by_name('Window'), nil, 'substring')
end)

test('<CR> opens foo.c, not an already open foo.cpp', function()
    vim.cmd('badd ' .. vim.fn.fnameescape(dir .. '/foo.cpp'))
    run('echo foo.c:2:1')
    jump_first()
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(cursor()[1], 2, 'line')
end)

test('<CR> opens a file whose buffer was :bdelete-d', function()
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/foo.c'))
    vim.cmd('bdelete')
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/other.txt'))
    run('echo foo.c:2:1')
    jump_first()
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(cursor()[1], 2, 'line')
end)

test('column is converted from 1-based to 0-based', function()
    run('echo foo.c:3:2')
    jump_first()
    eq(cursor(), { 3, 1 }, 'cursor')
end)

test('first location on a line wins', function()
    run([[echo 'see foo.c:3 and other.txt:2:2']])
    jump_first()
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(cursor()[1], 3, 'line')
end)

test('MSVC file(line,col) locations', function()
    run([[echo 'C(3) x foo.c(2,2) y']])
    jump_first()
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(cursor(), { 2, 1 }, 'cursor')
end)

test('relative paths resolve against the cwd the command started in', function()
    vim.cmd('Run sleep 0.3; echo foo.c:2:2')
    vim.cmd('cd /')
    wait_finished()
    jump_first()
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(cursor(), { 2, 1 }, 'cursor')
end)

test('<CR> splits to the left when the output is the only window', function()
    run('echo foo.c:3:2')
    focus_run()
    vim.cmd('only')
    jump_first()
    local wins = vim.api.nvim_tabpage_list_wins(0)
    eq(#wins, 2, 'window count')
    eq(vim.api.nvim_get_current_win(), wins[1], 'file window is leftmost')
    eq(current_file(), dir .. '/foo.c', 'file')
    eq(vim.api.nvim_win_get_buf(wins[2]), run_buf(), 'output kept on the right')
end)

test('gg] reaches the first error while output is still arriving', function()
    vim.cmd([[Run for i in 1 2 3 4 5 6; do echo "foo.c:$i: error"; sleep 0.25; done]])
    vim.wait(600)
    local win = focus_run()
    keys('gg')
    vim.wait(300) -- more output arrives between gg and ]
    eq(vim.api.nvim_win_get_cursor(win)[1], 1, 'cursor stays on line 1')
    keys(']')
    eq(vim.api.nvim_get_current_line(), 'foo.c:1: error', 'line after ]')
    wait_finished()
    eq(vim.api.nvim_get_current_line(), 'foo.c:1: error', 'line after finish')
end)

test('output follows the end while the cursor is on the last line', function()
    vim.cmd([[Run for i in 1 2 3; do echo line$i; sleep 0.1; done]])
    wait_finished()
    local win = vim.fn.bufwinid(run_buf())
    eq(vim.api.nvim_win_get_cursor(win)[1], vim.api.nvim_buf_line_count(run_buf()), 'cursor at end')
end)

test('colors survive a line arriving in two flushes', function()
    run([[printf '\033[31mred'; sleep 0.3; printf 'more\033[0m\n']])
    eq(out_lines()[4], 'redmore', 'text')
    eq(ansi_marks(), { { row = 3, col = 0, end_col = 7, hl = 'Ansi_fg_800000' } }, 'highlights')
end)

test('colors survive a colorscheme change', function()
    run([[printf '\033[31mred\033[0m\n']])
    vim.cmd('colorscheme default')
    run([[printf '\033[31mred\033[0m\n']])
    local marks = ansi_marks()
    eq(#marks, 1, 'highlight count')
    eq(next(vim.api.nvim_get_hl(0, { name = marks[1].hl })) ~= nil, true, 'group defined')
end)

test('carriage return overwrite and erase-in-line keep per-char colors', function()
    run([[printf '\033[31mAAAA\033[0m\r\033[32mBB\033[0m\n'; printf 'xyz\033[1K!\n']])
    eq(out_lines()[4], 'BBAA', 'overwritten line')
    eq(out_lines()[5], '   !', 'erased line')
    eq(ansi_marks(), {
        { row = 3, col = 0, end_col = 2, hl = 'Ansi_fg_008000' },
        { row = 3, col = 2, end_col = 4, hl = 'Ansi_fg_800000' },
    }, 'highlights')
end)

test('re-running drops queued output of the previous job', function()
    -- Re-run from a timer (like pressing r) while the old job's output is still queued
    vim.cmd('Run seq 1 200000 | sed s/^/OLDJOB/')
    vim.defer_fn(function() vim.cmd('Run echo NEWJOB') end, 30)
    vim.wait(100)
    wait_finished()
    vim.wait(200)
    eq(table.concat(out_lines(), '\n'):find('OLDJOB'), nil, 'stale output')
    eq(#out_lines(), 8, 'line count')
end)

test(':bdelete of the output buffer during a run', function()
    vim.cmd('Run sleep 0.2; echo after-bd')
    vim.cmd('bdelete! ' .. run_buf())
    vim.wait(600)
    eq(vim.v.errmsg, '', 'errors')
    run('echo fresh')
    eq(out_lines()[4], 'fresh', 'next run output')
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
    -- Let any command still running finish before the next test
    if run_buf() and not finished() then
        vim.cmd('Run true')
        vim.wait(2000, finished)
    end
end

vim.fn.delete(dir, 'rf')
io.stdout:write(string.format('\n%d passed, %d failed\n', #tests - failed, failed))
os.exit(failed > 0 and 1 or 0)
