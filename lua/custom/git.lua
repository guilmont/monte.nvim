local diffsplit = require('custom.diffsplit')

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

local function get_git_root(file)
    local dir = vim.fn.fnamemodify(file, ':h')
    local out = git_cmd({ cwd = dir, cmd = 'rev-parse --show-toplevel' })
    if not out or not out[1] or out[1] == '' then
        error('Could not determine git repository root for ' .. file)
    end
    return out[1]
end

local function relative_to_root(root, file)
    if file:sub(1, #root + 1) == root .. '/' then
        return file:sub(#root + 2)
    end
    return vim.fn.fnamemodify(file, ':t')
end

local function file_exists_in_head(root, relpath)
    local cmd = 'git -C ' .. vim.fn.shellescape(root)
        .. ' cat-file -e ' .. vim.fn.shellescape('HEAD:' .. relpath) .. ' 2>/dev/null'
    vim.fn.system(cmd)
    return vim.v.shell_error == 0
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

vim.api.nvim_create_user_command('GitDiff', function()
    git_vdiffsplit(vim.fn.expand('%:p'))
end, { desc = 'Git: Diff current file against HEAD' })

vim.keymap.set('n', '<leader>gd', function()
    git_vdiffsplit(vim.fn.expand('%:p'))
end, { desc = 'Git: Diff current file against HEAD' })
