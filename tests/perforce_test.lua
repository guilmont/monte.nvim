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
vim.fn.mkdir(dir .. '/out', 'p')
vim.fn.writefile({ 'one', 'TWO', 'three' }, root .. '/src/a.c')

-- Every call is logged to p4.log ("$*", one line). With `p4 -x -` the arguments
-- read from stdin are logged as "< arg" lines and appended to "$@", so the
-- cases below see the same arguments either way. `change -i` input is logged too.
--
-- FAKE_P4_MODE=ws: one pending CL with one edited file
-- FAKE_P4_MODE=noclient: server reachable, but not inside a client workspace
-- FAKE_P4_MODE=noserver: every command fails to connect
-- FAKE_P4_MODE=custom: the workspace written by workspace() below (custom.sh)
local fake_p4 = dir .. '/bin/p4'
vim.fn.writefile(vim.split(([[
#!/bin/sh
ROOT='@ROOT@'
DIR='@DIR@'
printf '%s\n' "$*" >> "$DIR/p4.log"
if [ "$1" = "-x" ] && [ "$2" = "-" ]; then
  cat > "$DIR/stdin"
  awk '{ print "< " $0 }' "$DIR/stdin" >> "$DIR/p4.log"
  shift 2
  # (the last line may have no newline)
  while IFS= read -r arg || [ -n "$arg" ]; do set -- "$@" "$arg"; done < "$DIR/stdin"
fi
if [ "$1 $2" = "change -i" ]; then
  awk '{ print "< " $0 }' >> "$DIR/p4.log"
fi
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
  custom)
    out() { cat "$DIR/out/$1"; }
    # Local path of //depot/<rel>: $ROOT/<rel>, with p4's %XX encoding undone
    to_local() { printf '%s/%s\n' "$ROOT" "${1#//depot/}" | sed -e 's/%40/@/g' -e 's/%23/#/g' -e 's/%2A/*/g' -e 's/%25/%/g'; }
    fstat_fields() { printf '... haveRev 1\n... headRev 1\n'; }
    default_p4() {
      case "$1 $2" in
        "info ") printf 'Client name: fakeclient\nClient root: %s\n' "$ROOT" ;;
        "-ztag where") shift 2
          for p; do printf '... depotFile %s\n... path %s\n\n' "$p" "$(to_local "$p")"; done ;;
        "-ztag fstat") shift 2
          for p; do printf '... depotFile %s\n' "$p"; fstat_fields "$p"; echo; done ;;
        *) case "$1" in
             add|edit|revert|delete|move|shelve|unshelve|sync|reopen|resolve|fix|change)
               echo "$* ok" ;;
             *) echo "fake p4: unhandled: $*" >&2; exit 1 ;;
           esac ;;
      esac
    }
    . "$DIR/custom.sh"
    exit $? ;;
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
]]):gsub('@ROOT@', root):gsub('@DIR@', dir), '\n'), fake_p4)
vim.fn.setfperm(fake_p4, 'rwxr-xr-x')

-- FAKE_DIFF3=conflict: merged output with one conflict (exit 1)
-- FAKE_DIFF3=fail: diff3 trouble (exit 2)
local fake_diff3 = dir .. '/bin/diff3'
vim.fn.writefile(vim.split([[
#!/bin/sh
case "$FAKE_DIFF3" in
  conflict) printf '<<<<<<< LOCAL\nmine\n||||||| ORIGINAL\nbase\n=======\ntheirs\n>>>>>>> INCOMING\n'; exit 1 ;;
  *) echo "diff3: something broke" >&2; exit 2 ;;
esac
]], '\n'), fake_diff3)
vim.fn.setfperm(fake_diff3, 'rwxr-xr-x')
vim.env.PATH = dir .. '/bin:' .. vim.env.PATH

