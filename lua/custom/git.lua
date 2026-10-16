local diffsplit = require('custom.diffsplit')
local utils = require('custom.utils')

local BUFFER_NAME = 'Git Window'
local INDEX_MAP = {}
local GIT_CHANGES = {}
local STATUS_COLUMN_WIDTH = 8
local STATUS_LABELS = {
    M = 'MOD',
    A = 'ADD',
    D = 'DEL',
    R = 'REN',
    C = 'COPY',
    U = 'UNMERGED',
    T = 'TYPE',
}

local show_window -- forward declaration
local cached_buf = nil

-- Run git with a list of arguments and return its output as a list of lines,
-- or as NUL-separated fields when `z = true` (for the -z output formats).
-- No shell is involved, so arguments need no quoting on any platform.
local function git_cmd(args)
    if not args or not args.cmd or #args.cmd == 0 then
        error('No git command given', 0)
    end

    local cmd = { 'git' }
    if args.cwd and args.cwd ~= '' then
        vim.list_extend(cmd, { '-C', args.cwd })
    end
    vim.list_extend(cmd, args.cmd)

    local ok, result = pcall(function()
        return vim.system(cmd):wait()
    end)
    if not ok then
        error('Git error:\n ' .. tostring(result), 0)
    end

    local function split(text, sep)
        if text == '' then
            return {}
        end
        if text:sub(-1) == sep then
            text = text:sub(1, -2)
        end
        return vim.split(text, sep, { plain = true })
    end

    if result.code ~= 0 then
        local message = split((result.stderr or '') .. (result.stdout or ''), '\n')
        error('Git error:\n ' .. table.concat(message, '\n '), 0)
    end

    if args.z then
        return split(result.stdout or '', '\0')
    end
    local lines = split(result.stdout or '', '\n')
    for i, line in ipairs(lines) do
        lines[i] = line:gsub('\r$', '')
    end
    return lines
end

local function get_git_root(dir)
    local out = git_cmd({ cwd = dir, cmd = { 'rev-parse', '--show-toplevel' } })
    if not out or not out[1] or out[1] == '' then
        error('Could not determine git repository root', 0)
    end
    return vim.fn.resolve(out[1])
end

-- Directory to look for the repository in: the current file's directory, or the
-- cwd for terminals, URLs, scratch buffers and files in missing directories.
local function current_dir()
    local file = vim.fn.expand('%:p')
    if vim.bo.buftype == '' and file ~= '' then
        local dir = vim.fn.fnamemodify(file, ':h')
        if vim.fn.isdirectory(dir) == 1 then
            return dir
        end
    end
    return vim.fn.getcwd()
end

-- The repository to act on: the one the Git window shows when called from it,
-- otherwise the current file's (or the cwd's).
local function active_root()
    return vim.b.git_root or get_git_root(current_dir())
end

