-- Perforce integration for Neovim

-- ============================================================================
-- SIMPLE FILE OPERATIONS (outside window)
-- ============================================================================

-- Perforce uses url encoding for special characters in paths
-- This function decodes such strings
-- E.g. %20 -> space, %23 -> #, %40 -> @
local function url_decode(str)
  return str:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
end
-- End the way back
-- This function encodes special characters in paths
local function url_encode(str)
  return str:gsub('([@#%%*])', function(c) return string.format('%%%02X', string.byte(c)) end)
end

-- Run a p4 command and return output lines or error
local function p4_cmd(args)
  if not args or args == '' or not args.cmd or args.cmd == '' then
    error('No p4 command given')
  end

  -- Construct local command
  local cmd = 'p4 ' .. args.cmd
  -- If filepath is given, encode it
  if args.filepath then
    cmd = cmd .. ' ' .. url_encode(vim.fn.shellescape(args.filepath))
  end
  -- If newpath is given for move/rename, encode it
  if args.newpath then
    cmd = cmd .. ' ' .. url_encode(vim.fn.shellescape(args.newpath))
  end
  -- If revision is given, append it
  if args.revision then
    cmd = cmd .. '#' .. args.revision
  end

  -- Run command
  vim.schedule(function() vim.print('Running: ' .. cmd) end)
  local result = vim.fn.systemlist(cmd)
  if vim.v.shell_error ~= 0 then
    error('\nP4 error:\n ' .. table.concat(result, '\n '))
  end
  -- Decode output lines
  for i, line in ipairs(result) do
    result[i] = url_decode(line)
  end
  return result
end

local function p4_edit()
  local file = vim.fn.expand('%:p')
  local result = p4_cmd({cmd = 'edit ', filepath = file})
  if result then
    vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
    vim.bo.readonly = false
  end
end

local function p4_add()
  local file = vim.fn.expand('%:p')
  local result = p4_cmd({cmd = 'add ', filepath = file})
  if result then
    vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
  end
end

local function p4_revert()
  local file = vim.fn.expand('%:p')
  vim.ui.input(
    { prompt = 'Revert ' .. vim.fn.expand('%') .. '? (y/N): ' },
    function(input)
      if not (input and input:lower() == 'y') then return end
      -- Revert file
      local result = p4_cmd({cmd = 'revert ', filepath = file})
      if result then
        vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
        vim.cmd('checktime')
        vim.bo.readonly = true
      end
    end)
end

local function p4_delete()
  local file = vim.fn.expand('%:p')
  vim.ui.input(
    { prompt = 'Delete ' .. vim.fn.fnamemodify(file, ':t') .. '? (y/N): ' },
    function(input)
      if not (input and input:lower() == 'y') then return end
      -- Delete file
      local result = p4_cmd({cmd = 'delete ', filepath = file})
      if result then
        vim.cmd('bd!')  -- Close buffer
        vim.notify('P4: File marked for delete', vim.log.levels.INFO)
      end
    end)
end

local function p4_rename()
  local filepath = vim.fn.expand('%:p')
  vim.ui.input(
    { prompt = 'Move/rename to: ', default = filepath },
    function(new_path)
      if not (new_path and new_path ~= filepath) then return end
      -- First we need to edit the source file if not already opened
      p4_cmd({cmd = 'edit ', filepath = filepath})
      -- Move/Rename file
      local result = p4_cmd({cmd = 'move ', filepath = filepath, newpath = new_path})
      if result then
        vim.notify('P4: File moved/renamed', vim.log.levels.INFO)
        local old_buf = vim.api.nvim_get_current_buf()
        vim.cmd('edit ' .. vim.fn.fnameescape(new_path))
        vim.api.nvim_buf_delete(old_buf, { force = true })
      end
  end)
end