-- Write the FAKE_P4_MODE=custom workspace.
-- cls: list of changelists { cn, desc = {lines}, jobs = {{ id, desc }}, shelved = {paths},
--      files = {{ path, action, rev }} }. cn 'default' only has files. Paths are
--      encoded depot paths relative to //depot/.
-- opts.fstat: shell `case "$1" in` branches printing extra fstat fields of a depot path
-- opts.cases: shell `case "$*" in` branches, tried before the defaults
-- opts.out: extra canned outputs, name -> lines (`out name` prints one)
local function workspace(cls, opts)
    opts = opts or {}
    local changes, describe, opened = {}, {}, {}
    for _, cl in ipairs(cls) do
        if cl.cn ~= 'default' then
            local desc = cl.desc or { 'Change ' .. cl.cn }
            table.insert(changes, string.format("Change %s on 2026/10/15 by me@fakeclient *pending* '%s'", cl.cn, desc[1]))
            vim.list_extend(describe, { 'Change ' .. cl.cn .. ' by me@fakeclient on 2026/10/15 *pending*', '' })
            for _, l in ipairs(desc) do table.insert(describe, '\t' .. l) end
            table.insert(describe, '')
            if cl.jobs then
                vim.list_extend(describe, { 'Jobs fixed ...', '' })
                for _, job in ipairs(cl.jobs) do
                    vim.list_extend(describe, { job.id .. ' on 2026/10/15 by me *open*', '' })
                    if job.desc then vim.list_extend(describe, { '\t' .. job.desc, '' }) end
                end
            end
            if cl.shelved then
                vim.list_extend(describe, { 'Shelved files ...', '' })
                for _, p in ipairs(cl.shelved) do table.insert(describe, '... //depot/' .. p .. '#1 edit') end
                table.insert(describe, '')
            end
            vim.list_extend(describe, { 'Affected files ...', '' })
        end
        for _, f in ipairs(cl.files or {}) do
            table.insert(opened, string.format('//depot/%s#%d - %s %s (text)', f.path, f.rev or 1, f.action or 'edit',
                cl.cn == 'default' and 'default change' or 'change ' .. cl.cn))
        end
    end
    vim.fn.writefile(changes, dir .. '/out/changes')
    vim.fn.writefile(describe, dir .. '/out/describe')
    vim.fn.writefile(opened, dir .. '/out/opened')
    for name, lines in pairs(opts.out or {}) do
        vim.fn.writefile(lines, dir .. '/out/' .. name, 'b')
    end
    local script = {}
    if opts.fstat then
        vim.list_extend(script, { 'fstat_fields() {', '  case "$1" in' })
        vim.list_extend(script, opts.fstat)
        vim.list_extend(script, { [[    *) printf '... haveRev 1\n... headRev 1\n' ;;]], '  esac', '}' })
    end
    vim.list_extend(script, {
        'case "$*" in',
        '  "changes -s pending -c"*) out changes ;;',
        '  "describe -s -S"*) out describe ;;',
        '  opened) out opened ;;',
    })
    vim.list_extend(script, opts.cases or {})
    vim.list_extend(script, { '  *) default_p4 "$@" ;;', 'esac' })
    vim.fn.writefile(script, dir .. '/custom.sh')
end

local utils = require('custom.utils')
require('custom.perforce')

-- ============================================================================
-- Helpers
-- ============================================================================

local notifications = {}
vim.notify = function(msg) table.insert(notifications, msg) end

-- vim.ui.input answers 'y' unless `input_answer` says otherwise; prompts are recorded
local prompts = {}
local input_answer = 'y'
vim.ui.input = function(opts, on_confirm)
    table.insert(prompts, opts.prompt)
    on_confirm(input_answer)
end
-- vim.ui.select picks the first item containing `select_choice`
local select_choice = nil
vim.ui.select = function(items, _, on_choice)
    for _, item in ipairs(items) do
        if select_choice and item:find(select_choice, 1, true) then return on_choice(item) end
    end
    on_choice(nil)
end

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
local function buf_lines(buf) return vim.api.nvim_buf_get_lines(buf or 0, 0, -1, false) end

local function line_containing(text)
    for i, l in ipairs(buf_lines()) do
        if l:find(text, 1, true) then return i end
    end
    error('no line containing ' .. text, 2)
end

local function goto_line_containing(text)
    vim.api.nvim_win_set_cursor(0, { line_containing(text), 5 })
end

-- Lines of the `Files` header of changelist `cn` in the Perforce window
local function files_header_line(cn)
    local cl = line_containing('CL ' .. cn .. ' :')
    for i, l in ipairs(buf_lines()) do
        if i > cl and l:match('^  Files') then return i end
    end
    error('no Files header for CL ' .. cn, 2)
end

-- Expand the shelf on the line containing `text` (expansion is kept between tests)
local function expand_shelf(text)
    goto_line_containing(text)
    if vim.api.nvim_get_current_line():find('▶', 1, true) then keys('<CR>') end
