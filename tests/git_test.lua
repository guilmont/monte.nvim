-- Regression tests for lua/custom/git.lua (the Git review window).
--
-- Usage (from the repo root):
--   nvim --headless -u NONE -l tests/git_test.lua
--
-- Creates throwaway git repositories in a temp dir, with HOME pointed there so
-- the user's git config doesn't apply. A fake `lazygit` shell script is put
-- first on PATH. Needs git and a POSIX shell. Exits with status 1 on failure.

local repo = vim.fs.dirname(vim.fs.dirname(vim.fs.normalize(debug.getinfo(1, 'S').source:sub(2))))
vim.opt.rtp:prepend(repo)

-- ============================================================================
-- Fixtures
-- ============================================================================

local dir = vim.fn.resolve(vim.fn.tempname())
vim.fn.mkdir(dir .. '/home', 'p')
vim.fn.mkdir(dir .. '/bin', 'p')
vim.env.HOME = dir .. '/home'
vim.env.XDG_CONFIG_HOME = dir .. '/home/.config'
vim.env.GIT_CONFIG_NOSYSTEM = '1'

-- Fake lazygit: records the directory it was started in, then exits
local lazygit_log = dir .. '/lazygit.log'
local fake_lazygit = dir .. '/bin/lazygit'
vim.fn.writefile({ '#!/bin/sh', 'pwd > "' .. lazygit_log .. '"' }, fake_lazygit)
vim.fn.setfperm(fake_lazygit, 'rwxr-xr-x')
vim.env.PATH = dir .. '/bin:' .. vim.env.PATH

-- Run git in `cwd` and return stdout; errors on a non-zero exit
local function git(cwd, ...)
    local result = vim.system({ 'git', '-C', cwd, ... }):wait()
    if result.code ~= 0 then
        error('git ' .. table.concat({ ... }, ' ') .. ' failed: ' .. result.stderr, 2)
    end
    return result.stdout
end

local repo_count = 0
-- A new repository holding `files` (name -> content), committed unless `no_commit`
local function make_repo(files, no_commit)
    repo_count = repo_count + 1
    local root = dir .. '/repo' .. repo_count
    vim.fn.mkdir(root, 'p')
    git(root, 'init', '-q')
    git(root, 'config', 'user.name', 'Test')
    git(root, 'config', 'user.email', 'test@example.com')
    for name, content in pairs(files or {}) do
        vim.fn.writefile({ content }, root .. '/' .. name)
    end
    if not no_commit then
        git(root, 'add', '-A')
        git(root, 'commit', '-q', '--allow-empty', '-m', 'init')
    end
    return root
end

-- `git status` as a sorted list of "XY path" entries (renames as "XY new <- old")
local function status(root)
    local fields = vim.split(git(root, 'status', '--porcelain=v1', '-z', '-uall'), '\0', { plain = true })
    local entries = {}
    local i = 1
    while i <= #fields do
        if fields[i] ~= '' then
            local entry = fields[i]
            if entry:match('^[RC]') then
                i = i + 1
                entry = entry .. ' <- ' .. fields[i]
            end
            table.insert(entries, entry)
        end
        i = i + 1
    end
    table.sort(entries)
    return entries
end

local utils = require('custom.utils')
require('custom.git')

-- ============================================================================
-- Helpers
-- ============================================================================

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) end

-- Answers given to vim.ui.input prompts, in order
local answers = {}
vim.ui.input = function(_, on_confirm) on_confirm(table.remove(answers, 1)) end

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
    error('no line containing ' .. text .. ' in ' .. vim.inspect(vim.api.nvim_buf_get_lines(0, 0, -1, false)), 2)
end

local function header() return vim.api.nvim_buf_get_lines(0, 0, 1, false)[1] end

local function lazygit_buffer()
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):find('lazygit://', 1, true) then
            return b
        end
    end
end

-- Wait until fake lazygit has run and its buffer is gone; returns its cwd
local function wait_for_lazygit()
    local done = vim.wait(3000, function()
        return vim.fn.filereadable(lazygit_log) == 1 and not lazygit_buffer()
    end, 20)
    eq(done, true, 'lazygit ran and exited')
    vim.wait(50)
    return vim.fn.readfile(lazygit_log)[1]
end

-- Fresh state: one window on an empty buffer, no other buffers, cwd = `cwd`
local function reset(cwd)
    notifications = {}
    answers = {}
    vim.v.errmsg = ''
    vim.fn.delete(lazygit_log)
    vim.cmd('silent! only')
    vim.cmd('enew')
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if b ~= vim.api.nvim_get_current_buf() then
            pcall(vim.api.nvim_buf_delete, b, { force = true })
        end
    end
    vim.fn.chdir(cwd or dir)