-- Gvdiffsplit-like view: left = depot have, right = real file buffer
local function p4_vdiffsplit(file)
  -- Get depot info for #have
  local depot_file, have_rev, action, moved_file
  local fstat = p4_cmd({cmd = 'fstat ', filepath = file})
  if fstat then
    for _, line in ipairs(fstat) do
      local df = line:match('^%.%.%. depotFile (.+)$')
      if df then depot_file = df end
      local hr = line:match('^%.%.%. haveRev (%d+)$')
      if hr then have_rev = hr end
      local ac = line:match('^%.%.%. action (.+)$')
      if ac then action = ac end
      local mf = line:match('^%.%.%. movedFile (.+)$')
      if mf then moved_file = mf end
    end
  else
    error('Failed to get file info from Perforce for ' .. file)
  end
  -- Build left buffer content (depot #have, empty for add)
  local depot_content = {}
  if action == 'add' then
    depot_content = {}
  elseif action == 'move/add' then
    -- For move/add, get content from movedFile at #have
    depot_content = p4_cmd({cmd = 'print -q ', filepath = moved_file, revision = have_rev})
  else
    -- For edit
    depot_content = p4_cmd({cmd = 'print -q ', filepath = depot_file, revision = have_rev})
  end

  -- Ensure the local file is the current buffer (like Gvdiffsplit)
  if vim.fn.expand('%:p') ~= file then
    vim.cmd('edit ' .. vim.fn.fnameescape(file))
  end

  local local_win = vim.api.nvim_get_current_win()
  local local_buf = vim.api.nvim_get_current_buf()

  -- Create scratch buffer for depot side
  local left_buf = vim.api.nvim_create_buf(false, true)
  local ft = vim.filetype.match({ filename = file }) or ''
  vim.bo[left_buf].filetype = ft
  vim.bo[left_buf].buftype = 'nofile'
  vim.bo[left_buf].bufhidden = 'wipe'
  vim.api.nvim_buf_set_name(left_buf, (depot_file or 'P4 Depot') .. (have_rev and ('#' .. have_rev) or ''))
  vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, depot_content)

  -- Open vertical split to the LEFT of the file window (keeps sidebars leftmost)
  vim.api.nvim_set_current_win(local_win)
  vim.cmd('leftabove vsplit')
  local left_win = vim.api.nvim_get_current_win()
  vim.api.nvim_win_set_buf(left_win, left_buf)

  -- Enable diff mode on both, with common navigation
  vim.api.nvim_win_call(left_win, function() vim.cmd('diffthis') end)
  vim.api.nvim_win_call(local_win, function() vim.cmd('diffthis') end)
  vim.wo[left_win].scrollbind = true
  vim.wo[local_win].scrollbind = true
  vim.wo[left_win].cursorbind = true
  vim.wo[local_win].cursorbind = true


  -- Close helper: leave the real buffer, wipe the depot buffer, stop diff
  local function close_diff()
    pcall(vim.api.nvim_win_call, local_win, function() vim.cmd('diffoff') end)
    pcall(vim.api.nvim_win_call, left_win, function() vim.cmd('diffoff') end)
    if vim.api.nvim_buf_is_valid(left_buf) then
      pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
    end
    if vim.api.nvim_win_is_valid(left_win) then
      pcall(vim.api.nvim_win_close, left_win, true)
    end
    if vim.api.nvim_win_is_valid(local_win) then
      vim.api.nvim_set_current_win(local_win)
    end
  end

  -- Auto-clean depot buffer when its window closes
  vim.api.nvim_create_autocmd('WinClosed', {
    callback = function(args)
      local closed = tonumber(args.match)
      if closed == left_win then
        vim.schedule(close_diff)
      end
    end,
    once = true,
  })

end


-- ===========================================================================
-- PERFORCE WINDOW
-- ===========================================================================

-- Perforce data
local State = nil;

local function get_initial_state()
return {
  client = {},
  changelists = {},
  window = {},
}
end

-- DATA FETCHING -------------------------------------------------------------

local function get_client_info()
  local client_info = p4_cmd({cmd = 'info'})
  local client_name, client_root, client_stream
  for _, line in ipairs(client_info) do
    if not client_name then
      client_name = line:match('^Client name:%s+(.+)$')
    end
    if not client_root then
      client_root = line:match('^Client root:%s+(.+)$')
    end
    if not client_stream then
      client_stream = line:match('^Client stream:%s+(.+)$')
    end
    -- Break early if all info found
    if client_name and client_root and client_stream then break end
  end

  -- Ensure that all data was found
  if client_name and client_root and client_stream then
    return {
      name = client_name,
      root = client_root,
      stream = client_stream,
    }
  end
  -- Error out if incomplete
  error('Failed to retrieve complete Perforce client info')