end

-- Select lines first..last linewise and press `key`
local function visual(first, last, key)
    keys(first .. 'GV' .. last .. 'G' .. key)
end

local function p4_log()
    return vim.fn.filereadable(dir .. '/p4.log') == 1 and vim.fn.readfile(dir .. '/p4.log') or {}
end

-- The logged p4 commands that change something (not the queries that build the window).
-- A batched call shows its stdin arguments: '-x - revert < //depot/a.c < //depot/b.c'.
local function actions()
    local result = {}
    local batched = false
    for _, l in ipairs(p4_log()) do
        if l:match('^< ') then
            if batched then result[#result] = result[#result] .. ' ' .. l end
        elseif l == 'info' or l == 'opened' or l:match('^changes ') or l:match('^describe ')
                or l:match('^%-x %- %-ztag ') or l:match('^%-ztag where ') or l:match('^%-ztag fstat //') then
            batched = false
        else
            table.insert(result, l)
            batched = l:match('^%-x %- ') ~= nil
        end
    end
    return result
end

local function notified(text)
    for _, n in ipairs(notifications) do
        if n:find(text, 1, true) then return true end
    end
    return false
end

-- Highlight groups of buffer line `lnum` in the Perforce window's namespace
local function hl_groups(lnum)
    local ns = vim.api.nvim_create_namespace('P4Highlight')
    local groups = {}
    for _, m in ipairs(vim.api.nvim_buf_get_extmarks(0, ns, { lnum - 1, 0 }, { lnum - 1, -1 }, { details = true })) do
        groups[m[4].hl_group] = true
    end
    return groups
end

-- Fresh state: two windows on real files, no Perforce buffer, fake p4 in `mode`
local function reset(mode)
    vim.env.FAKE_P4_MODE = mode
    notifications = {}
    prompts = {}
    input_answer = 'y'
    select_choice = nil
    vim.fn.delete(dir .. '/p4.log')
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

-- reset('custom') with the given workspace, then open the Perforce window
local function open_workspace(cls, opts)
    reset('custom')
    workspace(cls, opts)
    vim.cmd('P4Window')
    eq(current_name(), 'Perforce Window', 'current buffer')
    vim.fn.delete(dir .. '/p4.log')
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

-- Parsing ---------------------------------------------------------------------

test('a default-CL file whose path contains "change <N>" is listed', function()
    open_workspace({ { cn = 'default', files = { { path = 'exchange 7.txt' } } } })
    local file = line_containing('exchange 7.txt')
    eq(line_containing('CL default :') < file, true, 'listed under the default CL')
end)

test('depot paths with an encoded # are parsed whole', function()
    open_workspace({ { cn = '100', shelved = { 's%23t.c' }, files = { { path = 'a%23b.c' } } } })
    eq(buf_lines()[line_containing('a#b.c')], '    edit            a#b.c', 'opened file line')
    expand_shelf('Shelf')
    line_containing('//depot/s#t.c')
end)

test('descriptions are shown verbatim and the spec round-trips through change -i', function()
    open_workspace({ { cn = '100', desc = { 'Fix 100%25 bug' }, files = { { path = 'a%40b.c' } } } }, {
        cases = { '  "change -o 100") out change ;;' },
        out = { change = { 'Change:\t100', '', 'Description:', '\tFix 100%25 bug', '', 'Files:', '\t//depot/a%40b.c\t# edit' } },
    })
    line_containing('  Fix 100%25 bug')
    goto_line_containing('Fix 100')
    keys('<CR>')
    eq(current_name(), 'P4-Change-100', 'edit buffer')
    line_containing('\tFix 100%25 bug')
    line_containing('\t//depot/a%40b.c\t# edit')
    keys('w')
    eq(vim.v.errmsg, '', 'errors')
    local log = p4_log()
    eq(vim.tbl_contains(log, '< \tFix 100%25 bug'), true, 'description sent unchanged')
    eq(vim.tbl_contains(log, '< \t//depot/a%40b.c\t# edit'), true, 'depot path sent encoded')
end)

test('editing a description again without q reuses the buffer name', function()
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' } } } }, {
        cases = { '  "change -o"*) out change ;;' },
        out = { change = { 'Change:\t100', '', 'Description:', '\tChange 100' } },
    })
    goto_line_containing('Change 100')
    keys('<CR>')
    eq(current_name(), 'P4-Change-100', 'edit buffer')
    vim.cmd('P4Window')    -- leave without q
    goto_line_containing('Change 100')
    keys('<CR>')
    eq(vim.v.errmsg, '', 'errors')
    eq(current_name(), 'P4-Change-100', 'edit buffer again')
    vim.cmd('P4Window')
    keys('n')
    vim.cmd('P4Window')
    keys('n')
    eq(vim.v.errmsg, '', 'errors')
    eq(current_name(), 'P4-Change-new', 'new changelist buffer again')
