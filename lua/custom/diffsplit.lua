local utils = require('custom.utils')

local M = {}

-- Open a temporary left buffer in diff mode against a real file on the right.
function M.open_file_diffsplit(args)
    if not args or not args.filepath or args.filepath == '' then
        error('No filepath provided for diffsplit')
    end

    local filepath = args.filepath
    local left_content = args.left_content or {}
    local left_name = args.left_name or 'Diff Base'

    if vim.fn.expand('%:p') ~= filepath then
        vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
    end

    local right_win = utils.get_current_window()
    local right_buf = utils.get_window_buffer(right_win)

    local left_buf = vim.api.nvim_create_buf(false, true)
    local ft = vim.filetype.match({ filename = filepath }) or ''
    vim.bo[left_buf].filetype = ft
    vim.bo[left_buf].buftype = 'nofile'
    vim.bo[left_buf].bufhidden = 'wipe'
    vim.api.nvim_buf_set_name(left_buf, left_name)
    vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, left_content)
    vim.bo[left_buf].modifiable = false

    -- Open split on the left so sidebars remain leftmost.
    vim.cmd('leftabove vsplit')
    local left_win = utils.get_current_window()
    utils.set_window_buffer(left_win, left_buf)

    vim.api.nvim_win_call(left_win, function() vim.cmd('diffthis') end)
    vim.wo[left_win].scrollbind = true
    vim.wo[left_win].cursorbind = true

    vim.api.nvim_win_call(right_win, function() vim.cmd('diffthis') end)
    vim.wo[right_win].scrollbind = true
    vim.wo[right_win].cursorbind = true

    local function close_diff()
        pcall(vim.api.nvim_win_call, left_win, function() vim.cmd('diffoff') end)
        pcall(utils.close_window, left_win)
        pcall(utils.remove_buffer, left_buf)

        pcall(vim.api.nvim_win_call, right_win, function() vim.cmd('diffoff') end)
        if vim.api.nvim_win_is_valid(right_win) then
            pcall(function()
                vim.wo[right_win].scrollbind = false
                vim.wo[right_win].cursorbind = false
                utils.set_current_window(right_win)
            end)
        end
    end

    local function close_both()
        pcall(vim.api.nvim_win_call, left_win, function() vim.cmd('diffoff') end)
        pcall(utils.close_window, left_win)
        pcall(utils.remove_buffer, left_buf)

        pcall(vim.api.nvim_win_call, right_win, function() vim.cmd('diffoff') end)
        pcall(utils.close_window, right_win)
        pcall(utils.remove_buffer, right_buf)
    end

    local function revert_hunk()
        if vim.api.nvim_win_is_valid(right_win) then
            vim.api.nvim_win_call(right_win, function()
                vim.cmd('diffget')
            end)
        end
    end

    local function jump_prev_hunk()
        if vim.api.nvim_win_is_valid(right_win) then
            vim.api.nvim_win_call(right_win, function()
                vim.cmd('normal! [c')
            end)
        end
    end

    local function jump_next_hunk()
        if vim.api.nvim_win_is_valid(right_win) then
            vim.api.nvim_win_call(right_win, function()
                vim.cmd('normal! ]c')
            end)
        end
    end

    vim.api.nvim_create_autocmd('WinClosed', {
        callback = function(event)
            local closed = tonumber(event.match)
            if closed == left_win then
                vim.schedule(close_diff)
            end
        end,
        once = true,
    })

    local map_opts = { nowait = true, noremap = true, silent = true }
    vim.keymap.set('n', 'q', close_diff, vim.tbl_extend('force', map_opts, { buffer = left_buf }))
    vim.keymap.set('n', 'q', close_diff, vim.tbl_extend('force', map_opts, { buffer = right_buf }))
    vim.keymap.set('n', 'Q', close_both, vim.tbl_extend('force', map_opts, { buffer = left_buf }))
    vim.keymap.set('n', 'Q', close_both, vim.tbl_extend('force', map_opts, { buffer = right_buf }))
    vim.keymap.set('n', 'r', revert_hunk, vim.tbl_extend('force', map_opts, { buffer = left_buf }))
    vim.keymap.set('n', 'r', revert_hunk, vim.tbl_extend('force', map_opts, { buffer = right_buf }))
    vim.keymap.set('n', '[', jump_prev_hunk, vim.tbl_extend('force', map_opts, { buffer = left_buf }))
    vim.keymap.set('n', '[', jump_prev_hunk, vim.tbl_extend('force', map_opts, { buffer = right_buf }))
    vim.keymap.set('n', ']', jump_next_hunk, vim.tbl_extend('force', map_opts, { buffer = left_buf }))
    vim.keymap.set('n', ']', jump_next_hunk, vim.tbl_extend('force', map_opts, { buffer = right_buf }))

    if args.notify_message and args.notify_message ~= '' then
        vim.notify(args.notify_message, vim.log.levels.INFO)
    end
end

return M
