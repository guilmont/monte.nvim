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
        -- PATH entries are separated by ';' on Windows (where ':' appears in drive letters)
        local path_list_sep = utils.is_windows and ';' or ':'
        local paths = vim.split(os.getenv('PATH') or '', path_list_sep, { plain = true })
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
local current_line_hls = {}  -- Highlight group per byte of the line being written
local navigation_marks = {}  -- Maps line numbers to file locations
local run_cwd = nil  -- Directory the current command was started in
local run_buffer = nil  -- Output buffer of the current run
local resolved_paths = {}  -- Per-run cache: path as printed -> absolute readable path, or false
local ansi_hl_cache = {}  -- Maps generated highlight group name -> highlight props

local is_windows = utils.is_windows

-- Location patterns, tried in order: the earliest match in a line wins, so more
-- specific patterns come first to win ties at the same start column.
local LOCATION_PATTERNS = {
    '([^%s%(]+)%((%d+),(%d+)%)',  -- file(line,col)  (MSVC)
    '([^%s%(]+)%((%d+)%)',        -- file(line)
    '([^%s:]+):(%d+):(%d+)',      -- file:line:col
    '([^%s:]+):(%d+)',            -- file:line
}
if is_windows then
    -- Keep the drive letter, which the patterns above would split on ':'
    table.insert(LOCATION_PATTERNS, 1, '(%a:[^%s:]+):(%d+):(%d+)')
    table.insert(LOCATION_PATTERNS, 2, '(%a:[^%s:]+):(%d+)')
end

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
        elseif p == '22' then state.attrs.bold = false
        elseif p == '23' then state.attrs.italic = false
        elseif p == '24' then state.attrs.underline = false
        elseif p == '29' then state.attrs.strikethrough = false
        elseif p == '39' then state.fg = nil
        elseif p == '49' then state.bg = nil
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
        ansi_hl_cache[hl_name] = props
    end
    return hl_name
end

-- Links for the output buffer's syntax groups
local syntax_links = {
    RunLocation = 'Comment',
    RunCommand = 'Comment',
    RunExitCode = 'Comment',
    ElapsedTime = 'Comment',
    Separator = 'Comment',
    RunError = 'ErrorMsg',
    RunWarning = 'WarningMsg',
}

local function define_syntax_links()
    for group, target in pairs(syntax_links) do
        vim.api.nvim_set_hl(0, group, { link = target, default = true })
    end
end

-- Loading a colorscheme runs `:hi clear`, which wipes the generated ANSI groups
-- that existing extmarks still reference, and the syntax links. Re-define them.
vim.api.nvim_create_autocmd('ColorScheme', {
    group = vim.api.nvim_create_augroup('run-ansi-highlights', { clear = true }),
    callback = function()
        define_syntax_links()
        for hl_name, props in pairs(ansi_hl_cache) do
            pcall(vim.api.nvim_set_hl, 0, hl_name, props)
        end
    end,
})