end)

test('editing a description that is still shown goes back to it, keeping its edits', function()
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' } } } }, {
        cases = { '  "change -o"*) out change ;;' },
        out = { change = { 'Change:\t100', '', 'Description:', '\tChange 100' } },
    })
    goto_line_containing('Change 100')
    keys('<CR>')
    local edit_buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(edit_buf, -1, -1, false, { '\tmore' })
    vim.cmd('tab split')    -- the first tab keeps showing it
    vim.cmd('P4Window')
    goto_line_containing('Change 100')
    keys('<CR>')
    local current, lines = vim.api.nvim_get_current_buf(), buf_lines()
    vim.cmd('tabonly')
    eq(vim.v.errmsg, '', 'errors')
    eq(current, edit_buf, 'same edit buffer')
    eq(lines[#lines], '\tmore', 'edits kept')
end)

test('local paths from p4 where are not URL-decoded', function()
    open_workspace({ { cn = '100', files = { { path = 'report%2520v2.txt' } } } })
    line_containing('report%20v2.txt')
end)

test('where and fstat get the depot paths on stdin, not on the command line', function()
    local files = {}
    for i = 1, 150 do table.insert(files, { path = string.format('src/some/long/directory/name/file%03d.c', i) }) end
    reset('custom')
    workspace({ { cn = '100', files = files } })
    vim.cmd('P4Window')
    line_containing('file150.c')
    local log = p4_log()
    local stdin_lines = 0
    for _, l in ipairs(log) do
        eq(#l < 200, true, 'command line length')
        if l:match('^< //depot/') then stdin_lines = stdin_lines + 1 end
    end
    eq(vim.tbl_contains(log, '-x - -ztag where'), true, 'where reads stdin')
    eq(vim.tbl_contains(log, '-x - -ztag fstat'), true, 'fstat reads stdin')
    eq(stdin_lines, 300, 'paths on stdin')
end)

test('blank lines inside a description are kept', function()
    open_workspace({ { cn = '100', desc = { 'First', '', 'Third' }, files = { { path = 'src/a.c' } } } })
    local cl = line_containing('CL 100 :')
    eq({ unpack(buf_lines(), cl + 1, cl + 3) }, { '  First', '  ', '  Third' }, 'description lines')
end)

-- File commands -----------------------------------------------------------------

test(':P4Revert on a modified buffer reloads it', function()
    reset('custom')
    workspace({})
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/src/a.c'))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved' })
    local ok, err = pcall(vim.cmd, 'P4Revert')
    eq(ok, true, 'no error: ' .. tostring(err))
    eq(vim.bo.modified, false, 'modified')
    eq(buf_lines(), { 'one', 'TWO', 'three' }, 'reloaded from disk')
    eq(actions(), { 'revert ' .. root .. '/src/a.c' }, 'p4 commands')
end)

test(':P4Add passes names literally, with -f when they contain @#%*', function()
    reset('custom')
    workspace({})
    vim.fn.writefile({}, root .. '/src/x@1.c')
    vim.fn.writefile({}, root .. '/src/plain.c')
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/src/x@1.c'))
    vim.cmd('P4Add')
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/src/plain.c'))
    vim.cmd('P4Add')
    eq(actions(), { 'add -f ' .. root .. '/src/x@1.c', 'add ' .. root .. '/src/plain.c' }, 'p4 commands')
end)

test(':P4Rename refuses a buffer with unsaved changes', function()
    reset('custom')
    workspace({})
    vim.cmd('edit ' .. vim.fn.fnameescape(root .. '/src/a.c'))
    vim.api.nvim_buf_set_lines(0, 0, 1, false, { 'unsaved' })
    input_answer = root .. '/src/renamed.c'
    vim.cmd('P4Rename')
    eq(actions(), {}, 'p4 commands')
    eq(current_name(), 'a.c', 'current buffer')
    eq(buf_lines()[1], 'unsaved', 'unsaved change kept')
    eq(notified('unsaved changes'), true, 'notified')
end)

