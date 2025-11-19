-- Async command runner with live output in a split window
-- Supports clickable file:line navigation and syntax highlighting

-- ============================================================================
-- State
-- ============================================================================

local state = {
  buf = nil,       -- Output buffer handle
  win = nil,       -- Output window handle
  job = nil,       -- Current running job ID
  last_cmd = nil,  -- Last command for recompile
}

-- ============================================================================
-- Utility Functions
-- ============================================================================

--- Remove ANSI escape codes from a string
local function strip_ansi(str)
  return str:gsub('\27%[[%d;]*[%a]', '')
end

--- Parse file path and line number from compiler/linter output
--- Supports formats: file:line:col, file:line, file(line,col), file(line)
---@return number|nil column_number
local function parse_file_location(line)
  local clean = strip_ansi(line)
  local file, lnum, col

  -- Try patterns: file:line:col or file:line
  file, lnum, col = clean:match('([%w%._%+/%-~]+):(%d+):?(%d*)')

  -- Try patterns: file(line,col) or file(line)
  if not file then
    file, lnum, col = clean:match('([%w%._%+/%-~]+)%((%d+),?(%d*)%)')
  end

  if not (file and lnum and lnum ~= '') then
    return nil, nil, nil
  end

  -- Expand and normalize path
  if file:sub(1, 1) == '~' then
    file = vim.fn.expand(file)
  elseif not file:match('^/') then
    file = vim.fn.fnamemodify(file, ':p')
  end

  -- Verify file exists
  if vim.fn.filereadable(file) == 1 then
    return file, tonumber(lnum), tonumber(col ~= '' and col or 1)
  end

  return nil, nil, nil
end

--- Find the next/previous line with a file location
---@param direction number 1 for next, -1 for previous
---@return number|nil line_number
local function find_next_file_location(direction)
  local current_line = vim.api.nvim_win_get_cursor(0)[1]
  local total_lines = vim.api.nvim_buf_line_count(0)
  local line_num = current_line + direction

  -- Wrap around search
  while line_num > 0 and line_num <= total_lines do
    local line = vim.api.nvim_buf_get_lines(0, line_num - 1, line_num, false)[1] or ''
    local file = parse_file_location(line)

    if file then
      return line_num
    end

    line_num = line_num + direction

    -- Wrap around
    if line_num > total_lines then
      line_num = 1
    elseif line_num < 1 then
      line_num = total_lines
    end

    -- Prevent infinite loop
    if line_num == current_line then
      break
    end
  end

  return nil
end

--- Navigate to next file location in output
local function goto_next_location()
  local next_line = find_next_file_location(1)
  if next_line then
    vim.api.nvim_win_set_cursor(0, { next_line, 0 })
  end
end

--- Navigate to previous file location in output
local function goto_prev_location()
  local next_line = find_next_file_location(-1)
  if next_line then
    vim.api.nvim_win_set_cursor(0, { next_line, 0 })
  end
end

--- Find existing buffer for a file path
---@param filepath string
---@return number|nil bufnr
local function find_buffer_by_path(filepath)
  local normalized = vim.fn.fnamemodify(filepath, ':p')

  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) and vim.api.nvim_buf_is_loaded(buf) then
      local buf_name = vim.api.nvim_buf_get_name(buf)
      if buf_name ~= '' then
        local buf_normalized = vim.fn.fnamemodify(buf_name, ':p')
        if buf_normalized == normalized then
          return buf
        end
      end
    end
  end

  return nil
end

--- Navigate to file at cursor line (callback for keymaps)
local function open_file_at_cursor()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(0, cursor_line - 1, cursor_line, false)[1] or ''
  local file, lnum, col = parse_file_location(line)

  if not file then
    return
  end

  -- Jump to left window and open file
  vim.cmd('wincmd h')

  -- Check if buffer already exists and switch to it, otherwise open file
  local existing_buf = find_buffer_by_path(file)
  if existing_buf then
    vim.api.nvim_win_set_buf(0, existing_buf)
  else
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
  end

  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(0, col - 1) })
  vim.cmd('normal! zz')
end

-- ============================================================================
-- Window & Buffer Management
-- ============================================================================

--- Setup syntax highlighting for the output buffer
---@param buf number
local function setup_syntax(buf)
  vim.api.nvim_buf_call(buf, function()
    vim.cmd([[
      syntax clear
      syntax match RunCommand /^\$ .*/
      syntax match RunError /\c\<error\>\|\cfailed\|\c\<fatal\>/
      syntax match RunWarning /\c\<warning\>\|\c\<warn\>/
      syntax match RunFilePath /\v[a-zA-Z0-9_.+\/~-]+:\d+(:\d+)?/
      syntax match RunExitCode /^\[Process exited with code \d\+\]$/
      highlight default link RunCommand Comment
      highlight default link RunError ErrorMsg
      highlight default link RunWarning WarningMsg
      highlight default link RunFilePath Directory
      highlight default link RunExitCode Comment
    ]])
  end)