--- Search for file:line or file:line:col patterns and set navigation marks
local function search_locations(line, line_num, buffer)
    local ns_id = ensure_ansi_namespace()

    -- The line may be re-parsed as more of it arrives; the first readable location wins
    navigation_marks[line_num] = nil

    -- Next match of each pattern at or after pos ({ s, e, file, line, col }, or false
    -- once a pattern has no more matches), so each pattern scans the line about once.
    local next_match = {}

    local pos = 1
    while pos <= #line do
        local best
        for k, pattern in ipairs(LOCATION_PATTERNS) do
            local m = next_match[k]
            if m == nil or (m and m[1] < pos) then
                m = { line:find(pattern, pos) }
                m = m[1] and m or false
                next_match[k] = m
            end
            if m and (not best or m[1] < best[1]) then
                best = m
            end
        end

        if not best then break; end
        local s, e, file, lineno, colno = unpack(best)

        -- Resolve relative paths against the directory the command was started in,
        -- not whatever cwd happens to be current when the output arrives. Build logs
        -- repeat the same paths a lot, so cache the result (including misses).
        local abs_path = resolved_paths[file]
        if abs_path == nil then
            local full = vim.fn.isabsolutepath(file) == 1 and file or vim.fs.joinpath(run_cwd, file)
            full = vim.fn.simplify(full)
            abs_path = vim.fn.filereadable(full) == 1 and full or false
            resolved_paths[file] = abs_path
        end
        if abs_path then
            navigation_marks[line_num] = navigation_marks[line_num] or {
                file = abs_path,
                line = tonumber(lineno),
                -- Tools report 1-based columns; nvim cursor columns are 0-based
                col = colno and math.max(0, tonumber(colno) - 1) or 0
            }
            -- Highlight the file:line[:col] pattern (0-based column indexing)
            -- Clamp extmark columns to the actual line length to avoid nvim errors
            local line_len = #line
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

    -- Build a byte array for existing current line content. Highlights are tracked
    -- per byte in current_line_hls (kept across chunks) so that rewriting the line,
    -- carriage-return overwrites and erases all keep colors consistent.
    local current_line = (utils.get_buffer_lines(buffer, -2, -1) or {})[1] or ''
    local out_bytes = {}
    for p = 1, #current_line do out_bytes[#out_bytes + 1] = current_line:byte(p) end

    local ns_id = ensure_ansi_namespace()
    local current_state = current_ansi_state
    local current_hl = current_state and get_ansi_highlight(current_state) or nil

    -- Pad the line with unstyled spaces up to (but not including) column col
    local function pad_to(col)
        for k = #out_bytes + 1, col - 1 do
            out_bytes[k] = 32
            current_line_hls[k] = nil
        end
    end

    local i = 1
    while i <= #input do
        local b = input:byte(i)
        -- Carriage return: move write cursor to start of line
        if b == 13 then
            current_line_position = 1
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
                        local code = params or ''
                        if code == '' or code == '0' then
                            current_state = nil
                            current_hl = nil
                        else
                            current_state = parse_sgr_parts(code, current_state)
                            current_hl = get_ansi_highlight(current_state)
                        end
                    elseif final == 'K' then
                        -- EL (Erase in Line) handling; the cursor never moves
                        local n = tonumber(params) or 0
                        if n == 0 then
                            -- erase from cursor to end of line
                            for idx = #out_bytes, current_line_position, -1 do
                                out_bytes[idx] = nil
                                current_line_hls[idx] = nil
                            end
                        elseif n == 1 then
                            -- erase from start of line through cursor (blank it out)
                            for idx = 1, math.min(current_line_position, #out_bytes) do
                                out_bytes[idx] = 32
                                current_line_hls[idx] = nil
                            end
                        elseif n == 2 then
                            -- erase entire line
                            out_bytes = {}
                            current_line_hls = {}
                        end
                    elseif final == 'J' then
                        -- ED (Erase Display) handling (ignore it for now)
                    elseif final == 'G' then
                        -- CHA (Cursor Character Absolute): move cursor to column N
                        current_line_position = math.max(1, tonumber(params) or 1)
                        pad_to(current_line_position)
                    elseif final == 'H' or final == 'f' then
                        -- Cursor position: move to specified column (params = 'row;col' or 'row')
                        local row_str, col_str = params:match('(%d*);?(%d*)')
                        local col = tonumber(col_str) or tonumber(row_str) or 1
                        current_line_position = math.max(1, col)
                        pad_to(current_line_position)
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
            current_line_hls[current_line_position] = current_hl
            current_line_position = current_line_position + 1
            i = i + 1
        end
    end

    -- Assemble final line from bytes
    local final_line = ''
    if #out_bytes > 0 then
        local parts = {}
        for idx = 1, #out_bytes do
            parts[idx] = string.char(out_bytes[idx])
        end
        final_line = table.concat(parts)
    end
    utils.set_buffer_lines(buffer, -2, -1, { final_line })

    -- Re-apply highlight extmarks for the whole line, merging runs of equal groups.
    -- Rewriting the line collapses its old extmarks, so clear them first.
    local line_num = utils.get_buffer_line_count(buffer) - 1
    pcall(vim.api.nvim_buf_clear_namespace, buffer, ns_id, line_num, line_num + 1)
    local idx = 1
    while idx <= #out_bytes do
        local hl = current_line_hls[idx]
        local stop = idx
        while stop + 1 <= #out_bytes and current_line_hls[stop + 1] == hl do
            stop = stop + 1
        end
        if hl then
            pcall(vim.api.nvim_buf_set_extmark, buffer, ns_id, line_num, idx - 1, {
                end_col = stop,
                hl_group = hl,
            })
        end
        idx = stop + 1
    end

    -- Search for file:line patterns and set navigation marks
    search_locations(final_line, line_num, buffer)

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
        ]])
        define_syntax_links()

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
local function initialize_keymaps(buffer)
    -- Keymaps are buffer-local, so the current window is always the one showing
    -- the output buffer (it may have moved since the command was started).

    -- Keymap to close the output window
    vim.keymap.set('n', 'q', function()
        utils.dismiss_buffer_window(utils.get_current_window(), buffer)
    end, { buffer = buffer, desc = 'Close Run Output Window' })

    -- Set up keymap for navigating to file:line under cursor
    vim.keymap.set('n', '<CR>', function()
        local window = utils.get_current_window()
        local line = utils.get_cursor_position(window).line - 1
        local mark = navigation_marks[line]
        if not mark then return end

        -- Prefer a window already showing the file, then any other real window.
        local existing = utils.find_buffer_by_path(mark.file)
        local target_win = (existing and utils.find_window_by_buffer(existing))
            or utils.find_alternate_real_window(window)

        if target_win then
            utils.set_current_window(target_win)
        else
            -- The output is the only real window: keep it and open the file in a
            -- new split to its left (Neo-tree, if open, stays leftmost).
            vim.cmd('leftabove vsplit')
            target_win = utils.get_current_window()
        end

        -- :edit reuses an existing buffer (loading it if needed) or opens the file
        vim.cmd('edit ' .. vim.fn.fnameescape(mark.file))
        utils.set_cursor_position(target_win, mark.line, mark.col)
    end, { buffer = buffer, nowait = true, desc = 'Go to file:line:col under cursor' })

    -- Navigate to next location mark
    vim.keymap.set('n', ']', function()
        local window = utils.get_current_window()
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
        local window = utils.get_current_window()
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
    -- A buffer closed with :bdelete still exists but is unloaded (and lost its
    -- syntax setup), so throw it away and start fresh
    if buffer and not utils.is_buffer_valid(buffer) then
        pcall(utils.remove_buffer, buffer)
        buffer = nil
    end
    if buffer then
        utils.reset_buffer_content(buffer)
        pcall(vim.api.nvim_buf_clear_namespace, buffer, ensure_ansi_namespace(), 0, -1)
    else
        -- Otherwise create a new buffer
        buffer = utils.create_scratch_buffer(BUFFER_NAME, false) -- modifiable = false
        -- Setup syntax highlighting and keymaps for the buffer
        initialize_syntax_highlighting(buffer)
    end
    return buffer
end


--- Update buffer with new output lines from run number `seq`
local function update_output(data, seq)
    if not data or #data == 0 then return end

    vim.schedule(function()
        -- Output from a previous run may already be queued when a new run resets the buffer
        if seq ~= run_sequence then return end
        local buffer = run_buffer
        if not buffer or not utils.is_buffer_valid(buffer) then return end

        -- Find the window displaying this buffer, if any, to manage auto-scrolling
        local window = utils.find_window_by_buffer(buffer)
        local at_bottom = true
        if window then
            local curr_line = utils.get_cursor_position(window).line
            local line_count = utils.get_buffer_line_count(buffer)
            -- Only follow output when the cursor is on the last line. A freshly reset
            -- buffer has a single line, so new runs still start out following.
            at_bottom = curr_line == line_count
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
                current_line_hls = {}
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
local function on_complete(seq, exit_code)
    local elapsed_ms = command_start_time and (vim.loop.now() - command_start_time) or 0
    local elapsed_str = format_elapsed_time(elapsed_ms)
    update_output({
        '',
        '----------------------------------------',
        string.format('Process exited with code %d', exit_code),
        string.format('Elapsed time: %s', elapsed_str)
    }, seq)
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
    run_buffer = buffer
    -- Reuse existing window if buffer is already displayed, otherwise create a new split
    utils.reuse_or_create_window_for_buffer(buffer)

    -- Setup keymaps for the buffer
    initialize_keymaps(buffer)

    -- Store last command and capture start time
    last_command = cmd
    -- Bump run sequence so any callbacks from previous jobs are ignored
    run_sequence = run_sequence + 1
    local this_run = run_sequence
    command_start_time = vim.loop.now()
    -- Reset navigation marks and per-run state (initialize_buffer cleared the buffer)
    navigation_marks = {}
    resolved_paths = {}
    run_cwd = vim.fn.getcwd()
    current_ansi_state = nil
    current_line_position = 1
    current_line_hls = {}
    -- Initially populate buffer with command info
    update_output({ '@ ' .. run_cwd, '$ ' .. cmd, '', ''}, this_run)
    -- Start async job
    local function on_output(_, data)
        update_output(data, this_run)
    end
    local job_opts = {
        -- Using tty mode on windows to avoid compatibility issues
        tty = is_windows,
        -- Using pty on non-windows systems so tools think they're in a real terminal
        pty = not is_windows,
        on_stdout = on_output,
        on_stderr = on_output,
        on_exit = function(_, code)
            if this_run ~= run_sequence then return end
            on_complete(this_run, code)
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
