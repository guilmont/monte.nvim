-- Regression tests for lua/custom/perforce.lua (the Perforce changelist window).
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/perforce_test.lua
--
-- Uses a fake `p4` shell script (written to a temp dir and put first on PATH), so
-- no Perforce server is needed. Needs a POSIX shell. Exits with status 1 on failure.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)

-- ============================================================================
-- Fake p4 and fixtures
-- ============================================================================

local dir = vim.fn.resolve(vim.fn.tempname())
local root = dir .. '/ws'
vim.fn.mkdir(root .. '/src', 'p')
vim.fn.mkdir(dir .. '/bin', 'p')
vim.fn.writefile({ 'one', 'TWO', 'three' }, root .. '/src/a.c')

-- FAKE_P4_MODE=ws: one pending CL with one edited file
-- FAKE_P4_MODE=noclient: server reachable, but not inside a client workspace
-- FAKE_P4_MODE=noserver: every command fails to connect
local fake_p4 = dir .. '/bin/p4'
vim.fn.writefile(vim.split(([[
#!/bin/sh
ROOT='@ROOT@'
case "$FAKE_P4_MODE" in
  noserver)
    echo "Perforce client error:" >&2
    echo "	Connect to server failed; check \$P4PORT." >&2
    exit 1 ;;
  noclient)
    case "$*" in
      info) printf 'Client name: myhost\nClient unknown.\n' ;;
      "changes -s pending -c"*) ;;
      opened) echo "File(s) not opened on this client." >&2 ;;
      *) echo "Client 'myhost' unknown." >&2; exit 1 ;;
    esac
    exit 0 ;;
esac
case "$*" in
  info) printf 'Client name: fakeclient\nClient root: %s\n' "$ROOT" ;;
  "changes -s pending -c"*) echo "Change 123 on 2026/10/15 by me@fakeclient *pending* 'Fix things'" ;;
  "describe -s -S"*) printf 'Change 123 by me@fakeclient on 2026/10/15 *pending*\n\n\tFix things\n\nAffected files ...\n\n' ;;
  opened) echo "//depot/src/a.c#3 - edit change 123 (text)" ;;
  "-ztag where"*) printf '... depotFile //depot/src/a.c\n... path %s/src/a.c\n' "$ROOT" ;;
  "-ztag fstat"*) printf '... depotFile //depot/src/a.c\n... haveRev 3\n... headRev 3\n' ;;
  fstat*) printf '... depotFile //depot/src/a.c\n... haveRev 3\n... action edit\n' ;;
  "print -q"*) printf 'one\ntwo\nthree\n' ;;
  *) echo "fake p4: unhandled: $*" >&2; exit 1 ;;
esac
]]):gsub('@ROOT@', root), '\n'), fake_p4)
vim.fn.setfperm(fake_p4, 'rwxr-xr-x')
vim.env.PATH = dir .. '/bin:' .. vim.env.PATH

local utils = require('custom.utils')
require('custom.perforce')

-- ============================================================================
-- Helpers
-- ============================================================================

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) end

local function keys(k)
    vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes(k, true, false, true), 'x', false)
    vim.wait(100) -- some actions run from vim.schedule
end

local function eq(actual, expected, what)
    if not vim.deep_equal(actual, expected) then
        error(string.format('%s: expected %s, got %s', what or 'value',
            vim.inspect(expected), vim.inspect(actual)), 2)
    end
end

local function current_name() return vim.fs.basename(vim.api.nvim_buf_get_name(0)) end

local function goto_line_containing(text)
    for i, l in ipairs(vim.api.nvim_buf_get_lines(0, 0, -1, false)) do
        if l:find(text, 1, true) then
            vim.api.nvim_win_set_cursor(0, { i, 5 })
            return
        end
    end
    error('no line containing ' .. text)
end

-- Fresh state: two windows on real files, no Perforce buffer, fake p4 in `mode`
local function reset(mode)
    vim.env.FAKE_P4_MODE = mode
    notifications = {}
    vim.v.errmsg = ''
    vim.cmd('silent! only')
    vim.cmd('enew')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= vim.api.nvim_get_current_buf() then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    vim.cmd('edit ' .. vim.fn.fnameescape(repo .. '/README.md'))
    vim.cmd('vsplit ' .. vim.fn.fnameescape(repo .. '/init.lua'))
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('no server: clear error, windows and buffers untouched', function()
    reset('noserver')
    vim.cmd('P4Window')
    eq(#vim.api.nvim_list_wins(), 2, 'window count')
    eq(utils.find_buffer_by_name('Perforce Window'), nil, 'Perforce buffer')
    eq(#notifications, 1, 'notifications')
    eq(notifications[1]:find('Connect to server failed', 1, true) ~= nil, true, 'message mentions the p4 error')
end)

test('outside a client workspace: clear error, windows and buffers untouched', function()
    reset('noclient')
    vim.cmd('P4Window')
    eq(#vim.api.nvim_list_wins(), 2, 'window count')
    eq(utils.find_buffer_by_name('Perforce Window'), nil, 'Perforce buffer')
    eq(notifications, { 'Perforce: not inside a Perforce client workspace (p4 info reports no client root)' }, 'notifications')
end)

test('window lists the opened file and d opens its diff', function()
    reset('ws')
    vim.cmd('P4Window')
    eq(current_name(), 'Perforce Window', 'current buffer')
    goto_line_containing('a.c')
    keys('d')
    eq(vim.v.errmsg, '', 'errors')
    eq(current_name(), 'a.c#3', 'diff base is current')
    keys('Q')
    eq(current_name(), 'Perforce Window', 'back to the Perforce window after Q')
end)

test('actions work when another buffer has the same name', function()
    reset('ws')
    -- A same-named buffer from another directory, created before the real one
    local other = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(other, dir .. '/elsewhere/Perforce Window')
    vim.cmd('P4Window')
    goto_line_containing('a.c')
    keys('d')
    eq(vim.v.errmsg, '', 'errors')
    eq(current_name(), 'a.c#3', 'diff base is current')
end)

test('reopening keeps the cursor position when the window is recreated', function()
    reset('ws')
    vim.cmd('P4Window')
    goto_line_containing('a.c')
    local before = vim.api.nvim_win_get_cursor(0)
    -- Another window to the left: P4Window keeps that one and closes the Perforce window
    vim.cmd('leftabove vsplit ' .. vim.fn.fnameescape(repo .. '/README.md'))
    vim.cmd('P4Window')
    eq(current_name(), 'Perforce Window', 'current buffer')
    eq(vim.api.nvim_win_get_cursor(0), before, 'cursor')
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

vim.fn.delete(dir, 'rf')
io.stdout:write(string.format('\n%d passed, %d failed\n', #tests - failed, failed))
os.exit(failed > 0 and 1 or 0)