end

--- Setup keymaps for the output buffer
---@param buf number
local function setup_keymaps(buf)
  local map = function(key, fn, desc)
    vim.keymap.set('n', key, fn, { buffer = buf, noremap = true, silent = true, desc = desc })
  end

  map('<CR>', open_file_at_cursor, 'Open file:line')
  map('<Tab>', goto_next_location, 'Next file location')
  map('<S-Tab>', goto_prev_location, 'Previous file location')
  map('r', function() recompile() end, 'Recompile')
end

--- Create a new output window and buffer
---@return number buf Buffer handle
---@return number win Window handle
local function create_output_window()
  local buf = vim.api.nvim_create_buf(false, true)
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.api.nvim_buf_set_name(buf, '[Run Output]')

  vim.cmd('botright vsplit')
  local win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_win_set_width(win, 60)

  setup_syntax(buf)
  setup_keymaps(buf)

  return buf, win
end

--- Ensure output window is visible and clear buffer
local function prepare_window()
  -- Create new window/buffer if needed
  if not state.buf or not vim.api.nvim_buf_is_valid(state.buf) then
    state.buf, state.win = create_output_window()
    return
  end

  -- Clear existing content
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, -1, false, {})

  -- Show window if hidden
  local wins = vim.fn.win_findbuf(state.buf)
  if #wins == 0 then
    vim.cmd('botright vsplit')
    state.win = vim.api.nvim_get_current_win()
    vim.api.nvim_win_set_buf(state.win, state.buf)
    vim.api.nvim_win_set_width(state.win, 60)
  else
    state.win = wins[1]
  end
end

--- Append text to the output buffer
---@param lines string[]
local function append_output(lines)
  if not lines or #lines == 0 then
    return
  end

  vim.schedule(function()
    if not vim.api.nvim_buf_is_valid(state.buf) then
      return
    end

    vim.bo[state.buf].modifiable = true

    for _, line in ipairs(lines) do
      if line ~= '' then
        vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, { line })
      end
    end

    vim.bo[state.buf].modifiable = false

    -- Auto-scroll to bottom
    if vim.api.nvim_win_is_valid(state.win) then
      local line_count = vim.api.nvim_buf_line_count(state.buf)
      pcall(vim.api.nvim_win_set_cursor, state.win, { line_count, 0 })
    end
  end)
end

-- ============================================================================
-- Command Execution
-- ============================================================================

--- Execute a shell command asynchronously with live output
---@param cmd string
local function run_command(cmd)
  -- Stop any running job before starting new one
  if state.job then
    vim.fn.jobstop(state.job)
    state.job = nil
  end

  state.last_cmd = cmd
  prepare_window()

  -- Add command header
  vim.bo[state.buf].modifiable = true
  vim.api.nvim_buf_set_lines(state.buf, 0, 0, false, { '$ ' .. cmd, '' })
  vim.bo[state.buf].modifiable = false

  -- Start async job
  state.job = vim.fn.jobstart(cmd, {
    on_stdout = function(_, data)
      append_output(data)
    end,
    on_stderr = function(_, data)
      append_output(data)
    end,
    on_exit = function(_, exit_code)
      vim.schedule(function()
        if not vim.api.nvim_buf_is_valid(state.buf) then
          return
        end

        vim.bo[state.buf].modifiable = true
        vim.api.nvim_buf_set_lines(state.buf, -1, -1, false, {
          '',
          string.format('[Process exited with code %d]', exit_code),
        })
        vim.bo[state.buf].modifiable = false
      end)
      state.job = nil
    end,
  })
end

--- Recompile - run the last command again
local function recompile()
  if state.last_cmd then
    run_command(state.last_cmd)
  else
    vim.notify('No previous command to recompile', vim.log.levels.WARN)
  end
end

-- ============================================================================
-- User Commands and Keymaps
-- ============================================================================

--- Custom completion for Run command (shell commands + files)
---@param arglead string
---@return string[]
local function complete_run_command(arglead)
  local cmds = vim.fn.getcompletion(arglead, 'shellcmd')
  local files = vim.fn.getcompletion(arglead, 'file')

  -- Combine without duplicates (commands first, then files)
  local seen = {}
  local result = {}

  for _, cmd in ipairs(cmds) do
    result[#result + 1] = cmd
    seen[cmd] = true
  end

  for _, file in ipairs(files) do
    if not seen[file] then
      result[#result + 1] = file
    end
  end

  return result
end

vim.api.nvim_create_user_command('Run', function(opts)
  local cmd = opts.args

  if cmd == '' then
    vim.ui.input({
      prompt = 'Command: ',
      completion = 'file',
    }, function(input)
      if input and input ~= '' then
        run_command(input)
      end
    end)
  else
    run_command(cmd)
  end
end, {
  nargs = '*',
  complete = complete_run_command,
  desc = 'Run command in background with live output',
})

vim.keymap.set('n', '<leader>r', ':Run ', { noremap = true, desc = 'Run command' })
