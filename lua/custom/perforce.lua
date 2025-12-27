-- Perforce integration for Neovim

-- ============================================================================
-- SIMPLE FILE OPERATIONS (outside window)
-- ============================================================================

-- Shared state and buffer naming
local State = nil
local BUFFER_NAME = 'Perforce Window'
local BufferViews = {}

-- Forward declarations for functions used before they're defined
local get_client_info
local get_all_changelists
local build_display_lines
local apply_syntax_highlighting
local update_display

-- Initial empty state
local function get_initial_state()
  return {
    client = {},
    changelists = {},
    window = {},
  }
end

-- Perforce uses url encoding for special characters in paths
-- This function decodes such strings
-- E.g. %20 -> space, %23 -> #, %40 -> @
local function url_decode(str)
  return str:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end)
end

local function set_buffer_lines(buf, lines)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  apply_syntax_highlighting(buf)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
end

local function find_existing_buffer()
  for _, buf in ipairs(vim.api.nvim_list_bufs()) do
    if vim.api.nvim_buf_is_valid(buf) then
      local name = vim.api.nvim_buf_get_name(buf)
      local stem = vim.fn.fnamemodify(name, ':t')
      if stem == BUFFER_NAME then
        return buf
      end
    end
  end
end

local function ensure_buffer()
  local buf = find_existing_buffer()
  if buf and vim.api.nvim_buf_is_valid(buf) then
    return buf
  end
  buf = vim.api.nvim_create_buf(true, false)
  vim.api.nvim_buf_set_name(buf, BUFFER_NAME)
  vim.bo[buf].bufhidden = 'hide'
  vim.bo[buf].swapfile = false
  vim.bo[buf].buftype = 'nofile'
  vim.bo[buf].readonly = true
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)
  return buf
end

local function render_into(win, buf)
  -- Use stored view for this buffer if available
  local view = BufferViews[buf]

  State = get_initial_state()
  State.client = get_client_info()
  State.changelists = get_all_changelists()
  State.window = { win = win, buf = buf }

  local lines, index_map = build_display_lines()
  State.window.index_map = index_map
  set_buffer_lines(buf, lines)

  if view and win and vim.api.nvim_win_is_valid(win) then
    -- Clamp line to new buffer length
    local max_line = math.max(1, #lines)
    if view.lnum and view.lnum > max_line then view.lnum = max_line end
    vim.api.nvim_win_call(win, function()
      pcall(vim.fn.winrestview, view)
    end)
  end
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

-- Resolve a depot path to a local filesystem path using `p4 where`.
local function depot_to_local(depot_path)
  if not depot_path or depot_path == '' then return '' end
  local ok, where = pcall(p4_cmd, { cmd = '-ztag where ', filepath = depot_path })
  if not ok or not where then return '' end
  for _, line in ipairs(where) do
    local path = line:match('^%.%.%. path%s+(.+)$')
    if path and path ~= '' then return path end
  end
  return ''
end

-- Batch resolve multiple depot paths to local paths using a single `p4 where` call.
-- Returns a table mapping depot_path -> local_path
local function batch_depot_to_local(depot_paths)
  if not depot_paths or #depot_paths == 0 then return {} end

  -- Build command with all depot paths
  local cmd = 'p4 -ztag where'
  for _, depot_path in ipairs(depot_paths) do
    cmd = cmd .. ' ' .. url_encode(vim.fn.shellescape(depot_path))
  end

  local ok, result = pcall(vim.fn.systemlist, cmd)
  if not ok or vim.v.shell_error ~= 0 then return {} end

  -- Parse the tagged output
  local mapping = {}
  local current_depot, current_path
  for _, line in ipairs(result) do
    line = url_decode(line)
    local depot = line:match('^%.%.%. depotFile%s+(.+)$')
    if depot then
      current_depot = depot
      current_path = nil
    else
      local path = line:match('^%.%.%. path%s+(.+)$')
      if path and current_depot then
        current_path = path
        mapping[current_depot] = current_path
      end
    end
  end

  return mapping
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
    { prompt = 'Revert ' .. file .. '? (y/N): ' },
    function(input)
      if not (input and input:lower() == 'y') then return end
      local result = p4_cmd({cmd = 'revert ', filepath = file})
      if result then
        vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
        vim.cmd('edit')
        if State and State.window and State.window.win and vim.api.nvim_win_is_valid(State.window.win) then
          update_display(true)
        end
      end
    end)
