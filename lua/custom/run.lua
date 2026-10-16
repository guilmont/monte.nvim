-- Async command runner with live output in a split window

local utils = require('custom.utils')

-- ============================================================================
-- Auto completion
-- ============================================================================

--- Global cache variables
local commands_cache = nil
local environ_cache = nil

--- Fill the commands cache from PATH, if it is still empty
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

--- Fill environment variables cache, if it is still empty
local function fill_environ_cache()
    if environ_cache == nil then
        local env_vars = {}
        for k, _ in pairs(vim.fn.environ()) do
            table.insert(env_vars, '$' .. k)
        end
        environ_cache = env_vars
    end
end

--- Escape a completed word for the shell. Windows paths use '\' as the separator
--- and cmd.exe doesn't use backslash escapes, so they are left alone there.
local function escape_shell_word(word)
    if utils.is_windows then return word end
    return (word:gsub('[%s\\\'"$`&;|<>()*?%[%]{}!#]', '\\%0'))
end

--- Undo escape_shell_word on what the user typed
local function unescape_shell_word(word)
    if utils.is_windows then return word end
    return (word:gsub('\\(.)', '%1'))
end

--- Custom completion for Run command
local function complete_run_command(arg_lead, cmd_line, cursor_pos)
    -- Only provide completion at the end of the command line
    if cursor_pos < #cmd_line then
        return {}
    end
    -- Determine if we need to provide completion for a command:
    -- 1) First argument (after 'Run', or an abbreviation such as 'Ru')
    -- 2) After a command separator (';', '&&', '||', '|', '&', '(', '{')
    local before_lead = cmd_line:sub(1, cursor_pos - #arg_lead)
    local preceding_text = before_lead:match('(%S+)%s*$') or ''
    local is_first_arg = before_lead:match('^[%s:]*%S+%s+$') ~= nil
    local is_command_start = is_first_arg or preceding_text:match('[;&|({]$') ~= nil
    -- Determine if arg_lead looks like an environment variable, ie, starts with $
    local is_environment_var = arg_lead:match('^%$%a*') ~= nil
    local lead = unescape_shell_word(arg_lead)

    -- Path-based completion for absolute (/...), relative (./, ../, sub/...), or ~ paths.
    -- Windows accepts both separators.
    local path_sep = package.config:sub(1,1) -- Get path separator for current OS
    local sep_class = utils.is_windows and '[/\\]' or '/'
    if lead == '~' then lead = '~' .. path_sep end
    if lead:find(sep_class) then
        local dir = lead:match('^(.*' .. sep_class .. ')')
        local base = lead:sub(#dir + 1)

        -- Expand a leading ~ to the home directory, but keep it in what is displayed
        local expanded_dir = dir
        if dir:match('^~' .. sep_class) then
            expanded_dir = (vim.env.HOME or vim.fn.expand('~')) .. dir:sub(2)
        elseif dir:find('[$~]') then
            expanded_dir = vim.fn.expand(dir)
        end
        if vim.fn.isdirectory(expanded_dir) == 0 then
            return {}
        end
        if not expanded_dir:sub(-1):match(sep_class) then
            expanded_dir = expanded_dir .. path_sep
        end
        -- Complete directories with the separator the user is already typing
        local dir_sep = dir:sub(-1)

        local entries = vim.fn.readdir(expanded_dir)
        local matches = {}
        for _, name in ipairs(entries) do
            if name ~= '.' and name ~= '..' and name:sub(1, #base) == base then
                local full = expanded_dir .. name
                local is_dir = vim.fn.isdirectory(full) == 1
                local display = dir .. name .. (is_dir and dir_sep or '')
                if is_dir or (not is_command_start) or (vim.fn.executable(full) == 1) then
                    -- Leave the ~ unescaped so the shell still expands it
                    local tilde = display:match('^~') or ''
                    table.insert(matches, tilde .. escape_shell_word(display:sub(#tilde + 1)))
                end
            end
        end
        return matches
    end

    if is_command_start then
        fill_commands_cache()
        -- Filter cached commands based on arg_lead
        local matches = {}
        for _, cmd in ipairs(commands_cache) do
            if cmd:sub(1, #arg_lead) == arg_lead then
                table.insert(matches, cmd)
            end
        end
        -- Return matching commands for completion
        return matches

    elseif is_environment_var then
        fill_environ_cache()
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
            if file:sub(1, #lead) == lead then
                table.insert(matches, escape_shell_word(file))
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

-- Extmark namespace for ANSI colors and locations (the same id after a reload)
local ANSI_NS = vim.api.nvim_create_namespace('ansi_hl')
local current_ansi_state = nil  -- Tracks ANSI state across lines (table: {fg,bg,attrs})
local current_line_position = 1  -- Write cursor, as an index into current_line_cells
local current_line_cells = {}  -- One character (string) per cell of the line being written
local current_line_hls = {}  -- Highlight group per cell of the line being written
local pending_input = ''  -- Incomplete escape sequence or character at the end of the last chunk
local navigation_marks = {}  -- Maps line numbers to file locations
local run_cwd = nil  -- Directory the current command was started in
local run_buffer = nil  -- Output buffer of the current run
local resolved_paths = {}  -- Per-run cache: path as printed -> absolute readable path, or false
local ansi_hl_cache = {}  -- Maps generated highlight group name -> highlight props

local is_windows = utils.is_windows

-- Number of header lines ('@ cwd' and '$ cmd') at the top of the output
local HEADER_LINE_COUNT = 2

-- Location patterns, matched at the start of each whitespace-separated word (after
-- any leading quote or bracket) and tried in order, so more specific ones come first.
-- Anchoring them keeps scanning linear in the line length.
local LOCATION_PATTERNS = {
    '^([^%(%)"\'<>%[%]]+)%((%d+),(%d+)%)',  -- file(line,col)  (MSVC)
    '^([^%(%)"\'<>%[%]]+)%((%d+)%)',        -- file(line)
    '^([^:%(%)"\'<>%[%]]+):(%d+):(%d+)',    -- file:line:col
    '^([^:%(%)"\'<>%[%]]+):(%d+)',          -- file:line
}
if is_windows then
    -- Keep the drive letter, which the patterns above would split on ':'
    table.insert(LOCATION_PATTERNS, 1, '^(%a:[^:%(%)"\'<>%[%]]+):(%d+):(%d+)')
    table.insert(LOCATION_PATTERNS, 2, '^(%a:[^:%(%)"\'<>%[%]]+):(%d+)')
end

-- ============================================================================
-- Utility Functions
-- ============================================================================

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

--- Start a new, empty line being written
local function reset_line()
    current_line_position = 1
    current_line_cells = {}
    current_line_hls = {}
end

--- Recompile - run the last command again
local function rerun_last_command()
    if run_command and last_command then
        run_command(last_command)
    else
        vim.notify('No previous command to re-run', vim.log.levels.WARN)
    end
end

-- Standard and bright colors, indexed by the offset from 30/40 and 90/100
local SGR_BASE = { '#000000', '#800000', '#008000', '#808000', '#000080', '#800080', '#008080', '#c0c0c0' }
local SGR_BRIGHT = { '#808080', '#ff0000', '#00ff00', '#ffff00', '#0000ff', '#ff00ff', '#00ffff', '#ffffff' }

local function clamp(v, a, b) v = tonumber(v) or 0 if v < a then return a end if v > b then return b end return v end

local function xterm256_to_hex(n)
    n = clamp(n, 0, 255)
    if n < 8 then
        return SGR_BASE[n + 1]
    elseif n < 16 then
        return SGR_BRIGHT[n - 7]
    elseif n <= 231 then
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

local function reset_sgr_state()
    return { fg = nil, bg = nil, attrs = { bold = false, italic = false, underline = false, strikethrough = false } }
end

--- Map ANSI color codes to highlight groups
local function parse_sgr_parts(params, state)
    -- params: string like '34' or '1;38;5;196'
    -- state: existing table to mutate (or nil)
    local parts = vim.split(params or '', ';')
    if not state then state = reset_sgr_state() end

    local i = 1
    while i <= #parts do
        -- Compare numerically: tools write leading zeros ('01;31', '00'), and an
        -- empty parameter means 0
        local p = parts[i] == '' and 0 or tonumber(parts[i])
        if p == 0 then state = reset_sgr_state()
        elseif p == 1 then state.attrs.bold = true
        elseif p == 3 then state.attrs.italic = true
        elseif p == 4 then state.attrs.underline = true
        elseif p == 9 then state.attrs.strikethrough = true
        elseif p == 22 then state.attrs.bold = false
        elseif p == 23 then state.attrs.italic = false
        elseif p == 24 then state.attrs.underline = false
        elseif p == 29 then state.attrs.strikethrough = false
        elseif p == 39 then state.fg = nil
        elseif p == 49 then state.bg = nil
        elseif p and p >= 30 and p <= 37 then state.fg = SGR_BASE[p - 29]
        elseif p and p >= 90 and p <= 97 then state.fg = SGR_BRIGHT[p - 89]
        elseif p and p >= 40 and p <= 47 then state.bg = SGR_BASE[p - 39]
        elseif p and p >= 100 and p <= 107 then state.bg = SGR_BRIGHT[p - 99]
        elseif p == 38 or p == 48 then
            local is_fg = p == 38
            local mode = tonumber(parts[i+1])
            if mode == 5 then
                local n = tonumber(parts[i+2]) or 0
                local hex = xterm256_to_hex(n)
                if is_fg then state.fg = hex else state.bg = hex end
                i = i + 2
            elseif mode == 2 then
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


--- Highlight group for an SGR state table (from parse_sgr_parts), or nil if unstyled
local function get_ansi_highlight(state)
    local fg, bg, attrs = state.fg, state.bg, state.attrs
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
    -- The line may be re-parsed as more of it arrives; the first readable location wins
    navigation_marks[line_num] = nil
    -- Every pattern has a ':' or '(' followed by the line number; most lines have none
    if not line:find('[:(]%d') then return end

    for word_start, word in line:gmatch('()(%S+)') do
        -- Skip quotes and brackets around the location: "foo.c:3", (foo.c:2:3), [foo.c:1]
        local skip = #word:match('^["\'`(<%[{]*')
        local s, e, file, lineno, colno
        for _, pattern in ipairs(LOCATION_PATTERNS) do
            s, e, file, lineno, colno = word:find(pattern, skip + 1)
            if s then break end
        end
        if s then
            s, e = word_start + s - 1, word_start + e - 1

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
                    -- 1-based column as reported by the tool, converted when jumping
                    col = tonumber(colno),
                }
                -- Highlight the file:line[:col] pattern (0-based column indexing)
                pcall(vim.api.nvim_buf_set_extmark, buffer, ANSI_NS, line_num, s - 1, {
                    end_col = e,
                    hl_group = 'Directory',
                })
            end
        end
    end
end

-- Longest incomplete escape sequence kept for the next chunk. Anything longer is
-- treated as malformed, so a stray ESC can't hold back the rest of the output.
local MAX_PENDING_LENGTH = 4096

--- Parse terminal control sequences (SGR/CSI/OSC/CR/BS) and apply highlighting.
--- is_complete is true when the chunk ends its line. Otherwise an escape sequence or
--- character cut off at the end is kept in pending_input for the next chunk.
local function handle_chunk(input, buffer, is_complete)
    input = pending_input .. input
    pending_input = ''
    if #input == 0 then return end
    -- Neovim delivers NUL bytes as '\n' inside a line; put the NUL back (shown as ^@)
    input = input:gsub('\n', '\0')

    -- The line being written is kept as cells, one character each, with a highlight
    -- group per cell (both kept across chunks), so that carriage-return overwrites,
    -- backspaces and erases work per character and keep colors consistent.
    local cells, hls = current_line_cells, current_line_hls
    local current_state = current_ansi_state
    local current_hl = current_state and get_ansi_highlight(current_state) or nil

    -- Pad the line with unstyled spaces up to (but not including) column col
    local function pad_to(col)
        for k = #cells + 1, col - 1 do
            cells[k] = ' '
            hls[k] = nil
        end
    end

    -- Keep the input from byte i on for the next chunk, if it may still be completed
    local function defer(i)
        if is_complete or #input - i >= MAX_PENDING_LENGTH then return false end
        pending_input = input:sub(i)
        return true
    end

    local n = #input
    local i = 1
    while i <= n do
        local b = input:byte(i)
        -- Carriage return: move write cursor to start of line
        if b == 13 then
            current_line_position = 1
            i = i + 1

        elseif b == 8 then
            -- Backspace: move write cursor back one character
            current_line_position = math.max(1, current_line_position - 1)
            i = i + 1

        elseif b == 7 then
            -- BEL: drop it
            i = i + 1

        elseif b == 27 then
            -- Escape: parse control sequence
            local next_ch = input:sub(i + 1, i + 1)
            if next_ch == '' then
                -- Lone ESC at the end of the chunk
                if defer(i) then break end
                i = i + 1
            elseif next_ch == '[' then
                -- CSI sequence: collect params up to final byte
                local j = i + 2
                while j <= n and not (input:byte(j) >= 64 and input:byte(j) <= 126) do
                    j = j + 1
                end
                if j <= n then
                    local final = input:sub(j, j)
                    local params = input:sub(i + 2, j - 1)
                    if final == 'm' and (params == '' or params == '0') then
                        -- SGR reset, by far the most common one
                        current_state = nil
                        current_hl = nil
                    elseif final == 'm' then
                        -- SGR - styling change. Merge sequential SGR codes into a single state
                        current_state = parse_sgr_parts(params, current_state)
                        current_hl = get_ansi_highlight(current_state)
                    elseif final == 'K' then
                        -- EL (Erase in Line) handling; the cursor never moves
                        local mode = tonumber(params) or 0
                        if mode == 0 then
                            -- erase from cursor to end of line
                            for idx = #cells, current_line_position, -1 do
                                cells[idx] = nil
                                hls[idx] = nil
                            end
                        elseif mode == 1 then
                            -- erase from start of line through cursor (blank it out)
                            for idx = 1, math.min(current_line_position, #cells) do
                                cells[idx] = ' '
                                hls[idx] = nil
                            end
                        elseif mode == 2 then
                            -- erase entire line
                            for idx = #cells, 1, -1 do
                                cells[idx] = nil
                                hls[idx] = nil
                            end
                        end
                    elseif final == 'J' then
                        -- ED (Erase Display) handling (ignore it for now)
                    elseif final == 'G' then
                        -- CHA (Cursor Character Absolute): move cursor to column N
                        current_line_position = math.max(1, tonumber(params) or 1)
                        pad_to(current_line_position)
                    elseif final == 'H' or final == 'f' then
                        -- Cursor position (params = 'row;col', 'row' or ''): only the
                        -- column is used, since output is written one line at a time
                        current_line_position = math.max(1, tonumber(params:match(';(%d+)')) or 1)
                        pad_to(current_line_position)
                    elseif final == 'l' or final == 'h' then
                        -- Private-mode set/reset (eg. ?25l / ?25h for cursor visibility) - ignore
                    end
                    i = j + 1
                elseif defer(i) then
                    break
                else
                    -- Malformed CSI: skip ESC
                    i = i + 1
                end
            elseif next_ch == ']' then
                -- OSC sequence (titles, OSC 8 hyperlinks): skip until BEL (7) or ESC '\'
                local j = i + 2
                local stop = nil
                while j <= n do
                    local cb = input:byte(j)
                    if cb == 7 then
                        stop = j
                        break
                    end
                    if cb == 27 and input:sub(j + 1, j + 1) == '\\' then
                        stop = j + 1
                        break
                    end
                    j = j + 1
                end
                if stop then
                    i = stop + 1
                elseif defer(i) then
                    break
                else
                    -- Unterminated OSC: drop the rest of the line
                    i = n + 1
                end
            elseif next_ch:match('[()*+#]') then
                -- Three-byte sequences: character set designation (ESC ( B, as written by
                -- tput sgr0) and ESC # n
                if i + 2 <= n then
                    i = i + 3
                elseif defer(i) then
                    break
                else
                    i = n + 1
                end
            else
                -- Other two-byte sequences (ESC 7, ESC 8, ESC =, ESC >, ...): skip them
                i = i + 2
            end
        else
            -- Regular character: append/overwrite at current position. Take a whole
            -- UTF-8 sequence; invalid bytes become a cell of their own.
            local len = b >= 240 and 4 or b >= 224 and 3 or b >= 192 and 2 or 1
            if len > 1 and not input:sub(i + 1, i + len - 1):match('^[\128-\191]*$') then
                len = 1
            elseif i + len - 1 > n and defer(i) then
                break
            end
            cells[current_line_position] = input:sub(i, i + len - 1)
            hls[current_line_position] = current_hl
            current_line_position = current_line_position + 1
            i = i + len
        end
    end

    local final_line = table.concat(cells)
    utils.set_buffer_lines(buffer, -2, -1, { final_line })

    -- Re-apply highlight extmarks for the whole line, merging runs of equal groups.
    -- Rewriting the line collapses its old extmarks, so clear them first.
    local line_num = utils.get_buffer_line_count(buffer) - 1
    pcall(vim.api.nvim_buf_clear_namespace, buffer, ANSI_NS, line_num, line_num + 1)
    local idx = 1
    local byte_col = 0  -- 0-based byte column of cell idx
    while idx <= #cells do
        local hl = hls[idx]
        local start_col = byte_col
        byte_col = byte_col + #cells[idx]
        while idx + 1 <= #cells and hls[idx + 1] == hl do
            idx = idx + 1
            byte_col = byte_col + #cells[idx]
        end
        if hl then
            pcall(vim.api.nvim_buf_set_extmark, buffer, ANSI_NS, line_num, start_col, {
                end_col = byte_col,
                hl_group = hl,
            })
        end
        idx = idx + 1
    end

    -- Search for file:line patterns and set navigation marks (not in the header,
    -- which echoes the command)
    if line_num >= HEADER_LINE_COUNT then
        search_locations(final_line, line_num, buffer)
    end

    -- Save ANSI state back (store state table)
    current_ansi_state = current_state
end



-- ============================================================================
-- Window And Buffer Management
-- ============================================================================

--- Initialize syntax highlighting for output buffer
local function initialize_syntax_highlighting(buffer)
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
    end)
end

--- 0-based byte column for a navigation mark, in the current buffer.
--- Tools report 1-based columns. GCC counts display columns (a tab is 8 wide), which
--- only differ from byte columns on lines with tabs or multibyte characters, so
--- columns are converted as display columns only on lines containing tabs.
local function location_byte_col(mark)
    if not mark.col then return 0 end
    local text = vim.api.nvim_buf_get_lines(0, mark.line - 1, mark.line, false)[1] or ''
    if not text:find('\t', 1, true) then
        return math.max(0, mark.col - 1)
    end
    local vcol = 1  -- display column of the character at byte i
    local i = 1
    while i <= #text do
        local ch = text:sub(i, i + vim.str_utf_end(text, i))
        local width = ch == '\t' and (8 - (vcol - 1) % 8) or vim.fn.strdisplaywidth(ch)
        if vcol + width > mark.col then break end
        vcol = vcol + width
        i = i + #ch
    end
    return i - 1
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
        utils.set_cursor_position(target_win, mark.line, location_byte_col(mark))
    end, { buffer = buffer, nowait = true, desc = 'Go to file:line:col under cursor' })

    -- Navigate to the next (dir = 1) or previous (dir = -1) location mark
    local function jump_mark(dir)
        local window = utils.get_current_window()
        local cur_line = utils.get_cursor_position(window).line - 1
        local target = nil
        for line_num, _ in pairs(navigation_marks) do
            -- Compare signed distances, so the nearest mark in direction dir wins
            if (line_num - cur_line) * dir > 0 and (target == nil or (line_num - target) * dir < 0) then
                target = line_num
            end
        end
        if target then
            utils.set_cursor_position(window, target + 1, 0)
        end
    end
    vim.keymap.set('n', ']', function() jump_mark(1) end,
        { buffer = buffer, nowait = true, desc = 'Go to next location mark' })
    vim.keymap.set('n', '[', function() jump_mark(-1) end,
        { buffer = buffer, nowait = true, desc = 'Go to previous location mark' })

    -- Keymap to re-run last command
    vim.keymap.set('n', 'r', rerun_last_command, { buffer = buffer, nowait = true, desc = 'Re-run last command' })

    -- Keymap to kill running command
    vim.keymap.set('n', '<C-c>', kill_running_job, { buffer = buffer, nowait = true, desc = 'Kill running command' })
end

--- Initialize or clear the output buffer
local function initialize_buffer()
    -- Reuse the buffer if it still exists, to preserve its windows. One closed with
    -- :bdelete is unloaded (and lost its syntax setup), so it is replaced by a new one.
    local buffer, created = utils.get_or_create_scratch_buffer(
        BUFFER_NAME, utils.find_buffer_by_name(BUFFER_NAME), false)
    if not created then
        utils.reset_buffer_content(buffer)
        pcall(vim.api.nvim_buf_clear_namespace, buffer, ANSI_NS, 0, -1)
    else
        initialize_syntax_highlighting(buffer)
        -- Don't leave the command running unseen once its output is gone (q, :bd, :bw)
        vim.api.nvim_create_autocmd({ 'BufDelete', 'BufWipeout' }, {
            buffer = buffer,
            callback = function()
                if buffer == run_buffer then kill_running_job() end
            end,
        })
    end
    return buffer
end


--- Update buffer with new output lines from run number `seq`.
--- reset_colors resets the ANSI state first (for the trailer written at exit).
local function update_output(data, seq, reset_colors)
    if not data or #data == 0 then return end

    vim.schedule(function()
        -- Output from a previous run may already be queued when a new run resets the buffer
        if seq ~= run_sequence then return end
        local buffer = run_buffer
        if not buffer or not utils.is_buffer_valid(buffer) then return end
        if reset_colors then current_ansi_state = nil end

        -- Each window showing this buffer follows the output only while its cursor is
        -- on the last line. A freshly reset buffer has a single line, so new runs
        -- still start out following.
        local line_count = utils.get_buffer_line_count(buffer)
        local following = {}
        for _, window in ipairs(vim.fn.win_findbuf(buffer)) do
            if utils.get_cursor_position(window).line == line_count then
                table.insert(following, window)
            end
        end

        -- stdout and stderr are not emitted immediately, they are accumulated and emitted
        -- in batches upon flush. Neovim emits a different chunk for each line emitted into
        -- stack prior to flush.
        for idx, chunk in ipairs(data) do
            -- More then one chunk means the flush has emitted multiple lines,
            -- so we can safely append a new empty line for the next chunk.
            if idx > 1 then
                utils.set_buffer_lines(buffer, -1, -1, { '' })
                reset_line()
            end
            -- Process the chunk to handle ANSI codes and update buffer content.
            -- Every chunk but the last ends its line.
            handle_chunk(chunk, buffer, idx < #data)
        end

        -- Auto-scroll to bottom the windows whose cursor was already at the end
        -- This allows users to scroll up and read output without being forced to the bottom on every update
        line_count = utils.get_buffer_line_count(buffer)
        for _, window in ipairs(following) do
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
    }, seq, true)
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
    reset_line()
    pending_input = ''
    -- Initially populate buffer with command info
    update_output({ '@ ' .. run_cwd, '$ ' .. cmd, '', ''}, this_run)
    -- Start async job
    local function on_output(_, data)
        update_output(data, this_run)
    end
    local job_opts = {
        -- Using pty on non-windows systems so tools think they're in a real terminal
        -- (plain pipes on Windows to avoid compatibility issues)
        pty = not is_windows,
        -- With a pty, git log, man, etc. would start a pager and wait for input forever.
        -- env extends the inherited environment (clear_env is off).
        env = not is_windows and { PAGER = 'cat', GIT_PAGER = 'cat', MANPAGER = 'cat' } or nil,
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