-- file's path below root, spelled as in file. The check is case-insensitive on
-- Windows (utils.normalize_path lowercases ASCII only, keeping byte lengths), so
-- the result is the same-length tail of file.
local function relative_to_root(root, file)
    local relpath = vim.fs.relpath(utils.normalize_path(root), utils.normalize_path(file))
    if not relpath or relpath == '.' then
        error(file .. ' is not inside the repository at ' .. root, 0)
    end
    local norm_file = vim.fs.normalize(file)
    return norm_file:sub(#norm_file - #relpath + 1)
end

local function make_entry(root, x, y, relpath, orig)
    local is_untracked = x == '?' and y == '?'
    local is_staged = not is_untracked and x ~= ' '
    local is_unstaged = not is_untracked and y ~= ' '

    return {
        root = root,
        relpath = relpath,
        -- For renames/copies, the original path, so the diff can use it at HEAD
        -- as its base and revert/unstage can act on both sides.
        orig = orig,
        abs_path = root .. '/' .. relpath,
        staged = is_staged,
        unstaged = is_unstaged,
        untracked = is_untracked,
        staged_label = is_staged and (STATUS_LABELS[x] or x) or nil,
        unstaged_label = is_unstaged and (STATUS_LABELS[y] or y) or nil,
    }
end

-- Parse `git status --porcelain=v1 -z` output. Each field is "XY path" with the
-- path unquoted; a rename or copy is followed by a field holding its origin.
local function parse_status(root, fields)
    local entries = {}
    local i = 1
    while i <= #fields do
        local field = fields[i]
        local x, y, relpath = field:sub(1, 1), field:sub(2, 2), field:sub(4)
        local orig
        if x:match('[RC]') or y:match('[RC]') then
            i = i + 1
            orig = fields[i]
        end
        if relpath ~= '' then
            table.insert(entries, make_entry(root, x, y, relpath, orig))
        end
        i = i + 1
    end
    return entries
end

local function find_entry(entries, relpath)
    local target = utils.normalize_path(relpath)
    for _, entry in ipairs(entries) do
        -- git prints '/'-separated paths, so the exact match is the usual one.
        if entry.relpath == relpath or utils.normalize_path(entry.relpath) == target then
            return entry
        end
    end
    return nil
end

-- Status of the file at relpath below root, or nil if unchanged/unknown.
local function file_status(root, relpath)
    local fields = git_cmd({ cwd = root, cmd = { 'status', '--porcelain=v1', '-z', '-uall', '--', relpath }, z = true })
    local entry = find_entry(parse_status(root, fields), relpath)
    if entry and entry.staged_label == 'ADD' then
        -- With the new path as pathspec, a staged rename shows as an add. Only
        -- the whole-repo status pairs it with its origin.
        fields = git_cmd({ cwd = root, cmd = { 'status', '--porcelain=v1', '-z', '-uno' }, z = true })
        entry = find_entry(parse_status(root, fields), relpath) or entry
    end
    return entry
end

-- Diff file against HEAD. status is its entry when the caller already has it
-- (the Git window), otherwise it is queried.
local function git_vdiffsplit(file, root, status)
    file = vim.fn.resolve(file)
    root = root or get_git_root(vim.fn.fnamemodify(file, ':h'))
    local relpath = relative_to_root(root, file)

    -- Decide the diff base from the file's status, so we never silently diff a
    -- new/untracked file against an empty buffer and paint the whole panel blue.
    -- The path we read at HEAD is the rename origin for renames, else the file.
    status = status or file_status(root, relpath)
    local base_path = (status and status.orig) or relpath
    local base_content = {}
    local left_name

    if status and status.untracked then
        left_name = 'Git (untracked — no base): ' .. relpath
        vim.notify('Git: ' .. relpath .. ' is untracked; diffing against empty base', vim.log.levels.INFO)
    else
        local ok, result = pcall(git_cmd, {
            cwd = root,
            cmd = { 'show', 'HEAD:./' .. base_path },
        })
        if ok then
            base_content = result
            left_name = 'Git HEAD:' .. base_path
        else
            -- Not in HEAD (e.g. staged new file) — empty base, but say so.
            left_name = 'Git (new file — no base): ' .. relpath
            vim.notify('Git: ' .. relpath .. ' has no version at HEAD; diffing against empty base', vim.log.levels.INFO)
        end
    end

    diffsplit.open_file_diffsplit({
        filepath = file,
        left_content = base_content,
        left_name = left_name,
        notify_message = 'Git Diff: [ / ] jump hunks, r reverts hunk, q closes base, Q closes both',
    })
end

-- Short badge shown for a file within a given section.
local function badge_for(item, section)
    if section == 'staged' then
        return item.staged_label
    elseif section == 'unstaged' then
        return item.unstaged_label
    end
    return 'NEW'
end

-- Partition the flat change list into the three review sections. A file with
-- both staged and unstaged changes (e.g. "MM") appears in both.
local function build_sections(changes)
    local staged, unstaged, untracked = {}, {}, {}
    for _, item in ipairs(changes) do
        if item.untracked then
            table.insert(untracked, item)
        else
            if item.staged then table.insert(staged, item) end
            if item.unstaged then table.insert(unstaged, item) end
        end
    end
    return staged, unstaged, untracked
end

local function get_git_changes(root)
    -- -uall expands untracked directories to their individual files; without it
    -- git collapses e.g. "foo/" into one line and hides everything inside.
    local fields = git_cmd({ cwd = root, cmd = { 'status', '--porcelain=v1', '-z', '-uall' }, z = true })
    local changes = parse_status(root, fields)

    table.sort(changes, function(a, b)
        return a.relpath < b.relpath
    end)

    return changes
end

local function has_staged_changes(root)
    local staged = git_cmd({ cwd = root, cmd = { 'diff', '--cached', '--name-only' } })
    return #staged > 0
end

-- The paths an action on item covers: both sides of a rename or copy.
local function item_paths(item)
    local paths = { item.relpath }
    if item.orig then
        table.insert(paths, item.orig)
    end
    return paths
end

local function abs_paths(root, relpaths)
    return vim.tbl_map(function(relpath) return root .. '/' .. relpath end, relpaths)
end

-- The file entry under the cursor, including which section row it is (staged /
-- unstaged / untracked) since a file may appear in more than one section.
-- Keymaps are buffer-local, so the current window is the Git window the key
-- was pressed in, even when the buffer is shown in more than one.
local function current_entry()
    local data = INDEX_MAP[vim.api.nvim_win_get_cursor(0)[1]]
    if not data or data.type ~= 'file' then
        return nil
    end
    return data
end

-- Run an action's commands, reporting an error instead of throwing, and always
-- refresh so the window shows what actually happened. Buffers of the absolute
-- paths in removable that the action deleted are dropped; the rest are reloaded.
local function run_action(root, fn, removable)
    local ok, err = pcall(fn)
    if not ok then
        utils.notify_error('Git: ', err)
    end
    utils.drop_buffers_of_missing_files(removable or {})
    show_window(root)
end

local function input_action()
    local entry = current_entry()
    if not entry then
        return
    end
    local item = entry.item

    if vim.fn.filereadable(item.abs_path) == 1 or vim.fn.isdirectory(item.abs_path) == 1 then
        vim.cmd('edit ' .. vim.fn.fnameescape(item.abs_path))
    else
        vim.notify('File does not exist on disk: ' .. item.relpath, vim.log.levels.WARN)
    end
end

local function show_diff()
    local entry = current_entry()
    if not entry then
        return
    end
    local item = entry.item

    if vim.fn.filereadable(item.abs_path) ~= 1 then
        vim.notify('Cannot diff missing file on disk: ' .. item.relpath, vim.log.levels.WARN)
        return
    end

    vim.schedule(function()
        local ok, err = pcall(git_vdiffsplit, item.abs_path, item.root, item)
        if not ok then
            utils.notify_error('Git: ', err)
        end
    end)
end

local function revert_file()
    local entry = current_entry()
    if not entry then
        return
    end
    local item = entry.item

    if item.untracked then
        utils.confirm('Delete untracked ' .. item.relpath .. '? (y/N): ', function()
            run_action(item.root, function()
                local is_dir = vim.fn.isdirectory(item.abs_path) == 1
                if vim.fn.delete(item.abs_path, is_dir and 'rf' or '') ~= 0 then
                    error('failed removing ' .. item.relpath, 0)
                end
                vim.notify('Git: removed untracked ' .. item.relpath, vim.log.levels.INFO)
            end, { item.abs_path })
        end)
        return
    end

    utils.confirm('Revert all changes in ' .. item.relpath .. '? (y/N): ', function()
        -- Include a rename's origin, or reverting it only deletes the new path.
        -- Restoring a staged add (or a rename's new path) removes the file.
        local paths = item_paths(item)
        run_action(item.root, function()
            local cmd = { 'restore', '--source=HEAD', '--staged', '--worktree', '--' }
            git_cmd({ cwd = item.root, cmd = vim.list_extend(cmd, paths) })
            vim.notify('Git: reverted ' .. item.relpath, vim.log.levels.INFO)
        end, abs_paths(item.root, paths))
    end)
end

local function toggle_stage_file()
    local entry = current_entry()
    if not entry then
        return
    end
    local item = entry.item

    run_action(item.root, function()
        -- Unstage only when acting on a row in the Staged section; otherwise stage.
        if entry.section == 'staged' then
            -- reset rather than restore --staged, which needs a HEAD commit.
            git_cmd({ cwd = item.root, cmd = vim.list_extend({ 'reset', '-q', '--' }, item_paths(item)) })
            vim.notify('Git: unstaged ' .. item.relpath, vim.log.levels.INFO)
        else
            git_cmd({ cwd = item.root, cmd = { 'add', '--', item.relpath } })
            vim.notify('Git: staged ' .. item.relpath, vim.log.levels.INFO)
        end
    end)
end

-- A whole-repository action on the shown repository: run git with cmd.
local function repo_action(cmd, message)
    return function()
        local root = vim.b.git_root
        run_action(root, function()
            git_cmd({ cwd = root, cmd = cmd })
            vim.notify('Git: ' .. message, vim.log.levels.INFO)
        end)
    end
end

local stage_all = repo_action({ 'add', '-A' }, 'staged all changes')
local unstage_all = repo_action({ 'reset', '-q', 'HEAD', '--' }, 'unstaged all changes')

local function discard_all()
    local root = vim.b.git_root
    -- This deletes untracked files and staged adds, so drop the buffers of
    -- any listed file that is gone afterwards.
    local listed = vim.tbl_map(function(item) return item.abs_path end, GIT_CHANGES)
    utils.confirm('Discard ALL changes and remove untracked files? (y/N): ', function()
        run_action(root, function()
            -- One reset --hard resets index and worktree together (and works
            -- without a HEAD commit). If it fails nothing has changed, so stop
            -- there rather than delete the untracked files anyway.
            git_cmd({ cwd = root, cmd = { 'reset', '--hard', '-q' } })
            git_cmd({ cwd = root, cmd = { 'clean', '-fd' } })
            vim.notify('Git: discarded all changes', vim.log.levels.INFO)
        end, listed)
    end)
end

local function commit_changes()
    local root = vim.b.git_root
    local ok, staged = pcall(has_staged_changes, root)
    if not ok then
        utils.notify_error('Git: ', staged)
        return
    end
    if not staged then
        vim.notify('Git: no staged changes to commit', vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = 'Commit message: ' }, function(input)
        if not input or input == '' then
            return
        end

        local commit_ok, result = pcall(git_cmd, {
            cwd = root,
            cmd = { 'commit', '-m', input },
        })

        if not commit_ok then
            utils.notify_error('Git: ', result)
            return
        end

        local summary = result[1] or 'commit created'
        vim.notify('Git: ' .. summary, vim.log.levels.INFO)
        show_window(root)
    end)
end

local function open_lazygit()
    local ok, root = pcall(active_root)
    if not ok then
        utils.notify_error('Git: ', root)
        return
    end
    if vim.fn.executable('lazygit') == 0 then
        vim.notify('Git: lazygit is not installed', vim.log.levels.WARN)
        return
    end

    local term_win = utils.get_current_window()
    local previous_buf = vim.api.nvim_get_current_buf()

    vim.cmd('enew')
    local term_buf = vim.api.nvim_get_current_buf()
    vim.bo[term_buf].bufhidden = 'wipe'
    local term_name = 'lazygit://' .. root
    if utils.release_buffer_name(term_name) then
        vim.api.nvim_buf_set_name(term_buf, term_name)
    end

    vim.fn.termopen({ 'lazygit' }, {
        cwd = root,
        on_exit = function()
            vim.schedule(function()
                local win = utils.find_window_by_buffer(term_buf)
                if not win then
                    return
                end
                -- Put back the buffer lazygit replaced, so a split stays open.
                -- The Git buffer is deleted below, so it falls back to dismiss.
                if vim.api.nvim_buf_is_valid(previous_buf) and win == term_win then
                    vim.api.nvim_win_set_buf(win, previous_buf)
                else
                    utils.dismiss_buffer_window(win, term_buf)
                end
            end)
        end,
    })
    vim.cmd('startinsert')

    if previous_buf == cached_buf then
        pcall(vim.api.nvim_buf_delete, previous_buf, { force = true })
    end
end

local function close_git_window(buf)
    local win = utils.find_window_by_buffer(buf)
    utils.dismiss_buffer_window(win, buf)
end

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }

    vim.keymap.set('n', '<CR>', input_action, opts)
    vim.keymap.set('n', 'd', show_diff, opts)
    vim.keymap.set('n', 'r', revert_file, opts)
    vim.keymap.set('n', 's', toggle_stage_file, opts)
    vim.keymap.set('n', 'a', stage_all, opts)
    vim.keymap.set('n', 'A', unstage_all, opts)
    vim.keymap.set('n', 'D', discard_all, opts)
    vim.keymap.set('n', 'c', commit_changes, opts)
    vim.keymap.set('n', 'L', open_lazygit, opts)
    vim.keymap.set('n', 'q', function()
        close_git_window(buf)
    end, opts)