-- Ranges and errors -------------------------------------------------------------

local two_cls = {
    { cn = '100', shelved = { 'src/s1.c' }, files = { { path = 'src/a.c' } } },
    { cn = '200', shelved = { 'src/s2.c', 'src/s3.c' }, files = { { path = 'src/b.c' }, { path = 'src/c.c' } } },
}

test('r on a range across changelists reverts the selected files, not a whole CL', function()
    open_workspace(two_cls)
    visual(line_containing('src/a.c'), files_header_line('200'), 'r')
    eq(prompts, { 'Revert 3 file(s)? (y/N): ' }, 'prompts')
    eq(actions(), { '-x - revert < //depot/src/a.c < //depot/src/b.c < //depot/src/c.c' }, 'p4 commands')
end)

test('r on a single Files header still reverts the whole changelist', function()
    open_workspace(two_cls)
    vim.api.nvim_win_set_cursor(0, { files_header_line('200'), 0 })
    keys('r')
    eq(actions(), { 'revert -c 200 //...' }, 'p4 commands')
end)

test('s on a range across changelists shelves the selected files', function()
    open_workspace(two_cls)
    -- The range includes CL 200's Files header, which stands for all its files
    visual(line_containing('src/a.c'), line_containing('src/b.c'), 's')
    eq(actions(), {
        '-x - shelve -f -c 100 < //depot/src/a.c', '-x - shelve -f -c 200 < //depot/src/b.c < //depot/src/c.c',
    }, 'p4 commands')
end)

test('u on a range unshelves the selected shelved files', function()
    open_workspace(two_cls)
    expand_shelf('Shelf (1 file)')
    vim.fn.delete(dir .. '/p4.log')
    local shelf200 = line_containing('Shelf (2 files)')
    visual(line_containing('//depot/src/s1.c'), shelf200, 'u')
    eq(actions(), {
        '-x - unshelve -s 100 -c 100 < //depot/src/s1.c',
        '-x - unshelve -s 200 -c 200 < //depot/src/s2.c < //depot/src/s3.c',
    }, 'p4 commands')
end)

test('a failing revert is reported, the others still run and the window refreshes', function()
    -- Like p4 -x -: the failing path is reported, the others are still reverted
    open_workspace(two_cls, {
        cases = { [[  "revert "*a.c*) echo "a.c - file(s) not opened on this client." >&2; echo "//depot/src/b.c#1 - was edit, reverted"; exit 1 ;;]] },
    })
    visual(line_containing('src/a.c'), line_containing('src/b.c'), 'r')
    eq(notified('a.c - file(s) not opened on this client.'), true, 'error notified')
    eq(actions(), { '-x - revert < //depot/src/a.c < //depot/src/b.c < //depot/src/c.c' }, 'one call for all files')
    eq(vim.tbl_contains(p4_log(), 'opened'), true, 'window refreshed')
end)

test('S on a Files header syncs past a failure and reports it', function()
    open_workspace(two_cls, {
        cases = { '  "sync "*b.c*) echo "b.c - no such file(s)." >&2; echo "//depot/src/c.c#1 - updating"; exit 1 ;;' },
    })
    vim.api.nvim_win_set_cursor(0, { files_header_line('200'), 0 })
    keys('S')
    eq(actions(), { '-x - sync < //depot/src/b.c < //depot/src/c.c' }, 'p4 commands')
    eq(notified('b.c - no such file(s).'), true, 'error notified')
    eq(vim.tbl_contains(p4_log(), 'opened'), true, 'window refreshed')
end)

test('deleting a changelist stops at the first failure and refreshes', function()
    open_workspace(two_cls, {
        cases = { '  "revert -c 200 //...") echo "revert failed" >&2; exit 1 ;;' },
    })
    goto_line_containing('CL 200 :')
    keys('D')
    eq(actions(), { 'revert -c 200 //...' }, 'p4 commands')
    eq(notified('revert failed'), true, 'error notified')
    eq(vim.tbl_contains(p4_log(), 'opened'), true, 'window refreshed')
end)

-- D on opened files -------------------------------------------------------------