end

-- ============================================================================
-- Tests
-- ============================================================================

local tests = {}
local function test(name, fn) table.insert(tests, { name = name, fn = fn }) end

test('actions act on the repository the window shows, not the cwd', function()
    local a = make_repo({ ['a.txt'] = 'a' })
    local b = make_repo({ ['b.txt'] = 'b' })
    vim.fn.writefile({ 'changed' }, a .. '/a.txt')
    vim.fn.writefile({ 'changed' }, b .. '/b.txt')
    reset(a)
    vim.cmd('edit ' .. vim.fn.fnameescape(b .. '/b.txt'))
    vim.cmd('GitWindow')
    eq(header(), 'Git Review: ' .. b, 'header')
    keys('a')
    eq(vim.v.errmsg, '', 'errors')
    eq(header(), 'Git Review: ' .. b, 'header after refresh')
    eq(status(b), { 'M  b.txt' }, 'shown repo staged')
    eq(status(a), { ' M a.txt' }, 'cwd repo untouched by a')
    keys('L')
    eq(wait_for_lazygit(), b, 'lazygit directory')
    vim.cmd('GitWindow')
    eq(header(), 'Git Review: ' .. b, 'header after lazygit')
    answers = { 'y' }
    keys('D')
    eq(status(b), {}, 'shown repo discarded')
    eq(status(a), { ' M a.txt' }, 'cwd repo untouched by D')
end)

test('r on a staged rename restores the original file', function()
    local root = make_repo({ ['old.txt'] = 'content' })
    git(root, 'mv', 'old.txt', 'new.txt')
    reset(root)
    vim.cmd('GitWindow')
    goto_line_containing('new.txt')
    answers = { 'y' }
    keys('r')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), {}, 'status')
    eq(vim.fn.readfile(root .. '/old.txt'), { 'content' }, 'old.txt')
end)

test('s on a staged rename unstages both sides', function()
    local root = make_repo({ ['old.txt'] = 'content' })
    git(root, 'mv', 'old.txt', 'new.txt')
    reset(root)
    vim.cmd('GitWindow')
    goto_line_containing('new.txt')
    keys('s')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), { ' D old.txt', '?? new.txt' }, 'status')
end)

test('g is free for gg/gj/gk; L opens lazygit', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    reset(root)
    vim.cmd('GitWindow')
    local last = vim.api.nvim_buf_line_count(0)
    eq(vim.api.nvim_buf_get_lines(0, last - 1, last, false)[1]:find('L=lazygit', 1, true) ~= nil, true, 'help line')
    vim.api.nvim_win_set_cursor(0, { last, 0 })
    keys('gg')
    eq(current_name(), 'Git Window', 'still in the Git window')
    eq(vim.api.nvim_win_get_cursor(0)[1], 1, 'gg moved to the top')
    eq(vim.fn.filereadable(lazygit_log), 0, 'lazygit not started by gg')
end)

test('paths that git would quote are shown and acted on verbatim', function()
    local names = { 'café.txt', 'a "q".txt', 'back\\slash.txt', 'tab\there.txt', 'x -> y.txt' }
    local root = make_repo({ ['tracked.txt'] = 't' })
    for _, name in ipairs(names) do
        vim.fn.writefile({ name }, root .. '/' .. name)
    end
    reset(root)
    vim.cmd('GitWindow')
    for _, name in ipairs(names) do
        goto_line_containing('] ' .. name)
        keys('s')
        eq(vim.v.errmsg, '', 'errors staging ' .. name)
    end
    local expected = {}
    for _, name in ipairs(names) do table.insert(expected, 'A  ' .. name) end
    table.sort(expected)
    eq(status(root), expected, 'status')
    goto_line_containing('] café.txt')
    keys('<CR>')
    eq(vim.api.nvim_buf_get_name(0), root .. '/café.txt', 'Enter opens the file')
end)

test(':GitDiff on a staged rename diffs against the original at HEAD', function()
    local root = make_repo({ ['old.txt'] = 'content' })
    git(root, 'mv', 'old.txt', 'new.txt')
    vim.fn.writefile({ 'content', 'more' }, root .. '/new.txt')
    reset(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/new.txt'))
    vim.cmd('GitDiff')
    eq(vim.v.errmsg, '', 'errors')
    local base
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):find('Git HEAD:old.txt', 1, true) then base = b end
    end
    eq(base ~= nil, true, 'base buffer named after the rename origin')
    eq(vim.api.nvim_buf_get_lines(base, 0, -1, false), { 'content' }, 'base content')
end)

