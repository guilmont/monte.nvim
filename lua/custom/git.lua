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
    ['!'] = 'IGNORED',
}

local show_window -- forward declaration

local function git_cmd(args)
    if not args or not args.cmd or args.cmd == '' then
        error('No git command given')
    end

    local cmd = 'git'
    if args.cwd and args.cwd ~= '' then
        cmd = cmd .. ' -C ' .. vim.fn.shellescape(args.cwd)
    end
    cmd = cmd .. ' ' .. args.cmd

    local result = vim.fn.systemlist(cmd)
    if vim.v.shell_error ~= 0 then
        error('\nGit error:\n ' .. table.concat(result, '\n '))
    end

    return result
end

local function get_git_root(path)
    local dir = vim.fn.getcwd()
    if path and path ~= '' then
        dir = vim.fn.fnamemodify(path, ':h')
    end

    local out = git_cmd({ cwd = dir, cmd = 'rev-parse --show-toplevel' })
    if not out or not out[1] or out[1] == '' then
        error('Could not determine git repository root')
    end
    return vim.fn.resolve(out[1])
end

local function current_git_root()
    return get_git_root(vim.fn.expand('%:p'))
end

local function relative_to_root(root, file)
    if file:sub(1, #root + 1) == root .. '/' then
        return file:sub(#root + 2)
    end
    return vim.fn.fnamemodify(file, ':t')
end

local parse_status_line -- forward declaration

-- Status of a single file relative to root, or nil if unchanged/unknown.
local function file_status(root, file)
    local relpath = relative_to_root(root, file)
    local out = git_cmd({ cwd = root, cmd = 'status --porcelain=v1 -- ' .. vim.fn.shellescape(relpath) })
    for _, line in ipairs(out) do
        local entry = parse_status_line(root, line)
        -- porcelain reports renames as "old -> new"; match on the new path.
        if entry and (entry.relpath == relpath or entry.abs_path == file) then
            return entry
        end
    end
    return nil
end

local function git_vdiffsplit(file)
    file = vim.fn.resolve(file)
    local root = get_git_root(file)
    local relpath = relative_to_root(root, file)

    -- Decide the diff base from the file's status, so we never silently diff a
    -- new/untracked file against an empty buffer and paint the whole panel blue.
    -- The path we read at HEAD is the rename origin for renames, else the file.
    local status = file_status(root, file)
    local base_path = (status and status.orig) or relpath
    local base_content = {}
    local left_name

    if status and status.untracked then
        left_name = 'Git (untracked — no base): ' .. relpath
        vim.notify('Git: ' .. relpath .. ' is untracked; diffing against empty base', vim.log.levels.INFO)
    else
        local ok, result = pcall(git_cmd, {
            cwd = root,
            cmd = 'show HEAD:./' .. vim.fn.shellescape(base_path),
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

parse_status_line = function(root, line)
    if not line or line == '' then
        return nil
    end

    local x = line:sub(1, 1)
    local y = line:sub(2, 2)
    local raw_path = line:sub(4)
    if raw_path == '' then
        return nil
    end

    local relpath = raw_path:match('-> (.+)$') or raw_path
    relpath = relpath:gsub('^"', ''):gsub('"$', '')

    -- For renames/copies the raw path is "old -> new"; capture the origin so
    -- the diff can use the original path at HEAD as its base.
    local orig = raw_path:match('^(.-) %-> ')
    if orig then orig = orig:gsub('^"', ''):gsub('"$', '') end

    local absolute_path = root .. '/' .. relpath
    local is_untracked = x == '?' and y == '?'
    local is_staged = not is_untracked and x ~= ' '
    local is_unstaged = not is_untracked and y ~= ' '

    return {
        root = root,
        relpath = relpath,
        orig = orig,
        abs_path = absolute_path,
        staged = is_staged,
        unstaged = is_unstaged,
        untracked = is_untracked,
        staged_label = is_staged and (STATUS_LABELS[x] or x) or nil,
        unstaged_label = is_unstaged and (STATUS_LABELS[y] or y) or nil,
    }
end

-- Short badge shown for a file within a given section.
local function badge_for(item, section)
    if section == 'staged' then
        return item.staged_label or 'MOD'
    elseif section == 'unstaged' then
        return item.unstaged_label or 'MOD'
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
    local lines = git_cmd({ cwd = root, cmd = 'status --porcelain=v1 -uall' })
    local changes = {}

    for _, line in ipairs(lines) do
        local entry = parse_status_line(root, line)
        if entry then
            table.insert(changes, entry)
        end
    end

    table.sort(changes, function(a, b)
        return a.relpath < b.relpath
    end)

    return changes
end

local function has_staged_changes(root)
    local staged = git_cmd({ cwd = root, cmd = 'diff --cached --name-only' })
    return #staged > 0
end

local function get_git_window()
    local buf = utils.find_buffer_by_name(BUFFER_NAME)
    if not buf then
        error('No valid Git buffer for action')
    end

    local win = utils.find_window_by_buffer(buf)
    if win then
        return win
    end

    error('No valid Git window for action')
end

local function get_action_line()
    local win = get_git_window()
    return utils.get_cursor_position(win).line
end

-- The file entry under the cursor, including which section row it is (staged /
-- unstaged / untracked) since a file may appear in more than one section.
local function current_entry()
    local line = get_action_line()
    local data = INDEX_MAP[line]
    if not data or data.type ~= 'file' then
        return nil
    end
    return data
end

local function current_item()
    local data = current_entry()
    return data and data.item or nil
end

local function input_action()
    local item = current_item()
    if not item then
        return
    end

    if vim.fn.filereadable(item.abs_path) == 1 or vim.fn.isdirectory(item.abs_path) == 1 then
        vim.cmd('edit ' .. vim.fn.fnameescape(item.abs_path))
    else
        vim.notify('File does not exist on disk: ' .. item.relpath, vim.log.levels.WARN)
    end
end

local function show_diff()
    local item = current_item()
    if not item then
        return
    end

    if vim.fn.filereadable(item.abs_path) ~= 1 then
        vim.notify('Cannot diff missing file on disk: ' .. item.relpath, vim.log.levels.WARN)
        return
    end

    vim.schedule(function()
        git_vdiffsplit(item.abs_path)
    end)
end

local function revert_file()
    local item = current_item()
    if not item then
        return
    end

    if item.untracked then
        vim.ui.input({ prompt = 'Delete untracked ' .. item.relpath .. '? (y/N): ' }, function(input)
            if not (input and input:lower() == 'y') then
                return
            end
            local is_dir = vim.fn.isdirectory(item.abs_path) == 1
            local ok = vim.fn.delete(item.abs_path, is_dir and 'rf' or '') == 0
            if ok then
                vim.notify('Git: removed untracked ' .. item.relpath, vim.log.levels.INFO)
                show_window()
            else
                vim.notify('Git: failed removing ' .. item.relpath, vim.log.levels.ERROR)
            end
        end)
        return
    end

    vim.ui.input({ prompt = 'Revert all changes in ' .. item.relpath .. '? (y/N): ' }, function(input)
        if not (input and input:lower() == 'y') then
            return
        end

        git_cmd({ cwd = item.root, cmd = 'restore --source=HEAD --staged --worktree -- ' .. vim.fn.shellescape(item.relpath) })
        vim.cmd('checktime')
        vim.notify('Git: reverted ' .. item.relpath, vim.log.levels.INFO)
        show_window()
    end)
end

local function toggle_stage_file()
    local entry = current_entry()
    if not entry then
        return
    end
    local item = entry.item

    -- Unstage only when acting on a row in the Staged section; otherwise stage.
    if entry.section == 'staged' then
        git_cmd({ cwd = item.root, cmd = 'restore --staged -- ' .. vim.fn.shellescape(item.relpath) })
        vim.notify('Git: unstaged ' .. item.relpath, vim.log.levels.INFO)
    else
        git_cmd({ cwd = item.root, cmd = 'add -- ' .. vim.fn.shellescape(item.relpath) })
        vim.notify('Git: staged ' .. item.relpath, vim.log.levels.INFO)
    end

    show_window()
end

local function stage_all()
    local root = current_git_root()
    git_cmd({ cwd = root, cmd = 'add -A' })
    vim.notify('Git: staged all changes', vim.log.levels.INFO)
    show_window()
end

local function unstage_all()
    local root = current_git_root()
    git_cmd({ cwd = root, cmd = 'reset -q HEAD --' })
    vim.notify('Git: unstaged all changes', vim.log.levels.INFO)
    show_window()
end

local function discard_all()
    local root = current_git_root()
    vim.ui.input({ prompt = 'Discard ALL changes and remove untracked files? (y/N): ' }, function(input)
        if not (input and input:lower() == 'y') then
            return
        end
        git_cmd({ cwd = root, cmd = 'reset -q HEAD --' })
        git_cmd({ cwd = root, cmd = 'checkout -- .' })
        git_cmd({ cwd = root, cmd = 'clean -fd' })
        vim.cmd('checktime')
        vim.notify('Git: discarded all changes', vim.log.levels.INFO)
        show_window()
    end)
end

local function commit_changes()
    local root = current_git_root()
    if not has_staged_changes(root) then
        vim.notify('Git: no staged changes to commit', vim.log.levels.WARN)
        return
    end

    vim.ui.input({ prompt = 'Commit message: ' }, function(input)
        if not input or input == '' then
            return
        end

        local ok, result = pcall(git_cmd, {
            cwd = root,
            cmd = 'commit -m ' .. vim.fn.shellescape(input),
        })

        if not ok then
            vim.notify(result, vim.log.levels.ERROR)
            return
        end

        local summary = result[1] or 'commit created'
        vim.notify('Git: ' .. summary, vim.log.levels.INFO)
        show_window()
    end)
end

local function open_lazygit()
    local root = current_git_root()
    if vim.fn.executable('lazygit') == 0 then
        vim.notify('Git: lazygit is not installed', vim.log.levels.WARN)
        return
    end

    local term_win = utils.get_current_window()
    local previous_buf = vim.api.nvim_get_current_buf()
    local previous_name = vim.api.nvim_buf_get_name(previous_buf)

    vim.cmd('enew')
    local term_buf = vim.api.nvim_get_current_buf()
    vim.bo[term_buf].bufhidden = 'wipe'
    vim.api.nvim_buf_set_name(term_buf, 'lazygit://' .. root)

    vim.fn.termopen('lazygit', {
        cwd = root,
        on_exit = function()
            vim.schedule(function()
                local win = utils.find_window_by_buffer(term_buf) or term_win
                utils.dismiss_buffer_window(win, term_buf)
            end)
        end,
    })
    vim.cmd('startinsert')

    if previous_name:find(BUFFER_NAME, 1, true) then
        pcall(vim.api.nvim_buf_delete, previous_buf, { force = true })
    end
end

local function close_git_window(buf)
    local win = utils.find_window_by_buffer(buf)
    utils.dismiss_buffer_window(win, buf)
end

local function initialize_buffer()
    local buf = utils.create_scratch_buffer(BUFFER_NAME, false)
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }

    vim.keymap.set('n', '<CR>', input_action, opts)
    vim.keymap.set('n', 'd', show_diff, opts)
    vim.keymap.set('n', 'r', revert_file, opts)
    vim.keymap.set('n', 's', toggle_stage_file, opts)
    vim.keymap.set('n', 'a', stage_all, opts)
    vim.keymap.set('n', 'A', unstage_all, opts)
    vim.keymap.set('n', 'D', discard_all, opts)
    vim.keymap.set('n', 'c', commit_changes, opts)
    vim.keymap.set('n', 'g', open_lazygit, opts)
    vim.keymap.set('n', 'q', function()
        close_git_window(buf)
    end, opts)

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

    push('[Enter=open d=diff r=revert s=stage a=stage-all A=unstage-all D=discard-all c=commit g=lazygit q=close]',
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
        IGNORED = 'Comment',
    }

    for i, line in ipairs(lines) do
        local line_idx = i - 1
        local entry = INDEX_MAP[i]

        if line:match('^Git Review:') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, #line)
        elseif entry and entry.type == 'section' then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, #line)
        elseif entry and entry.type == 'file' then
            local badge_start, badge_finish, badge = line:find('%[ (%S+)%s*%]')
            if badge_start then
                local hl = badge_hl[badge] or 'Keyword'
                vim.api.nvim_buf_add_highlight(buf, ns_id, hl, line_idx, badge_start - 1, badge_finish)
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Normal', line_idx, badge_finish, #line)
            end
        elseif line:match('^%[Enter=') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
        elseif line:match('^Working tree clean') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
        end
    end
end

show_window = function()
    local root = current_git_root()

    local saved_cursor_pos = nil
    local buffer = utils.find_buffer_by_name(BUFFER_NAME)
    if buffer then
        local win = utils.find_window_by_buffer(buffer)
        if win then
            saved_cursor_pos = utils.get_cursor_position(win)
        end
    else
        buffer = initialize_buffer()
    end

    -- Take over as main window
    local target_win = utils.close_other_windows()

    local changes = get_git_changes(root)
    GIT_CHANGES = changes

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

vim.api.nvim_create_user_command('GitWindow', show_window, { desc = 'Git: Show changed files' })
vim.api.nvim_create_user_command('GitLazyGit', open_lazygit, { desc = 'Git: Open lazygit' })
vim.api.nvim_create_user_command('GitDiff', function()
    local file = vim.fn.expand('%:p')
    if file == '' then
        vim.notify('Git: no file in current buffer', vim.log.levels.WARN)
        return
    end
    git_vdiffsplit(file)
end, { desc = 'Git: Diff current file against HEAD' })

vim.keymap.set('n', '<leader>gs', show_window, { desc = 'Git: Show changed files' })
vim.keymap.set('n', '<leader>gg', open_lazygit, { desc = 'Git: Open lazygit' })
vim.keymap.set('n', '<leader>gd', function()
    local file = vim.fn.expand('%:p')
    if file == '' then
        vim.notify('Git: no file in current buffer', vim.log.levels.WARN)
        return
    end
    git_vdiffsplit(file)
end, { desc = 'Git: Diff current file against HEAD' })
