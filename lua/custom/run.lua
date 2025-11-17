-- Minimal async background runner with live output window and clickable file:line parsing

local current_buf = nil
local current_win = nil
local current_job = nil

local function strip_ansi(s)
  return s:gsub('\27%[[%d;]*[%a]', '')
end

local function parse_file_line(line)
  local clean = strip_ansi(line)
  local file, lnum, col

  -- Try common patterns: file:line:col, file:line, file(line,col), file(line)
  file, lnum, col = clean:match('([%w%._%+/%-~]+):(%d+):(%d+)')
  if not file then
file, lnum = clean:match('([%w%._%+/%-~]+):(%d+)')
  end
  if not file then
file, lnum, col = clean:match('([%w%._%+/%-~]+)%((%d+),(%d+)%)')
  end
  if not file then
file, lnum = clean:match('([%w%._%+/%-~]+)%((%d+)%)')
  end

  if file and lnum then
-- Expand paths and verify file exists
if file:sub(1, 1) == '~' then
  file = vim.fn.expand(file)
elseif not file:match('^/') then
  file = vim.fn.fnamemodify(file, ':p')
end

if vim.fn.filereadable(file) == 1 then
  return file, tonumber(lnum), tonumber(col or 1)
end
  end

  return nil, nil, nil
end

local function open_file_at_line()
  local cursor_line = vim.api.nvim_win_get_cursor(0)[1]
  local line = vim.api.nvim_buf_get_lines(0, cursor_line - 1, cursor_line, false)[1] or ''
  local file, lnum, col = parse_file_line(line)

  if not file then return end

  -- Open in the left window
  vim.cmd('wincmd h')
  vim.cmd('edit ' .. vim.fn.fnameescape(file))
  pcall(vim.api.nvim_win_set_cursor, 0, { lnum, math.max(0, col - 1) })
  vim.cmd('normal! zz')
end

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

  -- Syntax highlighting
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

  -- Keymaps
  local opts = { buffer = buf, noremap = true, silent = true }
  vim.keymap.set('n', '<CR>', open_file_at_line, vim.tbl_extend('force', opts, { desc = 'Open file:line' }))
  vim.keymap.set('n', '<LeftMouse>', open_file_at_line, vim.tbl_extend('force', opts, { desc = 'Click to open' }))
  vim.keymap.set('n', 'q', '<cmd>close<CR>', vim.tbl_extend('force', opts, { desc = 'Close window' }))

  return buf, win
end

local function run_command(cmd)
  -- Stop existing job
  if current_job then
vim.fn.jobstop(current_job)
  end

  -- Create or reuse output window
  if not current_buf or not vim.api.nvim_buf_is_valid(current_buf) then
current_buf, current_win = create_output_window()
  else
vim.bo[current_buf].modifiable = true
vim.api.nvim_buf_set_lines(current_buf, 0, -1, false, {})

-- Show window if hidden
local wins = vim.fn.win_findbuf(current_buf)
if #wins == 0 then
  vim.cmd('botright vsplit')
  current_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(current_win, current_buf)
  vim.api.nvim_win_set_width(current_win, 60)
else
  current_win = wins[1]
end
  end

  -- Add command header
  vim.bo[current_buf].modifiable = true
  vim.api.nvim_buf_set_lines(current_buf, 0, 0, false, { '$ ' .. cmd, '' })
  vim.bo[current_buf].modifiable = false

  -- Async output handler
  local function append_chunk(data)
if not data or #data == 0 then return end

vim.schedule(function()
  if not vim.api.nvim_buf_is_valid(current_buf) then return end

  vim.bo[current_buf].modifiable = true

  for _, line in ipairs(data) do
if line ~= '' then
  vim.api.nvim_buf_set_lines(current_buf, -1, -1, false, { line })
end
  end

  vim.bo[current_buf].modifiable = false

  -- Auto-scroll to bottom
  if vim.api.nvim_win_is_valid(current_win) then
pcall(vim.api.nvim_win_set_cursor, current_win, { vim.api.nvim_buf_line_count(current_buf), 0 })
  end
end)
  end

  -- Start async job
  current_job = vim.fn.jobstart(cmd, {
on_stdout = function(_, data) append_chunk(data) end,
on_stderr = function(_, data) append_chunk(data) end,
on_exit = function(_, exit_code)
  vim.schedule(function()
if not vim.api.nvim_buf_is_valid(current_buf) then return end
vim.bo[current_buf].modifiable = true
vim.api.nvim_buf_set_lines(current_buf, -1, -1, false, {
  '',
  string.format('[Process exited with code %d]', exit_code),
})
vim.bo[current_buf].modifiable = false
  end)
  current_job = nil
end,
  })
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
  complete = function(arglead)
local files = vim.fn.getcompletion(arglead, 'file')
local cmds = vim.fn.getcompletion(arglead, 'shellcmd')

-- Commands first, then files, no duplicates
local result = {}
local seen = {}
for _, v in ipairs(cmds) do
  result[#result + 1] = v
  seen[v] = true
end
for _, v in ipairs(files) do
  if not seen[v] then
result[#result + 1] = v
  end
end
return result
  end,
  desc = 'Run command in background with live output',
})
