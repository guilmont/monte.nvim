-- Align selected lines by a vim regexp

local utils = require('custom.utils')

--- Pad lines so the first match of `pattern` starts at the same column in all of them.
--- Lines without a match are left untouched.
local function align_by_pattern(line1, line2, pattern)
    local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)

    local pre_parts   = {}
    local pre_widths  = {}
    local match_parts = {}
    local post_parts  = {}
    local has_match   = {}
    local match_col   = 0

    for i, line in ipairs(lines) do
        -- vim.fn.match / matchend use vim regex and return 0-based indices (-1 = no match)
        local ms = vim.fn.match(line, pattern)
        local me = vim.fn.matchend(line, pattern)
        if ms >= 0 then
            local trimmed = line:sub(1, ms):gsub('%s+$', '')  -- strip trailing whitespace before delimiter
            -- Keep the indentation when only whitespace precedes the delimiter
            local indent_only = trimmed == ''
            local pre = indent_only and line:sub(1, ms) or trimmed
            pre_parts[i]   = pre
            -- Display width, so multibyte characters and tabs line up
            pre_widths[i]  = vim.fn.strdisplaywidth(pre)
            match_parts[i] = line:sub(ms + 1, me)
            post_parts[i]  = line:sub(me + 1)
            has_match[i]   = true
            -- +1 ensures at least one space between text and the delimiter
            match_col = math.max(match_col, pre_widths[i] + (indent_only and 0 or 1))
        else
            has_match[i] = false
        end
    end

    local new_lines = {}
    for i, line in ipairs(lines) do
        if has_match[i] then
            local padding = string.rep(' ', match_col - pre_widths[i])
            new_lines[i] = pre_parts[i] .. padding .. match_parts[i] .. post_parts[i]
        else
            new_lines[i] = line
        end
    end

    vim.api.nvim_buf_set_lines(0, line1 - 1, line2, false, new_lines)
end

-- Align, reporting a bad pattern instead of raising
local function try_align(line1, line2, pattern)
    local ok, err = pcall(align_by_pattern, line1, line2, pattern)
    if not ok then
        utils.notify_error('Align: ', err)
    end
end

local function prompt_and_align(line1, line2)
    vim.ui.input({ prompt = 'Align by pattern: ' }, function(pattern)
        if not pattern or pattern == '' then return end
        try_align(line1, line2, pattern)
    end)
end

vim.api.nvim_create_user_command('Align', function(opts)
    if opts.args ~= '' then
        try_align(opts.line1, opts.line2, opts.args)
    else
        prompt_and_align(opts.line1, opts.line2)
    end
end, { range = true, nargs = '?', desc = 'Align selected lines by vim regexp' })
