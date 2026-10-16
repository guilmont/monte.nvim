-- Regression tests for lua/custom/align.lua (the :Align command).
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/align_test.lua
--
-- Exits with status 1 if any test fails.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)

require('custom.align')

-- ============================================================================
-- Helpers
-- ============================================================================

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) end

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s: expected %s, got %s', what or 'value',
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

-- Put `lines` in a fresh buffer, run :Align over all of them, return the result
local function align(lines, pattern)
    vim.cmd('enew!')
    vim.bo.tabstop = 8
    vim.api.nvim_buf_set_lines(0, 0, -1, false, lines)
    vim.cmd('%Align ' .. pattern)
    return vim.api.nvim_buf_get_lines(0, 0, -1, false)
end

-- Display column (0-based) where the first match of `pattern` starts on each line
local function match_cols(lines, pattern)
    local cols = {}
    for i, line in ipairs(lines) do
        cols[i] = vim.fn.strdisplaywidth(line:sub(1, vim.fn.match(line, pattern)))
    end
    return cols
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('aligns plain ASCII lines', function()
    eq(align({ 'a = 1', 'bbb = 2', 'cc=3' }, '='), { 'a   = 1', 'bbb = 2', 'cc  =3' }, 'lines')
end)

test('pads by display width with multibyte characters', function()
    local out = align({ 'é = 1', 'ab = 2', '日本 = 3' }, '=')
    eq(out, { 'é    = 1', 'ab   = 2', '日本 = 3' }, 'lines')
    eq(match_cols(out, '='), { 5, 5, 5 }, 'columns')
end)

test('pads by display width with tabs', function()
    local out = align({ '\tx = 1', 'abcdefghij = 2' }, '=')
    eq(out, { '\tx  = 1', 'abcdefghij = 2' }, 'lines')
    eq(match_cols(out, '='), { 11, 11 }, 'columns')
end)

test('keeps indentation when only whitespace precedes the match', function()
    local out = align({ 'a = b', 'ccc = d', '    = e' }, '=')
    eq(out, { 'a   = b', 'ccc = d', '    = e' }, 'lines')
end)

test('indentation-only line wider than the others sets the column', function()
    local out = align({ 'a = b', '        = c' }, '=')
    eq(out, { 'a       = b', '        = c' }, 'lines')
end)

test('lines without a match are left untouched', function()
    eq(align({ 'a = 1', 'no match here', 'bb = 2' }, '='), { 'a  = 1', 'no match here', 'bb = 2' }, 'lines')
end)

test('invalid pattern reports an error', function()
    notifications = {}
    align({ 'a = 1' }, '\\(')
    eq(#notifications, 1, 'notifications')
end)

-- ============================================================================
-- Runner
-- ============================================================================

local failed = 0
for _, t in ipairs(tests) do
    local ok, err = pcall(t.fn)
    if ok then
        io.stdout:write('PASS  ' .. t.name .. '\n')
    else
        failed = failed + 1
        io.stdout:write('FAIL  ' .. t.name .. '\n      ' .. tostring(err) .. '\n')
    end
end

io.stdout:write(string.format('\n%d passed, %d failed\n', #tests - failed, failed))
os.exit(failed > 0 and 1 or 0)
