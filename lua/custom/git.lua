local diffsplit = require('custom.diffsplit')
local utils = require('custom.utils')

local BUFFER_NAME = 'Git Window'
local INDEX_MAP = {}
local GIT_CHANGES = {}
local STATUS_COLUMN_WIDTH = 13
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
    return out[1]
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

local function file_exists_in_head(root, relpath)
    local ok = pcall(git_cmd, {
        cwd = root,
        cmd = 'cat-file -e ' .. vim.fn.shellescape('HEAD:' .. relpath),
    })
    return ok
end

local function git_vdiffsplit(file)
    local root = get_git_root(file)
    local relpath = relative_to_root(root, file)

    local base_content = {}
    local left_name = 'Git HEAD (empty)'

    if file_exists_in_head(root, relpath) then
        base_content = git_cmd({ cwd = root, cmd = 'cat-file -p ' .. vim.fn.shellescape('HEAD:' .. relpath) })
        left_name = 'Git HEAD:' .. relpath
    end

    diffsplit.open_file_diffsplit({
        filepath = file,
        left_content = base_content,
        left_name = left_name,
        notify_message = 'Git Diff: [ / ] jump hunks, r reverts hunk, q closes base, Q closes both',
    })
end

local function parse_status_line(root, line)
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

    local absolute_path = root .. '/' .. relpath
    local is_untracked = x == '?' and y == '?'
    local is_staged = not is_untracked and x ~= ' '
    local is_unstaged = not is_untracked and y ~= ' '

    return {
        root = root,
        relpath = relpath,
        abs_path = absolute_path,
        staged = is_staged,
        unstaged = is_unstaged,
        untracked = is_untracked,
        staged_label = is_staged and (STATUS_LABELS[x] or x) or nil,
        unstaged_label = is_unstaged and (STATUS_LABELS[y] or y) or nil,
    }
end

local function item_status_text(item)
    if item.untracked then
        return 'UNTRACKED'
    end

    local parts = {}
    if item.staged and item.staged_label then
        table.insert(parts, 'INDEX:' .. item.staged_label)
    end
    if item.unstaged and item.unstaged_label then
        table.insert(parts, 'WORKTREE:' .. item.unstaged_label)
    end
    if #parts == 0 then
        table.insert(parts, 'UNCHANGED')
    end

    return table.concat(parts, ' | ')
end

local function get_git_changes(root)
    local lines = git_cmd({ cwd = root, cmd = 'status --porcelain=v1' })
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

local function current_item()
    local line = get_action_line()
    local data = INDEX_MAP[line]
    if not data or data.type ~= 'file' then
        return nil
    end
    return data.item
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
    local item = current_item()
    if not item then
        return
    end

    if item.staged then
        git_cmd({ cwd = item.root, cmd = 'restore --staged -- ' .. vim.fn.shellescape(item.relpath) })
        vim.notify('Git: unstaged ' .. item.relpath, vim.log.levels.INFO)
    else
        git_cmd({ cwd = item.root, cmd = 'add -- ' .. vim.fn.shellescape(item.relpath) })
        vim.notify('Git: staged ' .. item.relpath, vim.log.levels.INFO)
    end

    show_window()
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
                if vim.api.nvim_buf_is_valid(term_buf) then
                    pcall(vim.api.nvim_buf_delete, term_buf, { force = true })
                end
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
    if win then
        local ok = pcall(utils.close_window, win)
        if ok then
            return
        end
    end

    -- If this is the last window, :close can fail. In that case, replace the
    -- current window buffer and wipe the Git buffer.
    if vim.api.nvim_get_current_buf() == buf then
        vim.cmd('enew')
    end
    pcall(vim.api.nvim_buf_delete, buf, { force = true })
end

local function initialize_buffer()
    local buf = utils.create_scratch_buffer(BUFFER_NAME, false)
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }

    vim.keymap.set('n', '<CR>', input_action, opts)
    vim.keymap.set('n', 'd', show_diff, opts)
    vim.keymap.set('n', 'r', revert_file, opts)
    vim.keymap.set('n', 's', toggle_stage_file, opts)
    vim.keymap.set('n', 'c', commit_changes, opts)
    vim.keymap.set('n', 'g', open_lazygit, opts)
    vim.keymap.set('n', 'q', function()
        close_git_window(buf)
    end, opts)
    table.insert(lines, '[Enter=open | d=diff | r=revert | s=stage/unstage | c=commit | g=lazygit | q=close]')

    return buf
end

local function setup_display_lines(root)
    INDEX_MAP = {}

    local lines = {
        'Git Review: ' .. root,
        '',
    }
    table.insert(INDEX_MAP, { type = 'header' })
    table.insert(INDEX_MAP, { type = 'separator' })

    if #GIT_CHANGES == 0 then
        table.insert(lines, 'Working tree clean.')
        table.insert(INDEX_MAP, { type = 'info' })
    else
        local row_fmt = '[ %-' .. STATUS_COLUMN_WIDTH .. 's] %s'
        for _, item in ipairs(GIT_CHANGES) do
            table.insert(lines, string.format(row_fmt, item_status_text(item), item.relpath))
            table.insert(INDEX_MAP, { type = 'file', item = item })
        end
    end

    table.insert(lines, '')
    table.insert(lines, '[Enter=open | d=diff | r=revert | s=stage/unstage | c=commit | q=close]')
    table.insert(INDEX_MAP, { type = 'separator' })
    table.insert(INDEX_MAP, { type = 'help' })

    return lines
end

local function apply_syntax_highlighting(buf)
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

    local ns_id = vim.api.nvim_create_namespace('GitWindowHighlight')
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    for i, line in ipairs(lines) do
        local line_idx = i - 1

        if line:match('^Git Review:') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, #line)
        elseif line:match('^%[[^%]]+%] ') then
            local status_end = line:find('%]')
            if status_end then
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, status_end)
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'String', line_idx, status_end + 1, #line)
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

    local changes = get_git_changes(root)
    GIT_CHANGES = changes

    local lines = setup_display_lines(root)

    local win = utils.reuse_or_create_window_for_buffer(buffer)
    utils.set_buffer_lines(buffer, 0, -1, lines)
    apply_syntax_highlighting(buffer)

    utils.set_current_window(win)
    if saved_cursor_pos then
        pcall(utils.set_cursor_position, win, saved_cursor_pos.line, saved_cursor_pos.col)
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
