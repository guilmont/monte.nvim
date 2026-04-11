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

local function is_empty_normal_buffer(bufnr)
    return vim.bo[bufnr].buflisted
        and vim.bo[bufnr].buftype == ""
        and vim.api.nvim_buf_get_name(bufnr) == ""
        and not vim.bo[bufnr].modified
        and vim.api.nvim_buf_line_count(bufnr) == 1
        and vim.api.nvim_buf_get_lines(bufnr, 0, 1, false)[1] == ""
end

local function is_reusable_normal_buffer(bufnr, excluded_bufnr)
    if not bufnr or bufnr == 0 or bufnr == excluded_bufnr then
        return false
    end
    if not vim.api.nvim_buf_is_valid(bufnr) then
        return false
    end
    if vim.bo[bufnr].buftype ~= '' or not vim.bo[bufnr].buflisted then
        return false
    end

    if is_empty_normal_buffer(bufnr) then
        return false
    end
    return true
end

local function remember_window_buffer(winid, bufnr)
    if not M.is_window_valid(winid) or not M.is_buffer_valid(bufnr) then
        return
    end

    local current_buf = vim.api.nvim_win_get_buf(winid)
    if is_reusable_normal_buffer(current_buf, bufnr) then
        vim.w[winid].previous_normal_buffer = current_buf
    end
end

local function get_replacement_buffer(winid, excluded_bufnr)
    if M.is_window_valid(winid) then
        local previous_buf = vim.w[winid].previous_normal_buffer
        if is_reusable_normal_buffer(previous_buf, excluded_bufnr) then
            return previous_buf
        end
    end

    local alternate_buf = vim.fn.bufnr('#')
    if is_reusable_normal_buffer(alternate_buf, excluded_bufnr) then
        return alternate_buf
    end

    local bufinfo = vim.fn.getbufinfo({ buflisted = 1 })
    table.sort(bufinfo, function(a, b)
        return (a.lastused or 0) > (b.lastused or 0)
    end)
    for _, info in ipairs(bufinfo) do
        if is_reusable_normal_buffer(info.bufnr, excluded_bufnr) then
            return info.bufnr
        end
    end

    return nil
end

local function is_floating_window(winid)
    return vim.api.nvim_win_get_config(winid).relative ~= ''
end

local function is_neotree_window(winid)
    local bufnr = vim.api.nvim_win_get_buf(winid)
    return vim.bo[bufnr].filetype == 'neo-tree'
end

local function count_real_windows()
    local count = 0
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if M.is_window_valid(winid) and not is_floating_window(winid) and not is_neotree_window(winid) then
            count = count + 1
        end
    end
    return count
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
        if is_empty_normal_buffer(buf) then
            return win
        end
    end
    return nil
end

-- Create a new window for a given buffer and return its ID.
function M.create_window_for_buffer(bufnr)
    -- Before creating a new window, check for an empty buffer window to reuse.
    local empty_winid = M.find_empty_buffer_window()
    if empty_winid then
        remember_window_buffer(empty_winid, bufnr)
        vim.api.nvim_win_set_buf(empty_winid, bufnr)
        M.set_current_window(empty_winid)
        return empty_winid
    end
    -- If no empty buffer window is found, split a new one.
    vim.cmd("vsplit")
    local winid = vim.api.nvim_get_current_win()
    remember_window_buffer(winid, bufnr)
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

-- Find another real window to reuse, excluding the provided window ID.
function M.find_alternate_real_window(excluded_winid)
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if M.is_window_valid(winid)
            and winid ~= excluded_winid
            and not is_floating_window(winid)
            and not is_neotree_window(winid) then
            return winid
        end
    end
    return nil
end

-- Check if a window is valid.
function M.is_window_valid(winid)
    return vim.api.nvim_win_is_valid(winid)
end

-- Close all windows except Neo-tree.
-- Returns one surviving real window to reuse, or nil.
function M.close_other_windows()
    local target_win
    for _, winid in ipairs(vim.api.nvim_list_wins()) do
        if M.is_window_valid(winid) then
            if is_neotree_window(winid) then
                -- keep
            elseif not target_win and not is_floating_window(winid) then
                target_win = winid
            else
                vim.api.nvim_win_close(winid, true)
            end
        end
    end
    return target_win
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

-- Close a window by its ID.
function M.close_window(winid)
    if M.is_window_valid(winid) then
        vim.api.nvim_win_close(winid, true)
    end
end

-- Replace a tool window with the previous real buffer, or an empty buffer if none exists.
function M.dismiss_buffer_window(winid, bufnr)
    if not M.is_window_valid(winid) then
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not M.is_buffer_displayed(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        return
    end

    if count_real_windows() > 1 then
        M.close_window(winid)
        if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not M.is_buffer_displayed(bufnr) then
            pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
        end
        return
    end

    local replacement = get_replacement_buffer(winid, bufnr)
    if replacement then
        vim.api.nvim_win_set_buf(winid, replacement)
        vim.w[winid].previous_normal_buffer = nil
    else
        vim.api.nvim_win_call(winid, function()
            vim.cmd('enew')
        end)
        vim.w[winid].previous_normal_buffer = nil
    end

    if bufnr and vim.api.nvim_buf_is_valid(bufnr) and not M.is_buffer_displayed(bufnr) then
        pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
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

-- Set buffer for a given window ID.
function M.set_window_buffer(winid, bufnr)
    if M.is_window_valid(winid) and M.is_buffer_valid(bufnr) then
        remember_window_buffer(winid, bufnr)
        vim.api.nvim_win_set_buf(winid, bufnr)
    end
end

-- Get buffer for a given window ID. Returns nil if window is invalid.
function M.get_window_buffer(winid)
    if M.is_window_valid(winid) then
        return vim.api.nvim_win_get_buf(winid)
    end
    return nil
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