test('s unstages a file in a repository without commits', function()
    local root = make_repo({ ['f.txt'] = 'f' }, true)
    git(root, 'add', 'f.txt')
    reset(root)
    vim.cmd('GitWindow')
    goto_line_containing('f.txt')
    keys('s')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), { '?? f.txt' }, 'status')
end)

test('D discards everything in a repository without commits', function()
    local root = make_repo({ ['staged.txt'] = 's' }, true)
    git(root, 'add', 'staged.txt')
    vim.fn.writefile({ 'u' }, root .. '/untracked.txt')
    reset(root)
    vim.cmd('GitWindow')
    answers = { 'y' }
    keys('D')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), {}, 'status')
end)

test('answering no to r and D changes nothing', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    vim.fn.writefile({ 'u' }, root .. '/u.txt')
    reset(root)
    vim.cmd('GitWindow')
    goto_line_containing('a.txt')
    answers = { 'n' }
    keys('r')
    goto_line_containing('u.txt')
    answers = { '' }
    keys('r')
    answers = { 'N' }
    keys('D')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), { ' M a.txt', '?? u.txt' }, 'status')
    goto_line_containing('a.txt')
    answers = { 'Y' }
    keys('r')
    eq(status(root), { '?? u.txt' }, 'status after yes')
end)

test('actions use the cursor of the current window', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    reset(root)
    vim.cmd('GitWindow')
    vim.api.nvim_win_set_cursor(0, { 1, 0 })
    vim.cmd('rightbelow vsplit')
    goto_line_containing('a.txt')
    keys('s')
    eq(vim.v.errmsg, '', 'errors')
    eq(status(root), { 'M  a.txt' }, 'status')
end)