end

local function get_changelist_description(cl)
  -- Nothing to do for default changelist
  if cl == 'default' then return 'Default changelist' end

  local change_info = p4_cmd({cmd = 'change -o ' .. cl})
  if not change_info then
    error('Failed to get changelist info for CL ' .. cl)
  end

  local in_desc = false
  for _, line in ipairs(change_info) do
    if line:match('^Description:') then
      in_desc = true
    elseif in_desc and line:match('^%s+') then
      return line:match('^%s+(.*)')
    end
  end
  -- If we reach here, the change list doesn't have a description
  return '(no description)'
end

local function get_all_changelists()
  local file_map = {}
  --  Get all changes for the current client
  local changes_output = p4_cmd({cmd = 'changes -c ' .. vim.fn.shellescape(State.client.name)})
  for _, line in ipairs(changes_output) do
    local change_number = line:match('^Change (%d+)')
    if change_number then
      file_map[change_number] = {
        description = get_changelist_description(change_number),
        shelved_files= {},
        opened_files = {},
        expand_shelf = false,
      }
    end
  end
  -- Ensure default changelist is included
  if not file_map['default'] then
    file_map['default'] = {
      description = 'Default changelist',
      shelved_files = {},
      opened_files = {}
    }
  end
  -- Search for all opened files and group by changelist
  local files_output = p4_cmd({cmd = 'opened'})
  for _, line in ipairs(files_output) do
    local depot_path = line:match('^(//[^#]+)')
    if depot_path then
      local action = line:match('#%d+ %- ([^%s]+)')
      local change_number = line:match('change (%d+)') or 'default'
      -- Insert file to change_number
      table.insert(file_map[change_number].opened_files, {
        depot_path = depot_path,
        action = action,
        relative_path = depot_path:gsub(State.client.stream .. '/', ''),
        filename = depot_path:match('([^/]+)$'),
      })
    end
  end
  --- Now check for shelved files in all changelists
  for cn, _ in pairs(file_map) do
    if cn ~= 'default' then
      local in_shelved = false
      local shelved_output = p4_cmd({cmd = 'describe -s -S ' .. cn})
      for _, line in ipairs(shelved_output) do
        if line:match('^Shelved files') then
          in_shelved = true
        elseif in_shelved then
          local depot_path = line:match('^%.%.%. (//[^#]+)')
          if depot_path then
            table.insert(file_map[cn].shelved_files, depot_path)
          end
        end
      end
    end
  end
  -- Return the complete changelist file map
  return file_map
end

-- DISPLAY RENDERING ------------------------------------------------------------

local function build_display_lines()
  if not State then
    error('State is not initialized when building display')
  end

  local lines = {}
  local index_map = {}
  for cn, content in pairs(State.changelists) do
    -- CL header line
    local file_count = #content.opened_files
    local count_str = file_count > 0
      and string.format(' (%d file%s)', file_count, file_count ~= 1 and 's' or '')
      or ' (empty)'
    table.insert(lines, string.format('CL %s: %s%s', cn, content.description, count_str))
    table.insert(index_map, { type = 'changelist', change_number = cn })

    -- Shelf toggle line
    local shelf_size = #content.shelved_files
    if shelf_size > 0 then
      local expand_char = content.expand_shelf and '▼' or '▶'
      table.insert(lines, string.format('  %s Shelf (%d file%s)', expand_char, shelf_size, shelf_size ~= 1 and 's' or ''))
      table.insert(index_map, { type = 'shelf_toggle', change_number = cn })
      -- Shelved files (if expanded)
      if content.expand_shelf then
        for _, depot_path in ipairs(content.shelved_files) do
          table.insert(lines, string.format('    %s', depot_path))
          table.insert(index_map, { type = 'shelved_file', change_number = cn, shelved_file = depot_path })
        end
      end
    end

    -- Opened files
    for _, file in ipairs(content.opened_files) do
      table.insert(lines, string.format('  %-13s %s', file.action, file.relative_path))
      table.insert(index_map, { type = 'opened_file', change_number = cn, opened_file = file })
    end
    -- Empty line separator
    table.insert(lines, '')
    table.insert(index_map, { type = 'separator' })
  end

  -- Help line
  table.insert(lines, '[Enter=open/edit/toggle | d=diff | r=revert | m=move | s=shelve | u=unshelve | D=delete | N=new CL | A=all]')

  return lines, index_map