end

local function get_or_create_buffer()
    local buf, created = utils.get_or_create_scratch_buffer(BUFFER_NAME, cached_buf, false)
    cached_buf = buf
    if created then
        setup_keymaps(buf)
    end
    return buf
end

local function setup_display_lines(root)
    INDEX_MAP = {}

    local lines = {}
    local function push(line, entry)
        table.insert(lines, line)
        table.insert(INDEX_MAP, entry)
    end

    push('Git Review: ' .. root, { type = 'header' })
    push('', { type = 'separator' })

    if #GIT_CHANGES == 0 then
        push('Working tree clean.', { type = 'info' })
    else
        local staged, unstaged, untracked = build_sections(GIT_CHANGES)
        local row_fmt = '  [ %-' .. STATUS_COLUMN_WIDTH .. 's] %s'

        local function section(title, items, kind)
            if #items == 0 then
                return
            end
            push(string.format('%s (%d)', title, #items), { type = 'section' })
            for _, item in ipairs(items) do
                push(string.format(row_fmt, badge_for(item, kind), item.relpath),
                    { type = 'file', item = item, section = kind })
            end
            push('', { type = 'separator' })
        end

        section('Staged', staged, 'staged')
        section('Unstaged', unstaged, 'unstaged')
        section('Untracked', untracked, 'untracked')
    end

    push('[Enter=open d=diff r=revert s=stage a=stage-all A=unstage-all D=discard-all c=commit L=lazygit q=close]',
        { type = 'help' })

    return lines
end

local function apply_syntax_highlighting(buf)
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

    local ns_id = vim.api.nvim_create_namespace('GitWindowHighlight')
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- Per-badge highlight groups so status reads at a glance.
    local badge_hl = {
        MOD = 'DiffChange',
        ADD = 'DiffAdd',
        NEW = 'DiffAdd',
        DEL = 'DiffDelete',
        REN = 'DiffChange',
        COPY = 'DiffChange',
        TYPE = 'DiffChange',
        UNMERGED = 'ErrorMsg',
    }
    local line_hl = { header = 'Title', section = 'Title', help = 'Comment', info = 'Comment' }

    for i, line in ipairs(lines) do
        local line_idx = i - 1
        local entry = INDEX_MAP[i]

        if line_hl[entry.type] then
            vim.api.nvim_buf_add_highlight(buf, ns_id, line_hl[entry.type], line_idx, 0, #line)
        elseif entry.type == 'file' then
            local badge_start, badge_finish, badge = line:find('%[ (%S+)%s*%]')
            if badge_start then
                local hl = badge_hl[badge] or 'Keyword'
                vim.api.nvim_buf_add_highlight(buf, ns_id, hl, line_idx, badge_start - 1, badge_finish)
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Normal', line_idx, badge_finish, #line)
            end
        end
    end
end

-- Show (or refresh) the Git window for root, by default the active repository.
show_window = function(root)
    -- Query git before touching any buffers or windows, so a failure (not in a
    -- repository, git missing) leaves the editor untouched.
    local ok, result = pcall(function()
        root = root or active_root()
        return get_git_changes(root)
    end)
    if not ok then
        utils.notify_error('Git: ', result)
        return
    end
    GIT_CHANGES = result

    local created_ok, buffer = pcall(get_or_create_buffer)
    if not created_ok then
        utils.notify_error('Git: ', buffer)
        return
    end
    vim.b[buffer].git_root = root

    local saved_cursor_pos = nil
    local win = vim.api.nvim_get_current_buf() == buffer and utils.get_current_window()
        or utils.find_window_by_buffer(buffer)
    if win then
        saved_cursor_pos = utils.get_cursor_position(win)
    end

    -- Take over as main window
    local target_win = utils.close_other_windows()

    local lines = setup_display_lines(root)

    if target_win and utils.is_window_valid(target_win) then
        vim.api.nvim_win_set_buf(target_win, buffer)
    else
        target_win = utils.reuse_or_create_window_for_buffer(buffer)
    end
    utils.set_buffer_lines(buffer, 0, -1, lines)
    apply_syntax_highlighting(buffer)

    utils.set_current_window(target_win)
    if saved_cursor_pos then
        pcall(utils.set_cursor_position, target_win, saved_cursor_pos.line, saved_cursor_pos.column)
    end
end

local function diff_current_file()
    local file = vim.fn.expand('%:p')
    if vim.bo.buftype ~= '' or file == '' or vim.fn.filereadable(file) ~= 1 then
        vim.notify('Git: no file in current buffer', vim.log.levels.WARN)
        return
    end
    local ok, err = pcall(git_vdiffsplit, file)
    if not ok then
        utils.notify_error('Git: ', err)
    end
end

vim.api.nvim_create_user_command('GitWindow', function() show_window() end, { desc = 'Git: Show changed files' })
vim.api.nvim_create_user_command('GitLazyGit', open_lazygit, { desc = 'Git: Open lazygit' })
vim.api.nvim_create_user_command('GitDiff', diff_current_file, { desc = 'Git: Diff current file against HEAD' })

vim.keymap.set('n', '<leader>gs', function() show_window() end, { desc = 'Git: Show changed files' })
vim.keymap.set('n', '<leader>gg', open_lazygit, { desc = 'Git: Open lazygit' })
vim.keymap.set('n', '<leader>gd', diff_current_file, { desc = 'Git: Diff current file against HEAD' })
