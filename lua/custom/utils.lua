--- Common utility functions for handling windows and buffers in Neovim.

-- Module table to hold all utility functions.
local M = {}

M.is_windows = vim.fn.has('win32') == 1

-- ========================================================================
-- Buffer utilities
-- ========================================================================

-- Find buffer ID by name and return its ID.
-- Neovim expands scratch buffer names to full paths (e.g. '<cwd>/Git Window'),
-- so the name is compared against the last path component, not as a substring.
-- A loaded buffer wins over an unloaded one (eg. left by :bdelete before a :cd,
-- which keeps its old full path), so callers reuse the live buffer.
function M.find_buffer_by_name(name)
    local unloaded = nil
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        if vim.fs.basename(vim.api.nvim_buf_get_name(bufnr)) == name then
            if vim.api.nvim_buf_is_loaded(bufnr) then
                return bufnr
            end
            unloaded = unloaded or bufnr
        end
    end
    return unloaded
end

-- Normalize a file path for comparison (separators, and case on Windows).
function M.normalize_path(p)
    p = vim.fs.normalize(p)
    return M.is_windows and p:lower() or p
end

-- Absolute, symlink-free, normalized spelling of a path.
local function canonical_path(p)
    return M.normalize_path(vim.fn.resolve(vim.fn.fnamemodify(p, ':p')))
end

local function is_symlink(p)
    local stat = vim.uv.fs_lstat(p)
    return stat ~= nil and stat.type == 'link'
end

-- Find the buffer holding a file, however its name was spelled (relative,
-- symlinks, separators, case on Windows), or nil. The current buffer is checked first.
function M.find_buffer_by_path(path)
    local target = canonical_path(path)
    local current = vim.api.nvim_get_current_buf()
    local current_name = vim.api.nvim_buf_get_name(current)
    if current_name ~= '' and canonical_path(current_name) == target then
        return current
    end
    -- resolve() hits the file system, so only resolve buffers that can be the file:
    -- the same last component as the path (as given or resolved), or a symlink.
    local basenames = {
        [vim.fs.basename(M.normalize_path(path))] = true,
        [vim.fs.basename(target)] = true,
    }
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local name = vim.api.nvim_buf_get_name(bufnr)
        if bufnr ~= current and name ~= ''
            and (basenames[vim.fs.basename(M.normalize_path(name))] or is_symlink(name))
            and canonical_path(name) == target then
            return bufnr
        end
    end
    return nil
end

-- A buffer that holds work or is in view: never wiped to free its name.
local function is_buffer_in_use(bufnr)
    return vim.bo[bufnr].modified
        or M.is_buffer_displayed(bufnr)
        or (vim.bo[bufnr].buftype == 'terminal' and vim.api.nvim_buf_is_loaded(bufnr))
end

-- Free a buffer name for a new buffer by wiping the buffer holding it, such as an
-- unloaded one left by :bdelete or a stale hidden one. A buffer that is modified,
-- shown in a window (any tab) or a loaded terminal is left alone. Scratch
-- (buftype=nofile) buffers never count as modified, so a hidden one is wiped.
-- Returns true when no buffer holds the name anymore.
function M.release_buffer_name(name)
    -- Neovim stores names as full paths ('Git Window' -> '<cwd>/Git Window')
    local full = M.normalize_path(vim.fn.fnamemodify(name, ':p'))
    for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
        local buf_name = vim.api.nvim_buf_get_name(bufnr)
        if buf_name ~= '' and M.normalize_path(buf_name) == full then
            if is_buffer_in_use(bufnr) then
                return false
            end
            return (pcall(vim.api.nvim_buf_delete, bufnr, { force = true }))
        end
    end
    return true
end

-- Create a new scratch buffer with a given name and return its ID.
-- A leftover buffer with that name is wiped first (see release_buffer_name);
-- errors if the name belongs to a buffer still in use.
function M.create_scratch_buffer(name, modifiable)
    if not M.release_buffer_name(name) then
        error('Buffer "' .. name .. '" is already open', 0)
    end
    local bufnr = vim.api.nvim_create_buf(true, true)
    vim.api.nvim_buf_set_name(bufnr, name)
    vim.bo[bufnr].modifiable = modifiable
    return bufnr
end

-- Return cached_bufnr if it is still valid and loaded, otherwise a new scratch
-- buffer from create_scratch_buffer (same errors). The second result is true when
-- the buffer was just created, so the caller sets up its maps and highlighting.
function M.get_or_create_scratch_buffer(name, cached_bufnr, modifiable)
    if cached_bufnr and M.is_buffer_valid(cached_bufnr) then
        return cached_bufnr, false
    end
    return M.create_scratch_buffer(name, modifiable), true
end

-- Delete the buffers of files that are no longer on disk, so they don't keep
-- looking like normal files, then :checktime the rest. Modified buffers are kept
-- (checktime warns about them).
function M.drop_buffers_of_missing_files(paths)
    for _, path in ipairs(paths) do
        if path ~= '' and not vim.uv.fs_stat(path) then
            local bufnr = M.find_buffer_by_path(path)
            if bufnr and not vim.bo[bufnr].modified then
                pcall(vim.api.nvim_buf_delete, bufnr, { force = true })
            end
        end
    end
    vim.cmd('checktime')
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

-- Count real (non-floating, non-Neo-tree) windows in a tabpage (0 = current).
local function count_real_windows(tabpage)
    local count = 0
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(tabpage or 0)) do
        if M.is_window_valid(winid) and not is_floating_window(winid) and not is_neotree_window(winid) then
            count = count + 1
        end
    end
    return count
end

-- Check if a buffer is displayed in any window, in any tabpage.
-- Callers use this to decide whether a buffer can be deleted, so it stays global.
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

-- Detect window in the current tabpage containing the initial empty buffer and
-- return Id, otherwise nil.
function M.find_empty_buffer_window()
    for _, win in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
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

local function find_window_in(windows, bufnr)
    for _, win in ipairs(windows) do
        if vim.api.nvim_win_get_buf(win) == bufnr then
            return win
        end
    end
    return nil
end

-- Find window by buffer number and return its ID.
-- Prefers a window in the current tabpage, then falls back to other tabpages.
function M.find_window_by_buffer(bufnr)
    return find_window_in(vim.api.nvim_tabpage_list_wins(0), bufnr)
        or find_window_in(vim.api.nvim_list_wins(), bufnr)
end

-- Find another real window in the current tabpage to reuse, excluding the provided window ID.
function M.find_alternate_real_window(excluded_winid)
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
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

-- Close all windows in the current tabpage except Neo-tree.
-- Returns one surviving real window to reuse, or nil.
function M.close_other_windows()
    local target_win
    for _, winid in ipairs(vim.api.nvim_tabpage_list_wins(0)) do
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

-- Reuse a window in the current tabpage showing the given buffer, or create one.
function M.reuse_or_create_window_for_buffer(bufnr)
    local winid = find_window_in(vim.api.nvim_tabpage_list_wins(0), bufnr)
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

    if count_real_windows(vim.api.nvim_win_get_tabpage(winid)) > 1 then
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

-- ========================================================================
-- User interaction
-- ========================================================================

-- Ask a y/N question; on_yes runs only when the answer is y or Y.
function M.confirm(prompt, on_yes)
    vim.ui.input({ prompt = prompt }, function(input)
        if input and input:lower() == 'y' then
            on_yes()
        end
    end)
end

-- Show an error, e.g. one caught with pcall: notify_error('Git: ', err).
function M.notify_error(prefix, err)
    vim.notify(prefix .. vim.trim(tostring(err)), vim.log.levels.ERROR)
end

return M
