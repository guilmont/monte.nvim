-- Align selected lines by a vim regexp

--- Pad lines so the first match of `pattern` starts at the same column in all of them.
--- Lines without a match are left untouched.
local function align_by_pattern(line1, line2, pattern)
    local lines = vim.api.nvim_buf_get_lines(0, line1 - 1, line2, false)

    local pre_parts   = {}
    local match_parts = {}
    local post_parts  = {}
    local has_match   = {}
    local max_pre_len = 0

    for i, line in ipairs(lines) do
        -- vim.fn.match / matchend use vim regex and return 0-based indices (-1 = no match)
        local ms = vim.fn.match(line, pattern)
        local me = vim.fn.matchend(line, pattern)
        if ms >= 0 then
            local pre = line:sub(1, ms):gsub('%s+$', '')  -- strip trailing whitespace before delimiter
            pre_parts[i]   = pre
            match_parts[i] = line:sub(ms + 1, me)
            post_parts[i]  = line:sub(me + 1)
            has_match[i]   = true
            if #pre > max_pre_len then
                max_pre_len = #pre
            end
        else
            has_match[i] = false
        end
    end

    local new_lines = {}
    for i, line in ipairs(lines) do
        if has_match[i] then
            -- +1 ensures at least one space before the delimiter
            local padding = string.rep(' ', max_pre_len - #pre_parts[i] + 1)
            new_lines[i] = pre_parts[i] .. padding .. match_parts[i] .. post_parts[i]
        else
            new_lines[i] = line
        end
    end

    vim.api.nvim_buf_set_lines(0, line1 - 1, line2, false, new_lines)
end

local function prompt_and_align(line1, line2)
    vim.ui.input({ prompt = 'Align by pattern: ' }, function(pattern)
        if not pattern or pattern == '' then return end
        local ok, err = pcall(align_by_pattern, line1, line2, pattern)
        if not ok then
            vim.notify('Align: ' .. tostring(err), vim.log.levels.ERROR)
        end
    end)
end

vim.api.nvim_create_user_command('Align', function(opts)
    if opts.args ~= '' then
        local ok, err = pcall(align_by_pattern, opts.line1, opts.line2, opts.args)
        if not ok then
            vim.notify('Align: ' .. tostring(err), vim.log.levels.ERROR)
        end
    else
        prompt_and_align(opts.line1, opts.line2)
    end
end, { range = true, nargs = '?', desc = 'Align selected lines by vim regexp' })