local d_cls = {
    { cn = 'default', files = { { path = 'src/d.c' } } },
    { cn = '100', files = {
        { path = 'src/a.c' },
        { path = 'src/new.c', action = 'add' },
        { path = 'src/moved.c', action = 'move/add' },
        { path = 'src/old.c', action = 'move/delete' },
        { path = 'src/gone.c', action = 'delete' },
    } },
}
local d_opts = {
    fstat = { [[    //depot/src/moved.c) printf '... movedFile //depot/src/old.c\n' ;;]] },
    cases = { [[  "revert -w //depot/src/new.c") rm -f "$ROOT/src/new.c"; echo "//depot/src/new.c#none - was add, deleted" ;;]] },
}

test('D on an edited file reverts it and marks it for delete in its changelist', function()
    open_workspace(d_cls, d_opts)
    goto_line_containing('src/a.c')
    keys('D')
    eq(prompts, { 'Mark src/a.c for delete (discards local changes)? (y/N): ' }, 'prompts')
    eq(actions(), { '-x - revert < //depot/src/a.c', '-x - delete -c 100 < //depot/src/a.c' }, 'p4 commands')
end)

test('D on an added file removes it from disk and drops its buffer', function()
    vim.fn.writefile({ 'new' }, root .. '/src/new.c')
    open_workspace(d_cls, d_opts)
    vim.cmd('badd ' .. vim.fn.fnameescape(root .. '/src/new.c'))
    goto_line_containing('src/new.c')
    keys('D')
    eq(prompts, { 'Remove src/new.c from disk (opened for add)? (y/N): ' }, 'prompts')
    eq(actions(), { '-x - revert -w < //depot/src/new.c' }, 'p4 commands')
    eq(utils.find_buffer_by_path(root .. '/src/new.c'), nil, 'buffer of the removed file')
end)

test('D on a branched file removes it like an add (no depot revision to delete)', function()
    vim.fn.writefile({ 'branched' }, root .. '/src/br.c')
    open_workspace({ { cn = '100', files = { { path = 'src/br.c', action = 'branch' } } } }, {
        cases = { [[  "revert -w //depot/src/br.c") rm -f "$ROOT/src/br.c"; echo "//depot/src/br.c#none - was branch, deleted" ;;]] },
    })
    vim.cmd('badd ' .. vim.fn.fnameescape(root .. '/src/br.c'))
    goto_line_containing('src/br.c')
    keys('D')
    eq(prompts, { 'Remove src/br.c from disk (opened for branch)? (y/N): ' }, 'prompts')
    eq(actions(), { '-x - revert -w < //depot/src/br.c' }, 'p4 commands')
    eq(utils.find_buffer_by_path(root .. '/src/br.c'), nil, 'buffer of the removed file')
end)

test('D on a move/add reverts the move and deletes the original', function()
    open_workspace(d_cls, d_opts)
    goto_line_containing('src/moved.c')
    keys('D')
    eq(prompts, { 'Undo move to src/moved.c and mark //depot/src/old.c for delete (discards local changes)? (y/N): ' }, 'prompts')
    eq(actions(), { '-x - revert < //depot/src/moved.c', '-x - delete -c 100 < //depot/src/old.c' }, 'p4 commands')
end)

test('D on a file already marked for delete does nothing', function()
    open_workspace(d_cls, d_opts)
    goto_line_containing('src/gone.c')
    keys('D')
    eq(prompts, {}, 'prompts')
    eq(actions(), {}, 'p4 commands')
    eq(notified('1 file already marked for delete'), true, 'notified')
end)

test('D on a range asks with a per-kind summary', function()
    open_workspace(d_cls, d_opts)
    visual(line_containing('src/a.c'), line_containing('src/gone.c'), 'D')
    eq(prompts, { 'Mark 1 file(s) for delete, remove 1 added file(s) from disk, undo 1 move(s) and delete the originals (discards local changes)? (y/N): ' }, 'prompts')
    eq(notified('2 files already marked for delete'), true, 'notified')
    eq(actions(), {
        '-x - revert < //depot/src/a.c < //depot/src/moved.c',
        '-x - revert -w < //depot/src/new.c',
        '-x - delete -c 100 < //depot/src/a.c < //depot/src/old.c',
    }, 'p4 commands')
end)

test('D works on default-CL files but not on the default changelist', function()
    open_workspace(d_cls, d_opts)
    goto_line_containing('src/d.c')
    keys('D')
    eq(actions(), { '-x - revert < //depot/src/d.c', '-x - delete < //depot/src/d.c' }, 'p4 commands')
    vim.fn.delete(dir .. '/p4.log')
    prompts = {}
    goto_line_containing('CL default :')
    keys('D')
    eq(prompts, {}, 'prompts')
    eq(actions(), {}, 'p4 commands')
    eq(notified('Cannot delete the default changelist'), true, 'notified')
end)

-- Resolve -----------------------------------------------------------------------

local resolve_records = {
    '... depotFile //depot/src/a.c',
    '... resolveType0 content',
    '... resolveBaseFile0 //depot/src/a.c',
    '... resolveBaseRev0 3',
    '... resolveFromFile0 //depot/src/a.c',
    '... resolveStartFromRev0 4',
    '... resolveEndFromRev0 5',
}

-- Open the merge for src/a.c (unresolved), with fstat -Or output `records`
local function start_merge(records, extra_cases)
    local cases = { '  "-ztag fstat -Or "*) out resolve ;;' }
    vim.list_extend(cases, extra_cases or {})
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' } } } }, {
        fstat = { [[    //depot/src/a.c) printf '... haveRev 5\n... headRev 5\n... unresolved\n' ;;]] },
        cases = cases,
        out = { resolve = records },
    })
    select_choice = 'Merge'
    goto_line_containing('src/a.c')
    keys('R')
end

local function a_c_buf() return utils.find_buffer_by_path(root .. '/src/a.c') end
local function a_c_disk() return vim.fn.readfile(root .. '/src/a.c') end

test('merge: a failing p4 print leaves the file and its buffer alone', function()
    vim.env.FAKE_DIFF3 = 'conflict'
    start_merge(resolve_records, { [[  "print -q -o "*) echo "//depot/src/a.c#5 - no such file(s)." >&2; exit 1 ;;]] })
    eq(notified('no such file(s).'), true, 'error notified')
    local buf = a_c_buf()
    eq(buf == nil or not vim.bo[buf].modified, true, 'buffer untouched')
    eq(a_c_disk(), { 'one', 'TWO', 'three' }, 'file on disk')
end)

test('merge: diff3 trouble (exit 2) aborts', function()
    vim.env.FAKE_DIFF3 = 'fail'
    start_merge(resolve_records, { [[  "print -q -o "*) echo theirs > "$4" ;;]] })
    eq(notified('diff3: something broke'), true, 'error notified')
    local buf = a_c_buf()
    eq(buf == nil or not vim.bo[buf].modified, true, 'buffer untouched')
end)

