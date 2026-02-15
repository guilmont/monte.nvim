-- Async command runner with live output in a split window

local utils = require('custom.utils')

-- ============================================================================
-- Auto completion
-- ============================================================================

--- Global cache variables
local commands_cache = nil
local environ_cache = nil

--- Fill the commands cache from PATH
function fill_commands_cache()
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
function fill_environ_cache()
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
    if arg_lead:find('/') or arg_lead:sub(1,1) == '~' then
        local dir = arg_lead:match('(.*/)') or './'
        local base = arg_lead:sub(#dir + 1)

        local expanded_dir = vim.fn.expand(dir)
        if vim.fn.isdirectory(expanded_dir) == 0 then
            return {}
        end
        if expanded_dir:sub(-1) ~= '/' then
            expanded_dir = expanded_dir .. '/'
        end

        local entries = vim.fn.readdir(expanded_dir)
        local matches = {}
        for _, name in ipairs(entries) do
            if name ~= '.' and name ~= '..' and name:sub(1, #base) == base then
                local full = expanded_dir .. name
                local is_dir = vim.fn.isdirectory(full) == 1
                local display = dir .. name .. (is_dir and '/' or '')
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

local ansi_namespace = nil
local current_ansi_state = nil  -- Tracks ANSI state across lines
local navigation_marks = {}  -- Maps line numbers to file locations

local has_carriage_return = false -- Used for overwrite detection

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

--- Recompile - run the last command again
local function rerun_last_command()
    if last_command then
        run_command(last_command)
    else
        vim.notify('No previous command to re-run', vim.log.levels.WARN)
    end
end

--- Map ANSI color codes to highlight groups
local function get_ansi_highlight(code)
    local colors = {['31']='Red',         ['32']='Green',     ['33']='Yellow',     ['34']='Blue',
                    ['35']='Magenta',     ['36']='Cyan',      ['37']='White',
                    ['91']='BoldRed',     ['92']='BoldGreen', ['93']='BoldYellow', ['94']='BoldBlue',
                    ['95']='BoldMagenta', ['96']='BoldCyan',  ['97']='BoldWhite'}

    if not code:find(';') then
        return colors[code] and 'Ansi' .. colors[code]
    end

    -- Parse combined codes
    local parts = vim.split(code, ';')
    local style, color = '', nil
    for _, p in ipairs(parts) do
        if p == '1' then style = 'Bold'
        elseif p == '3' then style = 'Italic'
        elseif p == '4' then style = 'Underline'
        elseif p == '9' then style = 'Strike'
        elseif colors[p] then color = p
        end
    end

    if color then return 'Ansi' .. style .. colors[color]
    elseif style ~= '' then return 'Ansi' .. style
    end
end

--- Parse terminal control sequences (SGR/CSI/OSC/CR) and apply highlighting
local function parse_terminal_sequences(line)
    local clean_text = ''
    local highlights = {}
    local current_hl = current_ansi_state
    local pos = 0
    local hl_start = current_hl and 0 or nil

    -- Strip ANSI codes, carriage returns, and track positions
    local i = 1
    local has_cr = false
    while i <= #line do
        local byte = line:byte(i)
        -- Handle carriage return (CR, ^M, \r): ignore to avoid rendering artifacts
        if byte == 13 then
            has_cr = true
            i = i + 1
        elseif byte == 27 and line:sub(i + 1, i + 1) == '[' then
            -- Found ANSI CSI sequence: ESC [ params final
            local rest = line:sub(i + 2)
            local letter_pos = rest:find('%a')
            if letter_pos then
                local final = rest:sub(letter_pos, letter_pos)
                local params = rest:sub(1, letter_pos - 1)

                if final == 'm' then
                    -- Close previous highlight range before style change
                    if current_hl and hl_start then
                        table.insert(highlights, { hl = current_hl, start = hl_start, stop = pos })
                    end
                    -- Parse SGR parameters and update style state
                    local code = params
                    current_hl = (code == '0' or code == '') and nil or get_ansi_highlight(code)
                    hl_start = current_hl and pos or nil
                else
                    -- Non-SGR CSI (e.g., K to erase line, cursor moves, etc.)
                    -- Ignore sequence: do not emit literal text and keep style state.
                end

                local end_pos = i + 1 + letter_pos
                i = end_pos + 1
            else
                -- Malformed CSI, skip ESC
                i = i + 1
            end
        elseif byte == 27 and line:sub(i + 1, i + 1) == ']' then
            -- Handle OSC (Operating System Command) sequences, e.g., OSC 8 hyperlinks
            -- Format: ESC ] ... BEL (0x07) OR ESC \ (String Terminator)
            local j = i + 2
            local consumed = false
            while j <= #line do
                local b = line:byte(j)
                if b == 7 then
                    -- BEL terminator
                    i = j + 1
                    consumed = true
                    break
                elseif b == 27 and j + 1 <= #line and line:sub(j + 1, j + 1) == '\\' then
                    -- ESC \ terminator
                    i = j + 2
                    consumed = true
                    break
                else
                    j = j + 1
                end
            end
            if not consumed then
                -- Reached end without terminator; drop the remainder
                i = j
            end
        else
            -- Regular character
            clean_text = clean_text .. line:sub(i, i)
            pos = pos + 1
            i = i + 1
        end
    end

    -- Close final highlight
    if current_hl and hl_start then
        table.insert(highlights, { hl = current_hl, start = hl_start, stop = pos })
    end

    current_ansi_state = current_hl
    return clean_text, highlights, has_cr
end

--- Search for file:line or file:line:col patterns and set navigation marks
local function search_locations(line, line_num)
    local pos = 1
    while pos <= #line do
        -- Try matching file:line:col first
        local s, e, file, lineno, colno = line:find('([^%s:]+):(%d+):(%d+)', pos)

        -- If no match with column, try without column
        if not s then
            s, e, file, lineno = line:find('([^%s:]+):(%d+)', pos)
            colno = nil
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
            vim.api.nvim_buf_set_extmark(buffer, ansi_namespace, line_num, s - 1, {
                end_col = e,
                hl_group = 'Directory',
            })
        end
        pos = e + 1
    end
end


-- ============================================================================
-- Window And Buffer Management
-- ============================================================================

--- Initialize syntax highlighting for output buffer
local function initialize_syntax_highlighting(buffer)
    -- Reset ANSI state for new command
    current_ansi_state = nil
    -- Create fresh namespace with unique name for each new buffer
    ansi_namespace = vim.api.nvim_create_namespace('ansi_hl')

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
        utils.close_window(window)
    end, { buffer = buffer, desc = 'Close Run Output Window' })

    -- Set up keymap for navigating to file:line under cursor
    vim.keymap.set('n', '<CR>', function()
        local line = utils.get_cursor_position(window).line - 1
        if navigation_marks[line] then
            local mark = navigation_marks[line]
            -- Check if file is already open in a window
            local buffer = utils.find_buffer_by_name(mark.file)
            if buffer then
                local win = utils.reuse_or_create_window_for_buffer(buffer)
                utils.set_cursor_position(win, mark.line, mark.col)
            -- File not open, edit it in current window
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
    -- Otherwise create a new buffer
    else
        buffer = vim.api.nvim_create_buf(true, true)
        vim.bo[buffer].buftype = 'nofile'
        vim.bo[buffer].bufhidden = 'hide'
        vim.bo[buffer].swapfile = false
        vim.api.nvim_buf_set_name(buffer, BUFFER_NAME)

        -- Setup syntax highlighting and keymaps for the buffer
        initialize_syntax_highlighting(buffer)
    end
    -- Clear any existing content
    vim.bo[buffer].modifiable = true
    utils.set_buffer_lines(buffer, 0, -1, { '@ ' .. vim.fn.getcwd(), '' })
    vim.bo[buffer].modifiable = false

    return buffer
end


--- Update buffer with new output lines
local function update_output(data)
    if not data or #data == 0 then return end

    vim.schedule(function()
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

        -- Go thru each chunk of new data
        vim.bo[buffer].modifiable = true
        for idx, chunk in ipairs(data) do
            local offset = 0
            local line, highlights, has_cr = parse_terminal_sequences(chunk)

            if idx == 1 then
                if not has_carriage_return then
                    local last_line = utils.get_buffer_lines(buffer, -2, -1)[1] or ''
                    line = last_line .. line
                    offset = #last_line
                end

                utils.set_buffer_lines(buffer, -2, -1, { line })
            else
                utils.set_buffer_lines(buffer, -1, -1, { line })
            end
            -- Update carriage return state for next input data
            has_carriage_return = has_cr

            local line_num = utils.get_buffer_line_count(buffer) - 1
            -- Search for file:line patterns and set navigation marks
            search_locations(line, line_num)

            -- Apply highlight ranges (offset by existing line length if appending)
            for _, hl in ipairs(highlights) do
                vim.api.nvim_buf_set_extmark(buffer, ansi_namespace, line_num, hl.start + offset, {
                    end_col = hl.stop + offset,
                    hl_group = hl.hl,
                })
            end
        end

        vim.bo[buffer].modifiable = false

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
    command_start_time = vim.loop.now()
    -- Reset navigation marks
    navigation_marks = {}
    -- Initialize content
    update_output({ '$ ' .. cmd, '', ''})
    -- Start async job
    local job_opts = {
        -- Allocate a PTY so tools think they're in a real terminal
        -- and emit ANSI colors (helps Cargo, npm, etc.)
        pty = true,
        on_stdout = function(_, data) update_output(data) end,
        on_stderr = function(_, data) update_output(data) end,
        on_exit = on_complete,
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