test('quitting lazygit restores the buffer in the split it ran in', function()
    local root = make_repo({ ['a.txt'] = 'a', ['b.txt'] = 'b' })
    reset(root)
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/a.txt'))
    vim.cmd('vsplit ' .. vim.fn.fnameescape(root .. '/b.txt'))
    local win = vim.api.nvim_get_current_win()
    vim.cmd('GitLazyGit')
    eq(wait_for_lazygit(), root, 'lazygit directory')
    eq(#vim.api.nvim_list_wins(), 2, 'window count')
    eq(vim.api.nvim_win_is_valid(win) and vim.api.nvim_win_get_buf(win) == vim.fn.bufnr(root .. '/b.txt'), true,
        'b.txt back in its window')
end)

test('git errors are reported and the window still refreshes', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    vim.fn.writefile({ 'u' }, root .. '/u.txt')
    reset(root)
    vim.cmd('GitWindow')
    vim.fn.writefile({}, root .. '/.git/index.lock')
    goto_line_containing('a.txt')
    answers = { 'y' }
    keys('r')
    eq(vim.v.errmsg, '', 'errors from r')
    eq(notifications[#notifications]:find('index.lock', 1, true) ~= nil, true, 'r reports the git error')
    answers = { 'y' }
    keys('D')
    eq(vim.v.errmsg, '', 'errors from D')
    eq(notifications[#notifications]:find('index.lock', 1, true) ~= nil, true, 'D reports the git error')
    for _, k in ipairs({ 's', 'a', 'A' }) do
        keys(k)
        eq(vim.v.errmsg, '', 'errors from ' .. k)
    end
    eq(current_name(), 'Git Window', 'Git window still shown')
    vim.fn.delete(root .. '/.git/index.lock')
    eq(status(root), { ' M a.txt', '?? u.txt' }, 'nothing was half-discarded')
end)

test('commands from a terminal buffer fall back to the cwd', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    reset(root)
    vim.cmd('enew')
    vim.fn.termopen({ 'sh', '-c', 'sleep 10' })
    vim.cmd('GitDiff')
    eq(vim.v.errmsg, '', 'errors from GitDiff')
    vim.cmd('GitLazyGit')
    eq(vim.v.errmsg, '', 'errors from GitLazyGit')
    eq(wait_for_lazygit(), root, 'lazygit directory')
    vim.cmd('enew')
    vim.fn.termopen({ 'sh', '-c', 'sleep 10' })
    vim.cmd('GitWindow')
    eq(vim.v.errmsg, '', 'errors from GitWindow')
    eq(header(), 'Git Review: ' .. root, 'header')
end)

test('outside a repository: clear error, windows untouched', function()
    reset(dir)
    vim.cmd('edit ' .. vim.fn.fnameescape(dir .. '/lazygit.txt'))
    vim.cmd('GitWindow')
    eq(vim.v.errmsg, '', 'errors')
    eq(utils.find_buffer_by_name('Git Window'), nil, 'Git buffer')
    eq(#notifications, 1, 'notifications')
    eq(notifications[1]:find('not a git repository', 1, true) ~= nil, true, 'message mentions the git error')
end)

test('commit messages are passed verbatim', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    git(root, 'add', 'a.txt')
    reset(root)
    vim.cmd('GitWindow')
    local message = [[100% "done" for $HOME and %PATH% `x` 'y' \n !]]
    answers = { message }
    keys('c')
    eq(vim.v.errmsg, '', 'errors')
    eq(git(root, 'log', '-1', '--format=%B'), message .. '\n\n', 'commit message')
    eq(header(), 'Git Review: ' .. root, 'refreshed')
    eq(status(root), {}, 'status')
end)

test('buffers of files that r and D delete are dropped, others kept', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    vim.fn.writefile({ 'u' }, root .. '/u.txt')
    vim.fn.writefile({ 'n' }, root .. '/new.txt')
    git(root, 'add', 'new.txt')
    reset(root)
    for _, name in ipairs({ 'a.txt', 'u.txt', 'new.txt' }) do
        vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/' .. name))
    end
    vim.cmd('GitWindow')
    goto_line_containing('u.txt')
    answers = { 'y' }
    keys('r')
    goto_line_containing('new.txt')
    answers = { 'y' }
    keys('r')
    eq(vim.v.errmsg, '', 'errors from r')
    eq(status(root), {}, 'status after r')
    eq(vim.fn.bufexists(root .. '/u.txt'), 0, 'buffer of the deleted untracked file')
    eq(vim.fn.bufexists(root .. '/new.txt'), 0, 'buffer of the restored (removed) staged add')
    eq(vim.fn.bufexists(root .. '/a.txt'), 1, 'buffer of an untouched file')

    vim.fn.writefile({ 'n' }, root .. '/new.txt')
    git(root, 'add', 'new.txt')
    vim.fn.writefile({ 'u2' }, root .. '/u2.txt')
    vim.fn.writefile({ 'u3' }, root .. '/u3.txt')
    vim.fn.writefile({ 'changed' }, root .. '/a.txt')
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/new.txt'))
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/u3.txt'))
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/u2.txt'))
    vim.api.nvim_buf_set_lines(0, 0, -1, false, { 'unsaved' })
    vim.cmd('GitWindow')
    answers = { 'y' }
    keys('D')
    eq(vim.v.errmsg, '', 'errors from D')
    eq(status(root), {}, 'status after D')
    eq(vim.fn.bufexists(root .. '/new.txt'), 0, 'buffer of the removed staged add')
    eq(vim.fn.bufexists(root .. '/u3.txt'), 0, 'buffer of a cleaned untracked file')
    eq(vim.fn.bufexists(root .. '/u2.txt'), 1, 'modified buffer of a removed file kept')
    eq(vim.fn.bufexists(root .. '/a.txt'), 1, 'buffer of a restored file')
    vim.bo[vim.fn.bufnr(root .. '/u2.txt')].modified = false
end)

test('d in the Git window diffs a staged rename against the original', function()
    local root = make_repo({ ['old.txt'] = 'content' })
    git(root, 'mv', 'old.txt', 'new.txt')
    reset(root)
    vim.cmd('GitWindow')
    goto_line_containing('new.txt')
    keys('d')
    eq(vim.v.errmsg, '', 'errors')
    local base
    for _, b in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_get_name(b):find('Git HEAD:old.txt', 1, true) then base = b end
    end
    eq(base ~= nil, true, 'base buffer named after the rename origin')
    eq(vim.api.nvim_buf_get_lines(base, 0, -1, false), { 'content' }, 'base content')
end)

test('header, help and clean lines are highlighted', function()
    local root = make_repo({ ['a.txt'] = 'a' })
    reset(root)
    vim.cmd('GitWindow')
    local groups = {}
    for _, mark in ipairs(vim.api.nvim_buf_get_extmarks(0, -1, 0, -1, { details = true })) do
        groups[mark[2] + 1] = mark[4].hl_group
    end
    eq(groups, { 'Title', nil, 'Comment', 'Comment' }, 'highlight groups by line')
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