end

local function apply_syntax_highlighting(buf)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

  local ns_id = vim.api.nvim_create_namespace('P4Highlight')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_idx = i - 1

    -- CL header lines
    if line:match('^CL ') then
      local cl_num_end = line:find(':')
      if cl_num_end then
        -- Highlight "CL <number>"
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, cl_num_end - 1)

        -- Highlight count
        local count_match = line:match('%((%d+ file[s]?)%)')
        if count_match then
          local count_start = line:find('%(' .. count_match:gsub('([%^%$%(%)%%%.%[%]%*%+%-%?])', '%%%1'))
          if count_start then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Number', line_idx, count_start - 1, count_start + #count_match + 1)
          end
        elseif line:match('%(empty%)') then
          local empty_start = line:find('%(empty%)')
          if empty_start then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, empty_start - 1, empty_start + 6)
          end
        end
      end

    -- Shelf toggle lines
    elseif line:match('^%s+[▶▼] Shelf') then
      local arrow_end = line:find('Shelf') - 1
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Special', line_idx, 0, arrow_end)
      local shelf_start = line:find('Shelf')
      local paren_start = line:find('%(')
      if shelf_start and paren_start then
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, shelf_start - 1, paren_start - 1)
      end

    -- Shelved file lines
    elseif line:match('^%s%s%s%s[^%s]') and not line:match('^%s%s[^%s]') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Directory', line_idx, 0, #line)

    -- File action lines
    elseif line:match('^%s%s[a-z]+%s+') then
      local action = line:match('^%s%s([a-z]+)')
      if action then
        local hl_group
        if action == 'edit' then
          hl_group = 'DiffChange'
        elseif action == 'add' then
          hl_group = 'DiffAdd'
        elseif action == 'delete' then
          hl_group = 'DiffDelete'
        elseif action == 'move/add' or action == 'move/delete' then
          hl_group = 'DiffText'
        else
          hl_group = 'Identifier'
        end

        vim.api.nvim_buf_add_highlight(buf, ns_id, hl_group, line_idx, 2, 2 + #action)

        -- Highlight the filename
        local file_start = line:find('[^%s]', 13)
        if file_start then
          vim.api.nvim_buf_add_highlight(buf, ns_id, 'String', line_idx, file_start - 1, #line)
        end
      end

    -- Help line
    elseif line:match('^%[.*%]$') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
    end
  end
end

local function update_display(refresh_data)
  -- This is annoying but we have to check validity again for linter to be happy
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    return
  end
  -- Optionally refresh data
  if refresh_data then
    State.changelists = get_all_changelists()
  end

  -- Get current cursor position to keep it in place after update
  local cursor_line = vim.api.nvim_win_get_cursor(State.window.win)

  -- Rebuild display lines and index map
  local lines, index_map = build_display_lines()
  State.window.index_map = index_map

  -- Update buffer content
  local buf = vim.api.nvim_win_get_buf(State.window.win)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  apply_syntax_highlighting(buf)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

  -- Update window size and position
  local width = math.floor(0.9 * vim.o.columns)
  local height = math.min(#lines, math.floor(0.9 * vim.o.lines))
  vim.api.nvim_win_set_config(State.window.win, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
  })

  -- Restore cursor position
  local line_count = #lines
  cursor_line[1] = cursor_line[1] > line_count and line_count or cursor_line[1]

  vim.api.nvim_win_set_cursor(State.window.win, cursor_line)
end

-- WINDOW KEYBIND ACTIONS -------------------------------------------------------

local function close_window()
  if State and State.window.win and vim.api.nvim_win_is_valid(State.window.win) then
    vim.api.nvim_win_close(State.window.win, true)
  end
  State = nil;
end

local function input_action()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end

  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  -- Just in case
  if not data then
    error('No action data found for line ' .. line)
  end

  -- Toggle shelf expansion
  if data.type == 'shelf_toggle' then
    local cn = data.change_number
    State.changelists[cn].expand_shelf = not State.changelists[cn].expand_shelf
    update_display(false)

  -- Open file in editor
  elseif data.type == 'opened_file' then
    vim.api.nvim_win_close(State.window.win, true)
    local filepath = State.client.root .. '/' .. data.opened_file.relative_path
    vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
    close_window()

  -- Edit the description of a changelist
  elseif data.type == 'changelist' then
    vim.ui.input(
      { prompt = 'New changelist description: ' },
      function(description)
        -- Check for cancellation
        if not (description and description ~= '') then
          vim.notify('Description cancelled', vim.log.levels.INFO)
          return
        end
        -- Change description of existing changelist or create new one with description
        local cn = data.change_number == 'default' and 'new' or data.change_number
        vim.system(
          { "p4", "change", "-i" },
          { stdin = string.format("Change: %s\nDescription:\n\t%s\n", cn, description) },
          function(obj) vim.schedule(
            function()
              -- Move all opened files to new changelist
              local target = obj.stdout:match('Change (%d+)')
              local files_to_move = State.changelists[data.change_number].opened_files
              for _, file in ipairs(files_to_move) do
                p4_cmd({cmd = 'reopen -c ' .. target .. ' ', filepath = file.depot_path})
              end
              -- Refresh and update display
              update_display(true)
            end
          ) end )
      end
    )
  end
end

local function shelve_files()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  -- Shelve single file
  if data.type == 'opened_file' then
    local file = data.opened_file
    local current_cl = data.change_number
    if current_cl == 'default' then
      vim.notify('Cannot shelve files in default changelist', vim.log.levels.WARN)
      return
    end
    p4_cmd({cmd = 'shelve -f -c ' .. current_cl .. ' ', filepath = file.depot_path})
    update_display(true)
  -- Shelve entire changelist
  elseif data.type == 'changelist' then
    local cn = data.change_number
    if cn == 'default' then
      vim.notify('Cannot shelve default changelist', vim.log.levels.WARN)
      return
    end
    p4_cmd({cmd = 'shelve -f -c ' .. cn})
    update_display(true)
  end
end

local function unshelve_files()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  -- Unshelve single file
  if data.type == 'shelved_file' then
    local cn = data.change_number
    local depot_path = data.shelved_file
    p4_cmd({cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn .. ' ', filepath = depot_path})
    vim.cmd('checktime') -- Refresh file in editor if open
    update_display(true)
  -- Unshelve entire changelist
  elseif data.type == 'changelist' then
    local cn = data.change_number
    p4_cmd({cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn})
    vim.cmd('checktime') -- Refresh files in editor if open
    update_display(true)
  end
end

local function revert_files()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  -- Revert single file
  if data.type == 'opened_file' then
    local file = data.opened_file
    vim.ui.input(
      { prompt = 'Revert ' .. file.relative_path .. '? (y/N): ' },
      function(input)
        if not (input and input:lower() == 'y') then return end
        p4_cmd({cmd = 'revert ', filepath = file.depot_path})
        vim.cmd('checktime') -- Refresh file in editor if open
        update_display(true)
      end
    )
  -- Revert entire changelist
  elseif data.type == 'changelist' then
    local cn = data.change_number
    vim.ui.input(
      { prompt = 'Revert all files in changelist ' .. cn .. '? (y/N): ' },
      function(input)
        if not (input and input:lower() == 'y') then return end
        vim.cmd('checktime') -- Refresh files in editor if open
        p4_cmd({cmd = 'revert -c ' .. cn .. ' //...'})
        update_display(true)
      end
    )
  end
end

local function move_files()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  if data.type == 'opened_file' or data.type == 'changelist' then
    local cl_options = {}
    for cn, content in pairs(State.changelists) do
      if cn ~= data.change_number then
        table.insert(cl_options, string.format('%s: %s', cn, content.description))
      end
    end
    -- Prompt user for target changelist
    vim.ui.select(cl_options,
      { prompt = 'Target changelist:', format_item = function(item) return item end },
      function(choice)
        -- Verify that a choice was made
        if not choice then return end
        -- Extract target changelist number
        local target = choice:match('^([^:]+)')
        -- Move all files in changelist
        if data.type == 'changelist' then
          local cn = data.change_number
          local files_to_move = State.changelists[cn].opened_files
          for _, file in ipairs(files_to_move) do
            p4_cmd({cmd = 'reopen -c ' .. target .. ' ', filepath = file.depot_path})
          end
        -- Move single file
        elseif data.type == 'opened_file' then
          p4_cmd({cmd = 'reopen -c ' .. target .. ' ', filepath = data.opened_file.depot_path})
        end
        -- Refresh and update display
        vim.schedule(function() update_display(true) end)
      end
    )
  end
end

local function delete_stuff()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  -- Nothing can be done in default changelist
  if data.change_number == 'default' then
    vim.notify('Cannot delete items in default changelist', vim.log.levels.WARN)
    return
  end

  -- Delete changelist and everything in it
  if data.type == 'changelist' then
    local cn = data.change_number
    -- Check if user is sure
    vim.ui.input(
      { prompt = 'Delete changelist ' .. cn .. ' and all its files? (y/N): ' },
      function(input)
        if not (input and input:lower() == 'y') then return end
        -- First revert all opened files
        p4_cmd({cmd = 'revert -c ' .. cn .. ' //...'})
        -- Then delete shelved files if any
        local shelved_files = State.changelists[cn].shelved_files
        for _, depot_path in ipairs(shelved_files) do
          p4_cmd({cmd = 'shelve -d -c ' .. cn .. ' ', filepath = depot_path})
        end
        -- Finally delete the changelist itself
        p4_cmd({cmd = 'change -d ' .. cn})
        update_display(true)
      end
    )

  -- Delete single shelved file
  elseif data.type == 'shelved_file' then
    local cn = data.change_number
    local depot_path = data.shelved_file
    vim.ui.input(
      { prompt = 'Delete shelved file ' .. depot_path .. ' from CL ' .. cn .. '? (y/N): ' },
      function(input)
        if not (input and input:lower() == 'y') then return end
        p4_cmd({cmd = 'shelve -d -c ' .. cn .. ' ', filepath = depot_path})
        update_display(true)
      end
    )

  -- Delete all the shelved files in a changelist
  elseif data.type == 'shelf_toggle' then
    local cn = data.change_number
    vim.ui.input(
      { prompt = 'Delete all shelved files in changelist ' .. cn .. '? (y/N): ' },
      function(input)
        if not (input and input:lower() == 'y') then return end
        p4_cmd({cmd = 'shelve -d -c ' .. cn})
        update_display(true)
      end
    )
  end
end

local function create_changelist()
  vim.ui.input(
    { prompt = 'Create changelist with description: ' },
    function(description)
      if not (description and description ~= '') then
        vim.notify('Changelist creation cancelled', vim.log.levels.INFO)
        return
      end
      -- Create new changelist with description
      vim.system(
        { "p4", "change", "-i" },
        { stdin = string.format("Change: new\nDescription:\n\t%s\n", description) },
        function(obj) vim.schedule(
          function()
            vim.notify(obj.stdout, vim.log.levels.INFO)
            update_display(true)
          end
        ) end
      )
    end
  )
end

local function show_diff()
  -- Check window validity
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    error('No valid Perforce window for action')
  end
  -- Get action data for current line
  local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
  local data = State.window.index_map[line]
  if not data then
    error('No action data found for line ' .. line)
  end

  if data.type == 'opened_file' then
    local filepath = State.client.root .. '/' .. data.opened_file.relative_path
    close_window()
    vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
    vim.schedule(function() p4_vdiffsplit(filepath) end)
  end
end

local function review_all_opened_files()
  -- Get all files to review
  local files_to_open = {}
  for _, content in pairs(State.changelists) do
    for _, file in ipairs(content.opened_files) do
      if not file.action:match('move/delete') then
        table.insert(files_to_open, State.client.root .. '/' .. file.relative_path)
      end
    end
  end
  -- Close the window
  close_window()
  -- Open each file in its own buffer
  for _, filepath in ipairs(files_to_open) do
      vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
  end
end

-- MAIN WINDOW CREATION FUNCTION -------------------------------------------------------

local function show_window()
  -- Close existing window if it's open
  close_window()

  -- Initialize state
  State = get_initial_state()
  State.client = get_client_info()
  State.changelists = get_all_changelists()

  -- Create display lines and index map for actions
  local lines, index_map = build_display_lines()
  State.window.index_map = index_map

  -- Create buffer
  local buf = vim.api.nvim_create_buf(false, true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  vim.api.nvim_buf_set_name(buf, 'P4 Opened Files')
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  vim.api.nvim_buf_set_option(buf, 'buftype', 'nofile')
  vim.api.nvim_buf_set_option(buf, 'bufhidden', 'wipe')
  vim.api.nvim_buf_set_option(buf, 'swapfile', false)
  apply_syntax_highlighting(buf)
  State.window.buf = buf

  -- Create centered floating window for buffer
  local width = math.floor(0.9 * vim.o.columns)
  local height = math.min(#lines, math.floor(0.9 * vim.o.lines))
  State.window.win = vim.api.nvim_open_win(buf, true, {
    relative = 'editor',
    width = width,
    height = height,
    row = math.floor((vim.o.lines - height) / 2),
    col = math.floor((vim.o.columns - width) / 2),
    style = 'minimal',
    border = 'rounded',
    title = ' P4 Opened Files ',
    title_pos = 'center',
  })

  -- Keymaps
  local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
  vim.keymap.set('n', '<CR>', input_action, opts)
  vim.keymap.set('n', 'r', revert_files, opts)
  vim.keymap.set('n', 'm', move_files, opts)
  vim.keymap.set('n', 's', shelve_files, opts)
  vim.keymap.set('n', 'u', unshelve_files, opts)
  vim.keymap.set('n', 'D', delete_stuff, opts)
  vim.keymap.set('n', 'N', create_changelist, opts)
  vim.keymap.set('n', 'd', show_diff, opts)
  vim.keymap.set('n', 'A', review_all_opened_files, opts)
  for _, key in ipairs({'q', '<Esc>'}) do
      vim.keymap.set('n', key, close_window, opts)
  end
end

-- ============================================================================
-- COMMANDS
-- ============================================================================

vim.api.nvim_create_user_command('P4Window', show_window, { desc = 'P4: Show opened files' })
vim.api.nvim_create_user_command('P4Edit', p4_edit, { desc = 'P4: Edit current file' })
vim.api.nvim_create_user_command('P4Add', p4_add, { desc = 'P4: Add current file' })
vim.api.nvim_create_user_command('P4Revert', p4_revert, { desc = 'P4: Revert current file' })
vim.api.nvim_create_user_command('P4Delete', p4_delete, { desc = 'P4: Delete current file' })
vim.api.nvim_create_user_command('P4Rename', p4_rename, { desc = 'P4: Rename/move current file' })
vim.api.nvim_create_user_command('P4Diff', function() p4_vdiffsplit(vim.fn.expand('%:p')) end,  { desc = 'P4: Diff current file' })
vim.api.nvim_create_user_command('P4ReviewNext', function() vim.cmd('bn | bd #') end, { desc = 'P4: Review next opened file' })

-- Keymaps
vim.keymap.set('n', '<leader>ps', show_window, { desc = 'P4: Show opened files' })
vim.keymap.set('n', '<leader>pe', p4_edit, { desc = 'P4: Edit current file' })
vim.keymap.set('n', '<leader>pa', p4_add, { desc = 'P4: Add current file' })
vim.keymap.set('n', '<leader>pr', p4_revert, { desc = 'P4: Revert current file' })
vim.keymap.set('n', '<leader>pD', p4_delete, { desc = 'P4: Delete current file' })
vim.keymap.set('n', '<leader>pR', p4_rename, { desc = 'P4: Rename/move current file' })
vim.keymap.set('n', '<leader>pd', function() p4_vdiffsplit(vim.fn.expand('%:p')) end, { desc = 'P4: Diff current file' })
vim.keymap.set('n', '<leader>pn', function() vim.cmd('bn | bd #') end, { desc = 'P4: Review next opened file' })
