--- Common utility functions for handling windows and buffers in Neovim.

-- Module table to hold all utility functions.
local M = {}

-- ========================================================================
-- Buffer utilities
-- ========================================================================

-- Find buffer ID by name and return its ID.
function M.find_buffer_by_name(name)
    local buffers = vim.api.nvim_list_bufs()
    for _, bufnr in ipairs(buffers) do
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name:find(name, 1, true) then
            return bufnr
        end
    end
    return nil
end

-- Find buffer by filename and return its ID.
function M.find_buffer_by_filename(filename)
    local buffers = vim.api.nvim_list_bufs()
    for _, bufnr in ipairs(buffers) do
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        local stem = vim.fn.fnamemodify(buf_name, ":t")
        if stem:match(filename) then
            return bufnr
        end
    end
    return nil
end

-- Create a new scratch buffer with a given name and return its ID.
function M.create_scratch_buffer(name, modifiable)
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.bo[bufnr].modifiable = modifiable
    return bufnr
end

-- Check if a buffer is valid and loaded.
function M.is_buffer_valid(bufnr)
    return vim.api.nvim_buf_is_valid(bufnr) and vim.api.nvim_buf_is_loaded(bufnr)
end

-- Check if a buffer is displayed in any window.
function M.is_buffer_displayed(bufnr)
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
        local win_bufnr = vim.api.nvim_win_get_buf(win)
        if win_bufnr == bufnr then
            return true
        end
    end
    return false
end

-- Remove a buffer by its ID.
function M.remove_buffer(bufnr)
    vim.api.nvim_buf_delete(bufnr, { force = true })
end

-- Remove a buffer by its name.
function M.remove_buffer_by_name(name)
    local bufnr = M.find_buffer_by_name(name)
    if bufnr then
        M.remove_buffer(bufnr)
    end
end

-- Get buffer line count for a given buffer ID.
function M.get_buffer_line_count(bufnr)
    if M.is_buffer_valid(bufnr) then
        return vim.api.nvim_buf_line_count(bufnr)
    end
    return 0
end

-- Get buffer lines for a given buffer ID. Returns nil if buffer is invalid.
-- Note that start and end_ are zero-indexed and end_ is exclusive.
-- Errors if indices are out of range. Lines are returned as a list of strings.
function M.get_buffer_lines(bufnr, start, end_)
    if M.is_buffer_valid(bufnr) then
        return vim.api.nvim_buf_get_lines(bufnr, start, end_, true)
    end
    return nil
end

-- Set buffer lines for a given buffer ID.
-- Note that start and end_ are zero-indexed and end_ is exclusive.
-- Errors if indices are out of range. Lines should be a list of strings.
function M.set_buffer_lines(bufnr, start, end_, lines)
    if M.is_buffer_valid(bufnr) then
        local is_modifiable = vim.bo[bufnr].modifiable
        if not is_modifiable then
            vim.bo[bufnr].modifiable = true
        end
        vim.api.nvim_buf_set_lines(bufnr, start, end_, true, lines)
        if not is_modifiable then
            vim.bo[bufnr].modifiable = false
        end
    end
end

-- Reset buffer content by its ID.
function M.reset_buffer_content(bufnr)
    M.set_buffer_lines(bufnr, 0, -1, {})
end

-- ========================================================================
-- Window utilities
-- ========================================================================

-- Detect window containing the initial empty buffer and return Id, otherwise nil.
function M.find_empty_buffer_window()
    for _, win in ipairs(vim.api.nvim_list_wins()) do
        local buf = vim.api.nvim_win_get_buf(win)
        -- Must be listed
        if vim.bo[buf].buflisted
            -- Must be normal buffer
            and vim.bo[buf].buftype == ""
            -- Must be unnamed
            and vim.api.nvim_buf_get_name(buf) == ""
            -- Must not be modified
            and not vim.bo[buf].modified
            -- Must have exactly one line
            and vim.api.nvim_buf_line_count(buf) == 1
        then
            local line = vim.api.nvim_buf_get_lines(buf, 0, 1, false)[1]
            if line == "" then
              return win
            end
        end
    end
    return nil
end

-- Create a new window for a given buffer and return its ID.
function M.create_window_for_buffer(bufnr)
    -- Before creating a new window, check for an empty buffer window to reuse.
    local empty_winid = M.find_empty_buffer_window()
    if empty_winid then
        vim.api.nvim_win_set_buf(empty_winid, bufnr)
        M.set_current_window(empty_winid)
        return empty_winid
    end
    -- If no empty buffer window is found, split a new one.
    vim.cmd("vsplit")
    local winid = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(winid, bufnr)
    return winid
end

-- Find window by buffer number and return its ID.
function M.find_window_by_buffer(bufnr)
    local windows = vim.api.nvim_list_wins()
    for _, win in ipairs(windows) do
        local win_bufnr = vim.api.nvim_win_get_buf(win)
        if win_bufnr == bufnr then
            return win
        end
    end
    return nil
end

-- Check if a window is valid.
function M.is_window_valid(winid)
    return vim.api.nvim_win_is_valid(winid)
end

-- Reuse or create a window to given buffer.
function M.reuse_or_create_window_for_buffer(bufnr)
    local winid = M.find_window_by_buffer(bufnr)
    if winid and M.is_window_valid(winid) then
        vim.api.nvim_win_set_buf(winid, bufnr)
        M.set_current_window(winid)
        return winid
    else
        return M.create_window_for_buffer(bufnr)
    end
end

-- Check if a buffer is displayed in a specific window.
function M.is_buffer_displayed_in_window(bufnr, winid)
    if not M.is_window_valid(winid) then
        return false
    end
    local win_bufnr = vim.api.nvim_win_get_buf(winid)
    return win_bufnr == bufnr
end

-- Close a window by its ID.
function M.close_window(winid)
    if M.is_window_valid(winid) then
        vim.api.nvim_win_close(winid, true)
    end
end

-- Get the current window ID.
function M.get_current_window()
    return vim.api.nvim_get_current_win()
end

-- Set the current window to a given window ID.
function M.set_current_window(winid)
    if M.is_window_valid(winid) then
        vim.api.nvim_set_current_win(winid)
    end
end

-- Get cursor position for a given window, or current window if none provided.
function M.get_cursor_position(winid)
    if M.is_window_valid(winid) then
        local pos = vim.api.nvim_win_get_cursor(winid)
        return {line = pos[1], column = pos[2]}
    end
    return nil
end

-- Set cursor position for a given window.
function M.set_cursor_position(winid, line, column)
    if not M.is_window_valid(winid) then
        return
    end
    -- To avoid errors, ensure the line number is within the buffer's line count.
    -- Column number will be handled by Neovim and can be out of range without causing errors.
    local buf = vim.api.nvim_win_get_buf(winid)
    local line_count = vim.api.nvim_buf_line_count(buf)
    line = math.max(1, math.min(line, line_count))
    -- Set the cursor position in the specified window.
    vim.api.nvim_win_set_cursor(winid, { line, column })
end

return M