test('merge: a missing diff3 is reported', function()
    vim.env.FAKE_DIFF3 = 'fail'
    local executable = vim.fn.executable
    vim.fn.executable = function(name) return name == 'diff3' and 0 or executable(name) end
    local ok, err = pcall(start_merge, resolve_records, { [[  "print -q -o "*) echo theirs > "$4" ;;]] })
    vim.fn.executable = executable
    assert(ok, err)
    eq(notified('diff3 not found'), true, 'error notified')
    local buf = a_c_buf()
    eq(buf == nil or not vim.bo[buf].modified, true, 'buffer untouched')
end)

test('merge: works with CRLF fstat output, q accepts and removes the autocmd', function()
    vim.env.FAKE_DIFF3 = 'conflict'
    local crlf = {}
    for _, l in ipairs(resolve_records) do table.insert(crlf, l .. '\r') end
    start_merge(crlf, { [[  "print -q -o "*) echo theirs > "$4" ;;]] })
    eq(current_name(), 'a.c', 'merge buffer')
    eq(buf_lines(), { '<<<<<<< LOCAL', 'mine', '||||||| ORIGINAL', 'base', '=======', 'theirs', '>>>>>>> INCOMING' }, 'merged lines')
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, { 'merged' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    eq(a_c_disk(), { 'merged' }, 'auto-saved once resolved')
    keys('q')
    eq(vim.tbl_contains(actions(), 'resolve -ay //depot/src/a.c'), true, 'resolve -ay')
    eq(#vim.api.nvim_get_autocmds({ buffer = buf, event = 'TextChanged' }), 0, 'TextChanged autocmds left')
    vim.fn.writefile({ 'one', 'TWO', 'three' }, root .. '/src/a.c')
end)

test('merge: Esc cancels and later edits are not auto-saved', function()
    vim.env.FAKE_DIFF3 = 'conflict'
    start_merge(resolve_records, { [[  "print -q -o "*) echo theirs > "$4" ;;]] })
    eq(current_name(), 'a.c', 'merge buffer')
    local buf = vim.api.nvim_get_current_buf()
    keys('<Esc>')
    eq(current_name(), 'Perforce Window', 'back in the Perforce window')
    eq(#vim.api.nvim_get_autocmds({ buffer = buf, event = 'TextChanged' }), 0, 'TextChanged autocmds left')
    -- The user edits the file later
    vim.cmd('buffer ' .. buf)
    vim.api.nvim_buf_set_lines(buf, 0, 1, false, { 'later edit' })
    vim.api.nvim_exec_autocmds('TextChanged', { buffer = buf })
    eq(a_c_disk(), { 'one', 'TWO', 'three' }, 'file on disk')
    eq(vim.bo[buf].modified, true, 'edit still unsaved')
    vim.cmd('edit!')
end)

test('R reports a failed auto-merge instead of "Auto-merged"', function()
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' } } } }, {
        cases = { '  "resolve -am "*) echo "resolve: connection lost" >&2; exit 1 ;;' },
    })
    goto_line_containing('src/a.c')
    keys('R')
    eq(notified('Auto-merged'), false, 'claims auto-merged')
    eq(notified('resolve: connection lost'), true, 'error notified')