end

local function p4_delete()
  local file = vim.fn.expand('%:p')
  vim.ui.input(
    { prompt = 'Delete ' .. file .. '? (y/N): ' },
    function(input)
      if not (input and input:lower() == 'y') then return end
      local result = p4_cmd({cmd = 'delete ', filepath = file})
      if result then
        vim.cmd('bd!')
        vim.notify('P4: File marked for delete', vim.log.levels.INFO)
        if State and State.window and State.window.win and vim.api.nvim_win_is_valid(State.window.win) then
          update_display(true)
        end
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
    -- Reset cursor and scroll binding options
    if vim.api.nvim_win_is_valid(left_win) then
      pcall(function()
        vim.wo[left_win].scrollbind = false
        vim.wo[left_win].cursorbind = false
      end)
    end
    if vim.api.nvim_win_is_valid(local_win) then
      pcall(function()
        vim.wo[local_win].scrollbind = false
        vim.wo[local_win].cursorbind = false
      end)
    end
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

-- DATA FETCHING -------------------------------------------------------------

function get_client_info()
  local client_info = p4_cmd({cmd = 'info'})
  local client_name, client_root
  for _, line in ipairs(client_info) do
    if not client_name then
      client_name = line:match('^Client name:%s+(.+)$')
    end
    if not client_root then
      client_root = line:match('^Client root:%s+(.+)$')
    end
    if client_name and client_root then break end
  end

  return {
    name = client_name or '',
    root = client_root or '',
  }
end

local function get_changelist_extended_info(cl)
  -- Nothing to do for default changelist
  if cl == 'default' then
    return {
      description = 'Default changelist',
      jobs = {},
    }
  end

  local describe_output = p4_cmd({cmd = 'describe ' .. cl})
  if not describe_output then
    error('Failed to get changelist info for CL ' .. cl)
  end

  local description_lines = {}
  local jobs = {}
  local in_jobs = false

  -- Parse describe output
  for _, line in ipairs(describe_output) do
    -- Detect start of jobs section
    if line:match('^Jobs fixed') then
      in_jobs = true
    -- Detect end of jobs section (start of affected files)
    elseif line:match('^Affected files') then
      in_jobs = false
      break
    elseif in_jobs then
      -- Parse job lines: they DON'T start with "..." (those are files)
      -- Job lines look like: "g3985598 on 2025/12/20 by ohaddad *open*"
      if not line:match('^%.%.%.') and not line:match('^%s*$') then
        if not line:match('^%s+') then
          -- This is a job ID line (not indented)
          local job_id = line:match('^(%S+)')
          if job_id then
            table.insert(jobs, {
              id = job_id,
              line = line
            })
          end
        elseif #jobs > 0 then
          -- Job description lines (indented)
          local last_job = jobs[#jobs]
          if not last_job.description then
            last_job.description = line:match('^%s+(.*)')
          end
        end
      end
    elseif not in_jobs then
      -- Collect all description lines (indented with tabs/spaces)
      if line:match('^%s+%S') then
        local desc_line = line:match('^%s+(.*)')
        if desc_line then
          table.insert(description_lines, desc_line)
        end
      end
    end
  end

  return {
    description_lines = #description_lines > 0 and description_lines or {'(no description)'},
    jobs = jobs,
  }
end

function get_all_changelists()
  local file_map = {}
  local cl_numbers = {}

  -- Get all pending changelists for the current client
  local changes_output = p4_cmd({cmd = 'changes -s pending -c ' .. vim.fn.shellescape(State.client.name)})
  for _, line in ipairs(changes_output) do
    local change_number = line:match('^Change (%d+)')
    if change_number then
      table.insert(cl_numbers, change_number)
      file_map[change_number] = {
        description_lines = {},
        jobs = {},
        shelved_files = {},
        opened_files = {},
        expand_shelf = false,
      }
    end
  end

  -- Batch describe all changelists in one call to get descriptions, jobs, and shelves
  if #cl_numbers > 0 then
    local describe_cmd = 'describe -s -S ' .. table.concat(cl_numbers, ' ')
    local describe_output = p4_cmd({cmd = describe_cmd})

    local current_cl
    local in_description = false
    local in_jobs = false
    local in_shelved = false

    for _, line in ipairs(describe_output) do
      -- Detect changelist boundary
      local cl = line:match('^Change (%d+)')
      if cl then
        current_cl = cl
        in_description = true
        in_jobs = false
        in_shelved = false
      -- Detect jobs section
      elseif line:match('^Jobs fixed') then
        in_description = false
        in_jobs = true
        in_shelved = false
      -- Detect shelved files section
      elseif line:match('^Shelved files') then
        in_description = false
        in_jobs = false
        in_shelved = true
      -- Detect affected files section (end of useful data for this CL)
      elseif line:match('^Affected files') then
        in_description = false
        in_jobs = false
        in_shelved = false
      -- Parse content based on current section
      elseif current_cl and file_map[current_cl] then
        if in_description and line:match('^%s+%S') then
          local desc_line = line:match('^%s+(.*)')
          if desc_line then
            table.insert(file_map[current_cl].description_lines, desc_line)
          end
        elseif in_jobs then
          if not line:match('^%.%.%.') and not line:match('^%s*$') then
            if not line:match('^%s+') then
              -- Job ID line
              local job_id = line:match('^(%S+)')
              if job_id then
                table.insert(file_map[current_cl].jobs, {
                  id = job_id,
                  line = line
                })
              end
            elseif #file_map[current_cl].jobs > 0 then
              -- Job description line
              local last_job = file_map[current_cl].jobs[#file_map[current_cl].jobs]
              if not last_job.description then
                last_job.description = line:match('^%s+(.*)')
              end
            end
          end
        elseif in_shelved then
          local depot_path = line:match('^%.%.%. (//[^#]+)')
          if depot_path then
            table.insert(file_map[current_cl].shelved_files, depot_path)
          end
        end
      end
    end

    -- Set default description for changelists without one
    for _, cn in ipairs(cl_numbers) do
      if #file_map[cn].description_lines == 0 then
        file_map[cn].description_lines = {'(no description)'}
      end
    end
  end

  -- Ensure default changelist is included
  if not file_map['default'] then
    file_map['default'] = {
      description_lines = {'Default changelist'},
      jobs = {},
      shelved_files = {},
      opened_files = {}
    }
  end
  -- Search for all opened files and group by changelist
  local files_output = p4_cmd({cmd = 'opened'})
  local depot_paths = {}
  local files_data = {}

  -- First pass: collect depot paths and basic file info
  for _, line in ipairs(files_output) do
    local depot_path = line:match('^(//[^#]+)')
    if depot_path then
      local action = line:match('#%d+ %- ([^%s]+)')
      local change_number = line:match('change (%d+)') or 'default'
      table.insert(depot_paths, depot_path)
      table.insert(files_data, {
        depot_path = depot_path,
        action = action,
        change_number = change_number,
      })
    end
  end

  -- Batch resolve all depot paths to local paths in one p4 call
  local path_mapping = batch_depot_to_local(depot_paths)

  -- Second pass: add files with resolved local paths to changelists
  for _, file_data in ipairs(files_data) do
    local local_path = path_mapping[file_data.depot_path] or ''
    table.insert(file_map[file_data.change_number].opened_files, {
      depot_path = file_data.depot_path,
      action = file_data.action,
      local_path = local_path,
    })
  end

  -- Return the complete changelist file map
  return file_map
end

-- DISPLAY RENDERING ------------------------------------------------------------

function build_display_lines()
  if not State then
    error('State is not initialized when building display')
  end

  local lines = {}
  local index_map = {}
  for cn, content in pairs(State.changelists) do
    -- CL header line
    table.insert(lines, string.format('CL %s :', cn))
    table.insert(index_map, { type = 'changelist', change_number = cn })

    -- All description lines indented
    for _, desc_line in ipairs(content.description_lines) do
      table.insert(lines, string.format('  %s', desc_line))
      table.insert(index_map, { type = 'description_line', change_number = cn })
    end

    -- Jobs section (if available)
    if content.jobs and #content.jobs > 0 then
      table.insert(lines, '')
      table.insert(index_map, { type = 'separator' })
      table.insert(lines, '  Jobs')
      table.insert(index_map, { type = 'jobs_header', change_number = cn })
      for _, job in ipairs(content.jobs) do
        table.insert(lines, string.format('    (%s) %s', job.id, job.description or job.line))
        table.insert(index_map, { type = 'job_line', change_number = cn, job_id = job.id })
      end
    end

    -- Files section
    local file_count = #content.opened_files
    if file_count > 0 then
      table.insert(lines, '')
      table.insert(index_map, { type = 'separator' })
      local count_str = string.format(' (%d file%s)', file_count, file_count ~= 1 and 's' or '')
      table.insert(lines, string.format('  Files%s', count_str))
      table.insert(index_map, { type = 'files_header', change_number = cn })
      for _, file in ipairs(content.opened_files) do
        local path_for_display
        if file.local_path ~= '' then
          -- Make path relative to client root
          local root = State.client.root
          if root ~= '' and file.local_path:sub(1, #root) == root then
            path_for_display = file.local_path:sub(#root + 2) -- +2 to skip root and trailing slash
          else
            path_for_display = file.local_path
          end
        else
          path_for_display = file.depot_path
        end
        table.insert(lines, string.format('    %-13s %s', file.action, path_for_display))
        table.insert(index_map, { type = 'opened_file', change_number = cn, opened_file = file })
      end
    end

    -- Shelf toggle line
    local shelf_size = #content.shelved_files
    if shelf_size > 0 then
      table.insert(lines, '')  -- Empty line before shelf
      table.insert(index_map, { type = 'separator' })  -- Corresponding index_map entry
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
    -- Empty line separator
    table.insert(lines, '')
    table.insert(index_map, { type = 'separator' })
  end

  -- Help line
  table.insert(lines, '[Enter=open/edit/toggle | d=diff | r=revert | m=move | s=shelve | u=unshelve | D=delete | N=new CL | A=all]')

  return lines, index_map
end

function apply_syntax_highlighting(buf)
  -- Clear existing highlights
  vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

  local ns_id = vim.api.nvim_create_namespace('P4Highlight')
  local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

  for i, line in ipairs(lines) do
    local line_idx = i - 1

    -- CL header lines
    if line:match('^CL ') then
      -- Highlight entire CL header line
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, #line)

    -- Description lines (indented with 2 spaces)
    elseif line:match('^  [^%s]') and not line:match('^  Jobs') and not line:match('^  Files') and not line:match('^  [▶▼]') then
      -- Check for CR: or RB: patterns to apply special highlighting
      if line:match('CR:') then
        local cr_start = line:find('CR:')
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, cr_start - 1, cr_start + 2)
      elseif line:match('RB:') then
        local rb_start = line:find('RB:')
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, rb_start - 1, rb_start + 2)
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
      end

    -- Jobs header
    elseif line:match('^  Jobs$') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, #line)

    -- Job lines (indented with 4 spaces, starts with parenthesis)
    elseif line:match('^    %([^%)]+%)') then
      -- Highlight job ID in parentheses
      local paren_start = line:find('%(') - 1
      local paren_end = line:find('%)')
      if paren_start and paren_end then
        vim.api.nvim_buf_add_highlight(buf, ns_id, 'Number', line_idx, paren_start, paren_end)
      end

    -- Files header
    elseif line:match('^  Files') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, 7)
      -- Highlight count
      local count_match = line:match('%((%d+ file[s]?)%)')
      if count_match then
        local count_start = line:find('%(')
        local count_end = line:find('%)')
        if count_start and count_end then
          vim.api.nvim_buf_add_highlight(buf, ns_id, 'Number', line_idx, count_start - 1, count_end)
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

    -- File action lines (indented with 4 spaces)
    elseif line:match('^    [a-z]+%s+') then
      local action = line:match('^    ([a-z/]+)')
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

        vim.api.nvim_buf_add_highlight(buf, ns_id, hl_group, line_idx, 4, 4 + #action)

        -- Highlight the filename
        local file_start = line:find('[^%s]', 18)
        if file_start then
          vim.api.nvim_buf_add_highlight(buf, ns_id, 'String', line_idx, file_start - 1, #line)
        end
      end

    -- Shelved file lines (indented with 4 spaces, depot paths)
    elseif line:match('^    //') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Directory', line_idx, 0, #line)

    -- Help line
    elseif line:match('^%[.*%]$') then
      vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
    end
  end
end

function update_display(refresh_data)
  if not (State and State.window.win and vim.api.nvim_win_is_valid(State.window.win)) then
    return
  end
  if refresh_data then
    State.changelists = get_all_changelists()
  end

  local win = State.window.win
  local buf = vim.api.nvim_win_get_buf(win)
  local view = BufferViews[buf]

  local lines, index_map = build_display_lines()
  State.window.index_map = index_map

  set_buffer_lines(buf, lines)

  if view then
    local max_line = math.max(1, #lines)
    if view.lnum and view.lnum > max_line then view.lnum = max_line end
    vim.api.nvim_win_call(win, function()
      pcall(vim.fn.winrestview, view)
    end)
  end
end

-- WINDOW KEYBIND ACTIONS -------------------------------------------------------

-- Auto-refresh when the Perforce buffer is shown in a window
vim.api.nvim_create_autocmd('BufWinEnter', {
  callback = function(args)
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ':t')
    if name == BUFFER_NAME then
      render_into(vim.api.nvim_get_current_win(), args.buf)
    end
  end,
})

-- Save view when leaving Perforce buffer, to restore on next attach
vim.api.nvim_create_autocmd('BufWinLeave', {
  callback = function(args)
    local name = vim.fn.fnamemodify(vim.api.nvim_buf_get_name(args.buf), ':t')
    if name == BUFFER_NAME then
      local win = vim.api.nvim_get_current_win()
      local view
      pcall(function()
        view = vim.fn.winsaveview()
      end)
      if view then BufferViews[args.buf] = view end
    end
  end,
})

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
    local filepath = depot_to_local(data.opened_file.depot_path)
    if filepath ~= '' then
      vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
      State = nil
    else
      vim.notify('P4: Failed to resolve local path for ' .. data.opened_file.depot_path, vim.log.levels.ERROR)
    end

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
    local name_for_prompt = (file.local_path ~= '' and file.local_path or file.depot_path)
    vim.ui.input(
      { prompt = 'Revert ' .. name_for_prompt .. '? (y/N): ' },
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
        table.insert(cl_options, string.format('%s: %s', cn, content.description_lines[1]))
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
    local filepath = depot_to_local(data.opened_file.depot_path)
    if filepath ~= '' then
      vim.cmd('edit ' .. vim.fn.fnameescape(filepath))
      State = nil
      vim.schedule(function() p4_vdiffsplit(filepath) end)
    else
      vim.notify('P4: Failed to resolve local path for ' .. data.opened_file.depot_path, vim.log.levels.ERROR)
    end
  end
end

-- MAIN WINDOW CREATION FUNCTION -------------------------------------------------------

local function show_window()
  -- Initialize state
  State = get_initial_state()
  State.client = get_client_info()
  State.changelists = get_all_changelists()

  -- Build lines and index map
  local lines, index_map = build_display_lines()

  -- Ensure/reuse named buffer and use current window
  local win = vim.api.nvim_get_current_win()
  local buf = ensure_buffer()
  State.window = { win = win, buf = buf, index_map = index_map }
  vim.api.nvim_win_set_buf(win, buf)
  vim.api.nvim_buf_set_option(buf, 'modifiable', true)
  vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
  apply_syntax_highlighting(buf)
  vim.api.nvim_buf_set_option(buf, 'modifiable', false)

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

-- Keymaps
vim.keymap.set('n', '<leader>ps', show_window, { desc = 'P4: Show opened files' })
vim.keymap.set('n', '<leader>pe', p4_edit, { desc = 'P4: Edit current file' })
vim.keymap.set('n', '<leader>pa', p4_add, { desc = 'P4: Add current file' })
vim.keymap.set('n', '<leader>pr', p4_revert, { desc = 'P4: Revert current file' })
vim.keymap.set('n', '<leader>pD', p4_delete, { desc = 'P4: Delete current file' })
vim.keymap.set('n', '<leader>pR', p4_rename, { desc = 'P4: Rename/move current file' })
vim.keymap.set('n', '<leader>pd', function() p4_vdiffsplit(vim.fn.expand('%:p')) end, { desc = 'P4: Diff current file' })
