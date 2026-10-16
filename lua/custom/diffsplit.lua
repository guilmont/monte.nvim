local utils = require('custom.utils')

local M = {}

-- Normal-mode keys mapped on both diff buffers while the diff is open.
local DIFF_KEYS = { 'q', 'Q', 'r', '[', ']' }

-- Open a temporary left buffer in diff mode against a real file on the right.
function M.open_file_diffsplit(args)
    if not args or not args.filepath or args.filepath == '' then
        error('No filepath provided for diffsplit')
    end

    local filepath = args.filepath
    local left_content = args.left_content or {}
    local left_name = args.left_name or 'Diff Base'

    -- systemlist() splits on \n only, so blobs with CRLF line endings keep a
    -- trailing \r on every line. The working buffer on the right renders per its
    -- own 'fileformat' and never shows that \r, so the diff engine flags every
    -- line as changed (blue DiffText) even though both sides look identical.
    -- Strip the trailing \r so the comparison matches what the user sees.
    for i, line in ipairs(left_content) do
        left_content[i] = (line:gsub('\r$', ''))
    end

    -- Capture whatever buffer was in the window before we possibly replace it
    -- so close_both can restore it (e.g. return to the git window) instead of closing nvim.
    local prev_buf = vim.api.nvim_win_get_buf(vim.api.nvim_get_current_win())

    -- Reuse the file's buffer if it has one, however its name is spelled (symlinks,
    -- separators, case), or :edit on the current modified buffer fails (E37).
    local existing_buf = utils.find_buffer_by_path(filepath)
    -- close_both only deletes the file buffer if the diff is what loaded it
    local right_was_loaded = existing_buf ~= nil and vim.api.nvim_buf_is_loaded(existing_buf)
    if existing_buf then
        if existing_buf ~= vim.api.nvim_get_current_buf() then
            vim.api.nvim_win_set_buf(0, existing_buf)
        end
    else
        vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
    end

    local right_win = utils.get_current_window()
    local right_buf = utils.get_window_buffer(right_win)
    -- If the window already showed the target file, prev_buf is irrelevant
    if prev_buf == right_buf then prev_buf = nil end

    -- Restored on close; :diffoff doesn't know their values from before the diff.
    local saved_opts = {
        scrollbind = vim.wo[right_win].scrollbind,
        cursorbind = vim.wo[right_win].cursorbind,
    }

    -- The file's own buffer-local maps on the diff keys, restored on close.
    local saved_maps = {}
    vim.api.nvim_buf_call(right_buf, function()
        for _, key in ipairs(DIFF_KEYS) do
            local map = vim.fn.maparg(key, 'n', false, true)
            if map.buffer == 1 then
                saved_maps[key] = map
            end
        end
    end)

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

    local winclosed_id
    local closed = false

    -- Turn diff mode off in a window and put back its options from before the diff.
    local function restore_window(winid)
        if not vim.api.nvim_win_is_valid(winid) then
            return
        end
        pcall(vim.api.nvim_win_call, winid, function() vim.cmd('diffoff') end)
        pcall(function()
            vim.wo[winid].scrollbind = saved_opts.scrollbind
            vim.wo[winid].cursorbind = saved_opts.cursorbind
        end)
    end

    -- Remove diff-only keymaps from the real file buffer and put back the user's own.
    local function restore_file_maps()
        if not vim.api.nvim_buf_is_valid(right_buf) then
            return
        end
        for _, key in ipairs(DIFF_KEYS) do
            pcall(vim.keymap.del, 'n', key, { buffer = right_buf })
        end
        pcall(vim.api.nvim_buf_call, right_buf, function()
            for _, map in pairs(saved_maps) do
                vim.fn.mapset('n', false, map)
            end
        end)
    end

    local function close_diff()
        if closed then
            return
        end
        closed = true
        pcall(vim.api.nvim_del_autocmd, winclosed_id)

        restore_window(right_win)
        -- Closes the base window, or swaps the file back in if it's the last one left
        -- (the right pane was closed with :q). In that case left_win now shows the
        -- file, so give it the file window's options from before the diff; once
        -- left_win is closed, restore_window does nothing.
        pcall(utils.dismiss_buffer_window, left_win, left_buf)
        restore_window(left_win)
        if vim.api.nvim_win_is_valid(right_win) then
            utils.set_current_window(right_win)
        end
        restore_file_maps()
    end

    local function close_both()
        close_diff()
        if not vim.api.nvim_buf_is_valid(right_buf) then
            return
        end

        if vim.api.nvim_win_is_valid(right_win) and vim.api.nvim_win_get_buf(right_win) == right_buf then
            if prev_buf and vim.api.nvim_buf_is_valid(prev_buf) then
                -- Restore the buffer that was here before the diff opened (e.g. the git window).
                -- This avoids closing nvim when right_win is the last real window.
                vim.api.nvim_win_set_buf(right_win, prev_buf)
                utils.set_current_window(right_win)
            elseif vim.bo[right_buf].modified then
                -- Keep a file with unsaved edits in view
                return
            else
                -- No bufnr: the window goes away but the user's buffer is kept
                utils.dismiss_buffer_window(right_win)
            end
        end

        -- Only drop the file buffer if the diff loaded it and nothing else needs it
        if not right_was_loaded
            and not vim.bo[right_buf].modified
            and not utils.is_buffer_displayed(right_buf) then
            pcall(vim.api.nvim_buf_delete, right_buf, {})
        end
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

    -- Clean up when either pane is closed with :q / :close. Other windows (e.g. an
    -- LSP hover float) close too, so this only removes itself once it has handled one.
    winclosed_id = vim.api.nvim_create_autocmd('WinClosed', {
        callback = function(event)
            local closed_win = tonumber(event.match)
            if closed_win == left_win or closed_win == right_win then
                vim.schedule(close_diff)
                return true
            end
        end,
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
