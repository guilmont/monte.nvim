-- Async command runner with live output in a split window

local utils = require('custom.utils')

-- ============================================================================
-- Auto completion
-- ============================================================================

--- Global cache variables
local commands_cache = nil
local environ_cache = nil

--- Fill the commands cache from PATH
local function fill_commands_cache()
    if commands_cache == nil then
        -- Build cache of executable commands in PATH
        local paths = vim.split(os.getenv('PATH') or '', ':')
        local commands = {}
        local seen = {}
        for _, path in ipairs(paths) do
            local ok, entries = pcall(vim.fn.readdir, path)
            if ok and entries then
                for _, cmd in ipairs(entries) do
                    if not seen[cmd] then
                        table.insert(commands, cmd)
                        seen[cmd] = true
                    end
                end
            end
        end
        commands_cache = commands
    end
end

--- Fill environment variables cache
local function fill_environ_cache()
    if environ_cache == nil then
        local env_vars = {}
        for k, _ in pairs(vim.fn.environ()) do
            table.insert(env_vars, '$' .. k)
        end
        environ_cache = env_vars
    end
end

--- Custom completion for Run command
local function complete_run_command(arg_lead, cmd_line, cursor_pos)
    -- Only provide completion at the end of the command line
    if cursor_pos < #cmd_line then
        return {}
    end
    -- Determine if we need to provide completion for a command:
    -- 1) First argument after 'Run'
    -- 2) After a command separator
    local separators = { ';', '&&', '||', '|', '(', '{', '\n' }
    local preceding_text = cmd_line:sub(1, cursor_pos - #arg_lead - 1):match('(%S+)%s*$') or ''
    local last_char = preceding_text:sub(-1)
    local is_command_start = preceding_text == 'Run' or vim.tbl_contains(separators, last_char)
    -- Determine if arg_lead looks like an environment variable, ie, starts with $
    local is_environment_var = arg_lead:match('^%$%a*') ~= nil

    -- Path-based completion for absolute (/...), relative (./, ../, sub/...), or ~ paths
    local path_sep = package.config:sub(1,1) -- Get path separator for current OS
    if arg_lead:find(path_sep, 1, true) or arg_lead:sub(1,1) == '~' then
        local dir = (arg_lead:match('(.*' .. path_sep .. ')') or '.')
        local base = arg_lead:sub(#dir + 1)

        local expanded_dir = vim.fn.expand(dir)
        if vim.fn.isdirectory(expanded_dir) == 0 then
            return {}
        end
        if expanded_dir:sub(-1) ~= path_sep then
            expanded_dir = expanded_dir .. path_sep
        end

        local entries = vim.fn.readdir(expanded_dir)
        local matches = {}
        for _, name in ipairs(entries) do
            if name ~= '.' and name ~= '..' and name:sub(1, #base) == base then
                local full = expanded_dir .. name
                local is_dir = vim.fn.isdirectory(full) == 1
                local display = dir .. name .. (is_dir and path_sep or '')
                if is_dir or (not is_command_start) or (vim.fn.executable(full) == 1) then
                    table.insert(matches, display)
                end
            end
        end
        return matches
    end

    if is_command_start then
        -- If commands cache is empty, fill it
        if commands_cache == nil then
            fill_commands_cache()
        end
        -- Filter cached commands based on arg_lead
        if commands_cache == nil then
            return {}
        end
        local matches = {}
        for _, cmd in ipairs(commands_cache) do
            if cmd:sub(1, #arg_lead) == arg_lead then
                table.insert(matches, cmd)
            end
        end
        -- Return matching commands for completion
        return matches

    elseif is_environment_var then
        -- If environment cache is empty, fill it
        if environ_cache == nil then
            fill_environ_cache()
        end
        if environ_cache == nil then
            return {}
        end
        -- Filter cached environment variables based on arg_lead
        local env_vars = {}
        for _, var in ipairs(environ_cache) do
            if var:sub(1, #arg_lead) == arg_lead then
                table.insert(env_vars, var)
            end
        end
        -- Return matching environment variables for completion
        return env_vars

    else
        -- Get all the files in the current working directory
        local cwd = vim.fn.getcwd()
        local files = vim.fn.readdir(cwd)
        local matches = {}
        for _, file in ipairs(files) do
            if file:sub(1, #arg_lead) == arg_lead then
                table.insert(matches, file)
            end
        end
        return matches
    end
end


-- ============================================================================
-- Global state
-- ============================================================================

-- Global state
local BUFFER_NAME = '[Run Output]'

local run_command = nil  -- Forward function declaration
local last_command = nil
local running_job = nil
local command_start_time = nil  -- Track when command started
local run_sequence = 0 -- Incremented each run to ignore stale callbacks

local ansi_namespace = nil
local current_ansi_state = nil  -- Tracks ANSI state across lines (table: {fg,bg,attrs})
local current_line_position = 1
local navigation_marks = {}  -- Maps line numbers to file locations
local ansi_hl_cache = {}

-- Cheap OS detection: package.config first char is path separator ('\\' on Windows)
local is_windows = vim.fn.has("win32") == 1 or vim.fn.has("win64") == 1

--- Ensure extmark namespace exists even after module reloads
local function ensure_ansi_namespace()
    if type(ansi_namespace) ~= 'number' then
        ansi_namespace = vim.api.nvim_create_namespace('ansi_hl')
    end
    return ansi_namespace
end

-- ============================================================================
-- Utility Functions
-- ============================================================================
-- Debug capture: set to true to write raw incoming chunks to a temp file for inspection
local function pretty_chunk(c)
    local out = ''
    for i = 1, #c do
        local byte = c:byte(i)
        if byte >= 32 and byte <= 126 then
            out = out .. string.char(byte)
        else
            out = out .. string.format('<%d>', byte)
        end
    end
    return out
end

local function debug_capture(chunks)
    local debug_log_path = vim.fn.expand('%:p:h') .. '/run_command_debug.log'
    local ok, f = pcall(io.open, debug_log_path, 'a')
    if not ok or not f then return end
    f:write('---- CHUNK BATCH ----\n')
    for i, c in ipairs(chunks) do
        f:write(string.format('[%d] LEN=%d: ', i, #c or 0))
        f:write(pretty_chunk(c))
        f:write('\n')
    end
    f:write('\n')
    f:close()
end

--- Format elapsed time in milliseconds to a readable string
local function format_elapsed_time(ms)
    if ms < 1000 then
        return string.format('%.0fms', ms)
    elseif ms < 60000 then
        return string.format('%.2fs', ms / 1000)
    else
        local minutes = math.floor(ms / 60000)
        local seconds = math.floor((ms % 60000) / 1000)
        return string.format('%dm %ds', minutes, seconds)
    end
end

--- Kill the current running job, if any
local function kill_running_job()
    if running_job then
        vim.fn.jobstop(running_job)
        running_job = nil
    end
end

--- Recompile - run the last command again
local function rerun_last_command()
    if run_command and last_command then
        run_command(last_command)
    else
        vim.notify('No previous command to re-run', vim.log.levels.WARN)
    end
end

--- Map ANSI color codes to highlight groups
local function parse_sgr_parts(params, state)
    -- params: string like '34' or '1;38;5;196'
    -- state: existing table to mutate (or nil)
    local function clamp(v, a, b) v = tonumber(v) or 0 if v < a then return a end if v > b then return b end return v end
    local function xterm256_to_hex(n)
        n = tonumber(n) or 0
        if n < 0 then n = 0 end
        if n > 255 then n = 255 end
        local ansi16 = {
            {0,0,0},{128,0,0},{0,128,0},{128,128,0},{0,0,128},{128,0,128},{0,128,128},{192,192,192},
            {128,128,128},{255,0,0},{0,255,0},{255,255,0},{0,0,255},{255,0,255},{0,255,255},{255,255,255}
        }
        if n < 16 then
            local c = ansi16[n+1]
            return string.format('#%02x%02x%02x', c[1], c[2], c[3])
        elseif n >= 16 and n <= 231 then
            local v = n - 16
            local r = math.floor(v / 36)
            local g = math.floor((v % 36) / 6)
            local b = v % 6
            local function level(x) return x == 0 and 0 or 55 + x * 40 end
            return string.format('#%02x%02x%02x', level(r), level(g), level(b))
        else
            local gray = 8 + (n - 232) * 10
            return string.format('#%02x%02x%02x', gray, gray, gray)
        end
    end

    local parts = vim.split(params or '', ';')
    if not state then state = { fg = nil, bg = nil, attrs = { bold = false, italic = false, underline = false, strikethrough = false } } end

    local i = 1
    while i <= #parts do
        local p = parts[i]
        if p == '' then
            -- reset
            state = { fg = nil, bg = nil, attrs = { bold = false, italic = false, underline = false, strikethrough = false } }
        elseif p == '0' then
            state = { fg = nil, bg = nil, attrs = { bold = false, italic = false, underline = false, strikethrough = false } }
        elseif p == '1' then state.attrs.bold = true
        elseif p == '3' then state.attrs.italic = true
        elseif p == '4' then state.attrs.underline = true
        elseif p == '9' then state.attrs.strikethrough = true
        elseif tonumber(p) and tonumber(p) >= 30 and tonumber(p) <= 37 then
            local base = {['30']='#000000',['31']='#800000',['32']='#008000',['33']='#808000',['34']='#000080',['35']='#800080',['36']='#008080',['37']='#c0c0c0'}
            state.fg = base[p]
        elseif tonumber(p) and tonumber(p) >= 90 and tonumber(p) <= 97 then
            local b2 = {['90']='#808080',['91']='#ff0000',['92']='#00ff00',['93']='#ffff00',['94']='#0000ff',['95']='#ff00ff',['96']='#00ffff',['97']='#ffffff'}
            state.fg = b2[p]
        elseif tonumber(p) and tonumber(p) >= 40 and tonumber(p) <= 47 then
            local base_bg = {['40']='#000000',['41']='#800000',['42']='#008000',['43']='#808000',['44']='#000080',['45']='#800080',['46']='#008080',['47']='#c0c0c0'}
            state.bg = base_bg[p]
        elseif tonumber(p) and tonumber(p) >= 100 and tonumber(p) <= 107 then
            local bg2 = {['100']='#808080',['101']='#ff0000',['102']='#00ff00',['103']='#ffff00',['104']='#0000ff',['105']='#ff00ff',['106']='#00ffff',['107']='#ffffff'}
            state.bg = bg2[p]
        elseif p == '38' or p == '48' then
            local is_fg = p == '38'
            local mode = parts[i+1]
            if mode == '5' then
                local n = tonumber(parts[i+2]) or 0
                local hex = xterm256_to_hex(n)
                if is_fg then state.fg = hex else state.bg = hex end
                i = i + 2
            elseif mode == '2' then
                local r = clamp(parts[i+2], 0, 255)
                local g = clamp(parts[i+3], 0, 255)
                local b = clamp(parts[i+4], 0, 255)
                local hex = string.format('#%02x%02x%02x', r, g, b)
                if is_fg then state.fg = hex else state.bg = hex end
                i = i + 4
            end
        end
        i = i + 1
    end

    return state
end


local function get_ansi_highlight(code_or_state)
    -- Accept either an SGR param string or a state table
    local state = nil
    if type(code_or_state) == 'table' then
        state = code_or_state
    else
        state = parse_sgr_parts(code_or_state, nil)
    end

    if not state then return nil end
    local fg, bg, attrs = state.fg, state.bg, state.attrs or {}
    if not fg and not bg and not (attrs.bold or attrs.italic or attrs.underline or attrs.strikethrough) then
        return nil
    end

    local function sanitize(s)
        return tostring(s):gsub('#','_'):gsub('%W','_')
    end
    local name_parts = { 'Ansi' }
    if fg then table.insert(name_parts, 'fg' .. sanitize(fg)) end
    if bg then table.insert(name_parts, 'bg' .. sanitize(bg)) end
    if attrs.bold then table.insert(name_parts, 'Bold') end
    if attrs.italic then table.insert(name_parts, 'Italic') end
    if attrs.underline then table.insert(name_parts, 'Underline') end
    if attrs.strikethrough then table.insert(name_parts, 'Strike') end
    local hl_name = table.concat(name_parts, '_')

    if not ansi_hl_cache[hl_name] then
        local props = {}
        if fg then props.fg = fg end
        if bg then props.bg = bg end
        if attrs.bold then props.bold = true end
        if attrs.italic then props.italic = true end
        if attrs.underline then props.underline = true end
        if attrs.strikethrough then props.strikethrough = true end
        pcall(vim.api.nvim_set_hl, 0, hl_name, props)
        ansi_hl_cache[hl_name] = true
    end
    return hl_name
end


--- Search for file:line or file:line:col patterns and set navigation marks
local function search_locations(line, line_num)
    local ns_id = ensure_ansi_namespace()
    local patterns = is_windows
        and {
            '([^%s%(]+)%((%d+)%)',
            '([^%s:]+):(%d+):(%d+)',
            '([^%s:]+):(%d+)'
        }
        or {
            '([^%s:]+):(%d+):(%d+)',
            '([^%s:]+):(%d+)',
            '([^%s%(]+)%((%d+)%)'
        }

    local pos = 1
    while pos <= #line do
        local s, e, file, lineno, colno
        for _, pattern in ipairs(patterns) do
            s, e, file, lineno, colno = line:find(pattern, pos)
            if s then
                break
            end
        end

        if not s then break; end

        local abs_path = vim.fn.fnamemodify(file, ':p')
        if vim.fn.filereadable(abs_path) == 1 then
            navigation_marks[line_num] = {
                file = abs_path,
                line = tonumber(lineno),
                col = colno and tonumber(colno) or 0
            }
            -- Highlight the file:line[:col] pattern (0-based column indexing)
            local buffer = utils.find_buffer_by_name(BUFFER_NAME)
            -- Clamp extmark columns to the actual line length to avoid nvim errors
            local line_text = line or ''
            local line_len = #line_text
            local start_col = math.max(0, s - 1)
            local end_col = math.min(line_len, e)
            if end_col <= start_col then
                end_col = math.min(line_len, start_col + 1)
            end
            pcall(vim.api.nvim_buf_set_extmark, buffer, ns_id, line_num, start_col, {
                end_col = end_col,
                hl_group = 'Directory',
            })
        end
        pos = e + 1
    end
end

--- Parse terminal control sequences (SGR/CSI/OSC/CR) and apply highlighting
local function handle_chunk(input, buffer)
    if #input == 0 then return end

    -- Build a byte array for existing current line content
    local current_line = utils.get_buffer_lines(buffer, -2, -1)[1] or ''
    local out_bytes = {}
    for p = 1, #current_line do out_bytes[#out_bytes + 1] = current_line:byte(p) end

    local ns_id = ensure_ansi_namespace()
    local highlights = {}
    local current_state = current_ansi_state
    local current_hl = current_state and get_ansi_highlight(current_state) or nil
    local pos = current_line_position - 1
    local hl_start = current_hl and pos or nil

    local i = 1
    while i <= #input do
        local b = input:byte(i)
        -- Carriage return: move write cursor to start of line
        if b == 13 then
            -- Close any active highlight for this line before CR
            if current_hl and hl_start then
                table.insert(highlights, { hl = current_hl, start = hl_start, stop = pos })
                hl_start = nil
            end
            current_line_position = 1
            pos = 0
            i = i + 1

        elseif b == 27 then
            -- Escape: parse control sequence
            local next_ch = input:sub(i + 1, i + 1)
            if next_ch == '[' then
                -- CSI sequence: collect params up to final byte
                local j = i + 2
                while j <= #input and not (input:byte(j) >= 64 and input:byte(j) <= 126) do
                    j = j + 1
                end
                if j <= #input then
                    local final = input:sub(j, j)
                    local params = input:sub(i + 2, j - 1)
                    if final == 'm' then
                        -- SGR - styling change. Merge sequential SGR codes into a single state
                        if current_hl and hl_start then
                            table.insert(highlights, { hl = current_hl, start = hl_start, stop = pos })
                        end
                        local code = params or ''
                        if code == '' or code == '0' then
                            current_state = nil
                            current_hl = nil
                            hl_start = nil
                        else
                            current_state = parse_sgr_parts(code, current_state)
                            current_hl = get_ansi_highlight(current_state)
                            hl_start = current_hl and pos or nil
                        end
                    elseif final == 'K' then
                        -- EL (Erase in Line) handling
                        local n = tonumber(params) or 0
                        if n == 0 then
                            -- erase from cursor to end of line
                            for idx = current_line_position, #out_bytes do out_bytes[idx] = nil end
                            pos = current_line_position - 1
                        elseif n == 1 then
                            -- erase from start to cursor: shift remaining to line start
                            local start_idx = current_line_position
                            local new_bytes = {}
                            for idx = start_idx, #out_bytes do
                                new_bytes[#new_bytes + 1] = out_bytes[idx]
                            end
                            out_bytes = new_bytes
                            current_line_position = 1
                            pos = #out_bytes
                        elseif n == 2 then
                            -- erase entire line
                            out_bytes = {}
                            current_line_position = 1
                            pos = 0
                        end
                    elseif final == 'J' then
                        -- ED (Erase Display) handling (ignore it for now)
                        -- local n = tonumber(params) or 0
                        -- if n == 0 then
                        --     -- erase from cursor to end of screen (approx: to end of current line)
                        --     for idx = current_line_position, #out_bytes do out_bytes[idx] = nil end
                        --     pos = current_line_position - 1
                        -- elseif n == 1 then
                        --     -- erase from start to cursor (approx: clear current line and keep remainder)
                        --     out_bytes = {}
                        --     current_line_position = 1
                        --     pos = 0
                        -- elseif n == 2 then
                        --     -- erase entire screen -> reset whole buffer
                        --     out_bytes = {}
                        --     utils.reset_buffer_content(buffer)
                        --     current_line_position = 1
                        --     pos = 0
                        -- end
                    elseif final == 'H' or final == 'f' then
                        -- Cursor position: move to specified column (params = 'row;col' or 'row')
                        local row_str, col_str = params:match('(%d*);?(%d*)')
                        local col = tonumber(col_str) or tonumber(row_str) or 1
                        col = math.max(1, col)
                        -- Ensure out_bytes has space up to the target column - 1
                        local needed = col - 1
                        if #out_bytes < needed then
                            for k = #out_bytes + 1, needed do out_bytes[k] = 32 end
                        end
                        current_line_position = col
                        pos = current_line_position - 1
                    elseif final == 'l' or final == 'h' then
                        -- Private-mode set/reset (eg. ?25l / ?25h for cursor visibility) - ignore
                    end
                    j = j + 1
                    i = j
                else
                    -- Malformed CSI: skip ESC
                    i = i + 1
                end
            elseif next_ch == ']' then
                -- OSC sequence: skip until BEL (7) or ESC '\' terminator
                local j2 = i + 2
                while j2 <= #input do
                    local cb = input:byte(j2)
                    if cb == 7 then
                        j2 = j2 + 1
                        break
                    end
                    if cb == 27 and input:sub(j2 + 1, j2 + 1) == '\\' then
                        j2 = j2 + 2
                        break
                    end
                    j2 = j2 + 1
                end
                i = j2
            else
                -- Unknown ESC sequence: skip ESC
                i = i + 1
            end
        else
            -- Regular byte: append/overwrite at current position
            out_bytes[current_line_position] = b
            current_line_position = current_line_position + 1
            pos = pos + 1
            i = i + 1
        end
    end

    -- Close any open highlight at end of chunk
    if current_hl and hl_start then
        table.insert(highlights, { hl = current_hl, start = hl_start, stop = pos })
    end

    -- Assemble final line from bytes (avoid nils in sparse arrays)
    local final_line = ''
    local written_len = math.max(#out_bytes, current_line_position - 1, pos)
    if written_len > 0 then
        local parts = {}
        for idx = 1, written_len do
            local byte = out_bytes[idx] or 32 -- fill missing with space
            parts[idx] = string.char(byte)
        end
        final_line = table.concat(parts)
    end
    utils.set_buffer_lines(buffer, -2, -1, { final_line })

    -- Apply highlight extmarks for this line
    local line_num = utils.get_buffer_line_count(buffer) - 1
    for _, hl in ipairs(highlights) do
        if hl.stop > hl.start then
            -- Clamp highlight extmarks to current line length to avoid out-of-range errors
            local line_text = final_line or ''
            local line_len = #line_text
            local s_col = math.max(0, hl.start)
            local e_col = math.min(line_len, hl.stop)
            if e_col > s_col then
                pcall(vim.api.nvim_buf_set_extmark, buffer, ns_id, line_num, s_col, {
                    end_col = e_col,
                    hl_group = hl.hl,
                })
            end
        end
    end

    -- Search for file:line patterns and set navigation marks
    search_locations(final_line, line_num)

    -- Save ANSI state back (store state table)
    current_ansi_state = current_state
end



-- ============================================================================
-- Window And Buffer Management
-- ============================================================================

--- Initialize syntax highlighting for output buffer
local function initialize_syntax_highlighting(buffer)
    -- Reset ANSI state for new command
    current_ansi_state = nil
    -- Ensure namespace exists (important when state was reset by a reload)
    ansi_namespace = ensure_ansi_namespace()

    -- Setup syntax highlighting for this buffer
    vim.api.nvim_buf_call(buffer, function()
        vim.cmd([[
          syntax clear
          syntax match RunLocation /^@ .*/
          syntax match RunCommand /^\$ .*/
          syntax match RunExitCode /^Process exited with code \d\+$/
          syntax match ElapsedTime /^Elapsed time: .*/
          syntax match Separator /^-\{40,}$/
          syntax match RunError /\c\<error\>\|\cfailed\|\c\<fatal\>/
          syntax match RunWarning /\c\<warning\>\|\c\<warn\>/
          highlight default link RunLocation Comment
          highlight default link RunCommand Comment
          highlight default link RunExitCode Comment
          highlight default link ElapsedTime Comment
          highlight default link Separator Comment
          highlight default link RunError ErrorMsg
          highlight default link RunWarning WarningMsg
        ]])

        -- Generate ANSI color highlights programmatically
        local colors = {'Red', 'Green', 'Yellow', 'Blue', 'Magenta', 'Cyan', 'White'}
        local styles = {
            {prefix = '', attrs = ''},
            {prefix = 'Bold', attrs = 'cterm=bold gui=bold'},
            {prefix = 'Italic', attrs = 'cterm=italic gui=italic'},
            {prefix = 'Underline', attrs = 'cterm=underline gui=underline'},
            {prefix = 'Strike', attrs = 'cterm=strikethrough gui=strikethrough'},
        }

        for _, color in ipairs(colors) do
            for _, style in ipairs(styles) do
                local hl_name = 'Ansi' .. style.prefix .. color
                local ctermfg = ({Red=1, Green=2, Yellow=3, Blue=4, Magenta=5, Cyan=6, White=7})[color]
                local gui_color = string.lower(color)
                vim.cmd(string.format('highlight %s ctermfg=%d %s guifg=%s',
                    hl_name, ctermfg, style.attrs, gui_color))
            end
        end

        -- Standalone style highlights
        vim.cmd('highlight AnsiBold cterm=bold gui=bold')
        vim.cmd('highlight AnsiItalic cterm=italic gui=italic')
        vim.cmd('highlight AnsiUnderline cterm=underline gui=underline')
        vim.cmd('highlight AnsiStrike cterm=strikethrough gui=strikethrough')
    end)

end

-- Initialize keymap for new buffer
local function initialize_keymaps(window, buffer)
    -- Keymap to close the output window
    vim.keymap.set('n', 'q', function()
        utils.dismiss_buffer_window(window, buffer)
    end, { buffer = buffer, desc = 'Close Run Output Window' })

    -- Set up keymap for navigating to file:line under cursor
    vim.keymap.set('n', '<CR>', function()
        local line = utils.get_cursor_position(window).line - 1
        if navigation_marks[line] then
            local mark = navigation_marks[line]
            local target_win = utils.find_window_by_buffer(utils.find_buffer_by_name(mark.file))
                or utils.find_alternate_real_window(window)

            -- Check if file is already open in a window
            local other = utils.find_buffer_by_name(mark.file)
            if other and target_win then
                utils.set_window_buffer(target_win, other)
                utils.set_current_window(target_win)
                utils.set_cursor_position(target_win, mark.line, mark.col)
            elseif other then
                local win = utils.reuse_or_create_window_for_buffer(other)
                utils.set_cursor_position(win, mark.line, mark.col)
            elseif target_win then
                utils.set_current_window(target_win)
                vim.cmd('edit ' .. vim.fn.fnameescape(mark.file))
                utils.set_cursor_position(target_win, mark.line, mark.col)
            -- File not open and no reusable window exists
            else
                vim.cmd('edit ' .. vim.fn.fnameescape(mark.file))
                utils.set_cursor_position(window, mark.line, mark.col)
            end
        end
    end, { buffer = buffer, nowait = true, desc = 'Go to file:line:col under cursor' })

    -- Navigate to next location mark
    vim.keymap.set('n', ']', function()
        local cur_line = utils.get_cursor_position(window).line - 1
        local next_line = nil
        for line_num, _ in pairs(navigation_marks) do
            if line_num > cur_line and (next_line == nil or line_num < next_line) then
                next_line = line_num
            end
        end
        if next_line then
            utils.set_cursor_position(window, next_line + 1, 0)
        end
    end, { buffer = buffer, nowait = true, desc = 'Go to next location mark' })

    -- Navigate to previous location mark
    vim.keymap.set('n', '[', function()
        local cur_line = utils.get_cursor_position(window).line - 1
        local prev_line = nil
        for line_num, _ in pairs(navigation_marks) do
            if line_num < cur_line and (prev_line == nil or line_num > prev_line) then
                prev_line = line_num
            end
        end
        if prev_line then
            utils.set_cursor_position(window, prev_line + 1, 0)
        end
    end, { buffer = buffer, nowait = true, desc = 'Go to previous location mark' })

    -- Keymap to re-run last command
    vim.keymap.set('n', 'r', function()
        rerun_last_command()
    end, { buffer = buffer, nowait = true, desc = 'Re-run last command' })

    -- Keymap to kill running command
    vim.keymap.set('n', 'k', function()
        kill_running_job()
    end, { buffer = buffer, nowait = true, desc = 'Kill running command' })
end

--- Initialize or clear the output buffer
local function initialize_buffer()
    -- Reset buffer content if it already exists to preserve window and extmark state
    local buffer = utils.find_buffer_by_name(BUFFER_NAME)
    if buffer then
        utils.reset_buffer_content(buffer)
    else
        -- Otherwise create a new buffer
        buffer = utils.create_scratch_buffer(BUFFER_NAME, false) -- modifiable = false
        -- Setup syntax highlighting and keymaps for the buffer
        initialize_syntax_highlighting(buffer)
    end
    return buffer
end


--- Update buffer with new output lines
local function update_output(data)
    if not data or #data == 0 then return end

    vim.schedule(function()
        local ns_id = ensure_ansi_namespace()
        local buffer = utils.find_buffer_by_name(BUFFER_NAME)
        if not buffer then return end

        -- Find the window displaying this buffer, if any, to manage auto-scrolling
        local window = utils.find_window_by_buffer(buffer)
        local at_bottom = true
        if window then
            local curr_line = utils.get_cursor_position(window).line
            local line_count = utils.get_buffer_line_count(buffer)
            at_bottom = curr_line == 1 or curr_line == line_count
         end

        -- Capture raw chunks for debugging if needed
        -- debug_capture(data)
        -- stdout and stderr are not emitted immediately, they are accumulated and emitted
        -- in batches upon flush. Neovim emits a different chunk for each line emitted into
        -- stack prior to flush.
        for idx, chunk in ipairs(data) do
            -- More then one chunk means the flush has emitted multiple lines,
            -- so we can safely append a new empty line for the next chunk.
            if idx > 1 then
                utils.set_buffer_lines(buffer, -1, -1, { '' })
                current_line_position = 1
            end
            -- Process the chunk to handle ANSI codes and update buffer content
            handle_chunk(chunk, buffer)
        end

        -- If window is displayed, auto-scroll to bottom if cursor was already at the end
        -- This allows users to scroll up and read output without being forced to the bottom on every update
        if window and at_bottom then
            local line_count = utils.get_buffer_line_count(buffer)
            utils.set_cursor_position(window, line_count, 0)
        end
    end)
end

--- Function called when command is completed
local function on_complete(job_id, exit_code)
    local elapsed_ms = command_start_time and (vim.loop.now() - command_start_time) or 0
    local elapsed_str = format_elapsed_time(elapsed_ms)
    update_output({
        '',
        '----------------------------------------',
        string.format('Process exited with code %d', exit_code),
        string.format('Elapsed time: %s', elapsed_str)
    })
    running_job = nil
end

-- ============================================================================
-- Command Execution
-- ============================================================================

--- Execute a shell command asynchronously with live output
run_command = function(cmd)
    -- Stop any running job before starting new one
    kill_running_job()
    -- Prepare output buffer for new command
    local buffer = initialize_buffer()
    -- Reuse existing window if buffer is already displayed, otherwise create a new split
    local window = utils.reuse_or_create_window_for_buffer(buffer)

    -- Setup keymaps for the buffer
    initialize_keymaps(window, buffer)

    -- Store last command and capture start time
    last_command = cmd
    -- Bump run sequence so any callbacks from previous jobs are ignored
    run_sequence = run_sequence + 1
    local this_run = run_sequence
    command_start_time = vim.loop.now()
    -- Reset navigation marks
    navigation_marks = {}
    -- Reset buffer content and ANSI state for new command
    utils.reset_buffer_content(buffer)
    current_ansi_state = nil
    current_line_position = 1
    -- Initially populate buffer with command info
    update_output({ '@ ' .. vim.fn.getcwd(), '$ ' .. cmd, '', ''})
    -- Start async job
    local job_opts = {
        -- Using tty mode on windows to avoid compatibility issues
        tty = is_windows,
        -- Using pty on non-windows systems so tools think they're in a real terminal
        pty = not is_windows,
        on_stdout = function(_, data)
            if this_run ~= run_sequence then return end
            update_output(data)
        end,
        on_stderr = function(_, data)
            if this_run ~= run_sequence then return end
            update_output(data)
        end,
        on_exit = function(_, code)
            if this_run ~= run_sequence then return end
            on_complete(_, code)
        end,
    }
    running_job = vim.fn.jobstart(cmd, job_opts)
end

-- ============================================================================
-- User Interface
-- ============================================================================

vim.api.nvim_create_user_command('Run',
  function(opts)
    local cmd = opts.args
    -- Do nothing for empty command
    if cmd == '' then return end
    -- Run the command
    run_command(cmd)
  end,
  {
    nargs = '*',
    complete = complete_run_command,
    desc = 'Run command in background with live output',
  }
)

vim.keymap.set('n', '<leader>r', ':Run ', { noremap = true, desc = 'Run command' })