end)

test('R does not claim "Auto-merged" when the status check fails', function()
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' }, { path = 'src/b.c' } } } }, {
        cases = { [[  "-ztag fstat //depot/src/a.c") echo "fstat failed" >&2; exit 1 ;;]] },
    })
    goto_line_containing('src/a.c')
    keys('R')
    eq(notified('Auto-merged'), false, 'claims auto-merged')
    eq(notified('Could not check'), true, 'error notified')
end)

-- Display -----------------------------------------------------------------------

test('changelists are sorted and the cursor follows its entry on refresh', function()
    local cls = {
        { cn = '300', files = { { path = 'src/c300.c' } } },
        { cn = '50', files = { { path = 'src/c50.c' } } },
        { cn = '1000', files = { { path = 'src/c1000.c' } } },
        { cn = 'default', files = { { path = 'src/cdef.c' } } },
        { cn = '200', files = { { path = 'src/c200.c' } } },
    }
    open_workspace(cls)
    local headers = {}
    for _, l in ipairs(buf_lines()) do
        if l:match('^CL ') then table.insert(headers, l) end
    end
    eq(headers, { 'CL default :', 'CL 50 :', 'CL 200 :', 'CL 300 :', 'CL 1000 :' }, 'changelist order')
    goto_line_containing('src/c300.c')
    -- A file is opened in CL 50 meanwhile: lines shift down
    table.insert(cls[2].files, { path = 'src/c50b.c' })
    workspace(cls)
    vim.cmd('P4Window')
    eq(buf_lines()[vim.api.nvim_win_get_cursor(0)[1]]:find('src/c300.c', 1, true) ~= nil, true, 'cursor on src/c300.c')
end)

test('highlighting: shelf, move/add, job and multibyte description lines', function()
    open_workspace({ {
        cn = '100',
        desc = { '“Quoted” summary' },
        jobs = { { id = 'job001', desc = 'A job' } },
        shelved = { 'src/s.c' },
        files = { { path = 'src/moved.c', action = 'move/add' } },
    } })
    eq(hl_groups(line_containing('“Quoted”')).Comment, true, 'description')
    eq(hl_groups(line_containing('(job001)')).Number, true, 'job id')
    eq(hl_groups(line_containing('Shelf (1 file)')).Special, true, 'shelf arrow')
    local moved = hl_groups(line_containing('src/moved.c'))
    eq(moved.DiffText and moved.String, true, 'move/add action and path')
end)

test('a job without description shows no "nil"', function()
    open_workspace({ { cn = '100', jobs = { { id = 'job001' } }, files = { { path = 'src/a.c' } } } })
    eq(buf_lines()[line_containing('(job001)')]:find('nil', 1, true), nil, 'job line')
end)

test('keys on the help line do nothing', function()
    open_workspace({ { cn = '100', files = { { path = 'src/a.c' } } } })
    for _, k in ipairs({ '<CR>', 'd', 'S', 'R' }) do
        keys('G' .. k)
        eq(vim.v.errmsg, '', 'errors after ' .. k)
    end
    eq(actions(), {}, 'p4 commands')
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
