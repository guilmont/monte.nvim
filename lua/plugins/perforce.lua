
return {
  dir = vim.fn.stdpath('config') .. '/lua/plugins',
  name = 'perforce',
  lazy = false,
  priority = 100,
  config = function()
    local M = {}

    -- ============================================================================
    -- STATE MANAGEMENT
    -- ============================================================================

    local State = {
      shelf_expanded = {},  -- Track which CLs have expanded shelves
      -- P4 data (persistent)
      files = {},          -- Current opened files cache
      grouped = {},        -- Files grouped by CL
      sorted_cls = {},     -- Sorted changelist numbers
      -- Window state (transient)
      window = {
        buf = nil,
        win = nil,
        maps = {             -- Line number to object mappings
          file = {},
          cl = {},
          shelf_toggle = {},
          shelf_file = {},
        }
      }
    }

    -- ============================================================================
    -- PERFORCE COMMAND WRAPPER
    -- ============================================================================

    local function p4_cmd(args)
      local result = vim.fn.systemlist('p4 ' .. args)
      if vim.v.shell_error ~= 0 then
        vim.notify('P4 error: ' .. table.concat(result, '\n'), vim.log.levels.ERROR)
        return nil
      end
      return result
    end

    -- ============================================================================
    -- DATA FETCHING
    -- ============================================================================

    local function get_client_name()
      local client_info = p4_cmd('client -o')
      if not client_info then return nil end

      for _, line in ipairs(client_info) do
        local name = line:match('^Client:%s+(.+)$')
        if name then return name end
      end
      return nil
    end

    local function get_opened_files()
      local result = p4_cmd('opened')
      if not result then return {} end

      local files = {}
      for _, line in ipairs(result) do
        local depot_path = line:match('^(//[^#]+)')
        if depot_path then
          local where = p4_cmd('where ' .. vim.fn.shellescape(depot_path))
          if where and #where > 0 then
            local local_path = where[1]:match(' ([^ ]+)$')
            if local_path then
              table.insert(files, { line = line, local_path = local_path })
            end
          end
        end
      end
      return files
    end

    local function get_all_pending_cls(client_name)
      if not client_name then return {} end

      local result = p4_cmd('changes -s pending -c ' .. vim.fn.shellescape(client_name))
      if not result then return {} end

      local cls = {}
      for _, line in ipairs(result) do
        local cl_num = line:match('Change (%d+)')
        if cl_num then cls[cl_num] = true end
      end
      return cls
    end

    local function get_cl_description(cl)
      local change_info = p4_cmd('change -o ' .. cl)
      if not change_info then return 'No description' end

      local desc = ''
      local in_desc = false
      for _, line in ipairs(change_info) do
        if line:match('^Description:') then
          in_desc = true
        elseif in_desc then
          if line:match('^%s+') then
            local content = line:match('^%s+(.*)')
            if content ~= '' then
              desc = desc .. (desc ~= '' and ' ' or '') .. content
            end
          else
            break
          end
        end
      end
      return desc ~= '' and desc or 'No description'
    end

    local function get_shelved_files(cl)
      if cl == 'default' then return nil end

      local shelved_output = p4_cmd('describe -S ' .. cl)
      if not shelved_output then return nil end

      local shelved_files = {}
      local in_shelved = false
      for _, line in ipairs(shelved_output) do
        if line:match('^Shelved files') then
          in_shelved = true
        elseif in_shelved then
          local depot_path = line:match('^%.%.%. (//[^#]+)')
          if depot_path then
            table.insert(shelved_files, depot_path)
          elseif line:match('^Differences') or line:match('^====') then
            break
          end
        end
      end
      return #shelved_files > 0 and shelved_files or nil
    end

    -- ============================================================================
    -- DATA ORGANIZATION
    -- ============================================================================

    local function build_grouped_data(files, all_cls)
      local grouped = {}

      -- Group files by changelist
      for _, f in ipairs(files) do
        local cl = f.line:match('change (%d+)') or 'default'
        if not grouped[cl] then
          grouped[cl] = {
            desc = cl == 'default' and 'Default changelist' or get_cl_description(cl),
            files = {},
            shelved = get_shelved_files(cl) or {}
          }
        end
        table.insert(grouped[cl].files, f)
      end

      -- Add empty changelists
      for cl, _ in pairs(all_cls) do
        if not grouped[cl] then
          grouped[cl] = {
            desc = get_cl_description(cl),
            files = {},
            shelved = get_shelved_files(cl) or {}
          }
        end
      end

      -- Always include default
      if not grouped['default'] then
        grouped['default'] = { desc = 'Default changelist', files = {}, shelved = {} }
      end

      return grouped
    end

    local function get_sorted_cls(grouped)
      local cls = {}
      for cl, _ in pairs(grouped) do
        table.insert(cls, cl)
      end
      table.sort(cls, function(a, b)
        if a == 'default' then return false end
        if b == 'default' then return true end
        return tonumber(a) < tonumber(b)
      end)
      return cls
    end

    -- ============================================================================
    -- DISPLAY RENDERING
    -- ============================================================================

    local function build_display_lines()
      local lines = {}
      local maps = { file = {}, cl = {}, shelf_toggle = {}, shelf_file = {} }
      local idx = 1

      for _, cl in ipairs(State.sorted_cls) do
        local data = State.grouped[cl]
        if data then
          -- CL header line
          local file_count = #data.files
          local count_str = file_count > 0
            and string.format(' (%d file%s)', file_count, file_count ~= 1 and 's' or '')
            or ' (empty)'

          table.insert(lines, string.format('CL %s: %s%s', cl, data.desc, count_str))
          maps.cl[idx] = { cl = cl, desc = data.desc }
          idx = idx + 1

          -- Shelf toggle line
          if #data.shelved > 0 then
            local expand_char = State.shelf_expanded[cl] and '▼' or '▶'
            local shelf_count = #data.shelved
            table.insert(lines, string.format('  %s Shelf (%d file%s)',
              expand_char, shelf_count, shelf_count ~= 1 and 's' or ''))
            maps.shelf_toggle[idx] = { cl = cl, shelved = data.shelved }
            idx = idx + 1

            -- Shelved files (if expanded)
            if State.shelf_expanded[cl] then
              for _, depot_path in ipairs(data.shelved) do
                local filename = depot_path:match('([^/]+)$')
                table.insert(lines, string.format('    %s', filename))
                maps.shelf_file[idx] = { cl = cl, depot_path = depot_path }
                idx = idx + 1
              end
            end
          end

          -- Opened files
          for _, f in ipairs(data.files) do
            local action = f.line:match('#%d+ %- ([^%s]+)')
            local fullpath = vim.fn.fnamemodify(f.local_path, ':~:.')
            table.insert(lines, string.format('  %-8s %s', action, fullpath))
            maps.file[idx] = f
            idx = idx + 1
          end

          -- Empty line separator
          table.insert(lines, '')
          idx = idx + 1
        end
      end

      -- Help line
      table.insert(lines, '[Enter=diff | Tab=toggle shelf | e=edit | r=revert | s=shelve | u=unshelve | d=delete | m=move | N=new CL | q=close]')

      return lines, maps
    end

    local function update_display()
      if not vim.api.nvim_buf_is_valid(State.window.buf) or not vim.api.nvim_win_is_valid(State.window.win) then
        return
      end

      local cursor_line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local lines, maps = build_display_lines()

      vim.bo[State.window.buf].modifiable = true
      vim.api.nvim_buf_set_lines(State.window.buf, 0, -1, false, lines)
      vim.bo[State.window.buf].modifiable = false

      State.window.maps = maps

      -- Restore cursor (clamped to valid range)
      local line_count = #lines
      if cursor_line > line_count then cursor_line = line_count end
      pcall(vim.api.nvim_win_set_cursor, State.window.win, {cursor_line, 0})
    end

    local function refresh_data_and_display()
      -- Check if window is still valid before refreshing
      if not State.window.buf or not State.window.win then
        return
      end

      if not vim.api.nvim_buf_is_valid(State.window.buf) or not vim.api.nvim_win_is_valid(State.window.win) then
        return
      end

      -- Refresh all data
      local client_name = get_client_name()
      State.files = get_opened_files()
      local all_cls = get_all_pending_cls(client_name)
      State.grouped = build_grouped_data(State.files, all_cls)
      State.sorted_cls = get_sorted_cls(State.grouped)

      -- Update display
      update_display()
    end

    -- ============================================================================
    -- PERFORCE OPERATIONS
    -- ============================================================================

    local function create_changelist_with_desc(desc)
      local change_spec = p4_cmd('change -o')
      if not change_spec then return nil end

      local spec_lines = {}
      local in_desc, in_files = false, false

      for _, line in ipairs(change_spec) do
        if line:match('^Description:') then
          table.insert(spec_lines, line)
          table.insert(spec_lines, '\t' .. desc)
          in_desc = true
        elseif line:match('^Files:') then
          in_files, in_desc = true, false
        elseif in_desc or in_files then
          -- Skip
        else
          table.insert(spec_lines, line)
        end
      end

      local spec_file = vim.fn.tempname()
      local sf = io.open(spec_file, 'w')
      if not sf then return nil end

      sf:write(table.concat(spec_lines, '\n'))
      sf:close()

      local result = vim.fn.system('p4 change -i < ' .. spec_file)
      os.remove(spec_file)

      if vim.v.shell_error == 0 then
        local new_cl = result:match('Change (%d+) created')
        return new_cl
      end
      return nil
    end

    local function update_cl_description(cl, new_desc)
      local change_spec = p4_cmd('change -o ' .. cl)
      if not change_spec then return false end

      local spec_lines = {}
      local in_desc = false

      for _, line in ipairs(change_spec) do
        if line:match('^Description:') then
          table.insert(spec_lines, line)
          table.insert(spec_lines, '\t' .. new_desc)
          in_desc = true
        elseif in_desc and not line:match('^%s+') then
          table.insert(spec_lines, line)
          in_desc = false
        elseif not in_desc then
          table.insert(spec_lines, line)
        end
      end

      local spec_file = vim.fn.tempname()
      local sf = io.open(spec_file, 'w')
      if not sf then return false end

      sf:write(table.concat(spec_lines, '\n'))
      sf:close()

      vim.fn.system('p4 change -i < ' .. spec_file)
      os.remove(spec_file)

      return vim.v.shell_error == 0
    end

    local function reload_open_buffers()
      vim.schedule(function()
        vim.cmd('checktime')
        for _, bufnr in ipairs(vim.api.nvim_list_bufs()) do
          if vim.api.nvim_buf_is_loaded(bufnr) then
            vim.api.nvim_buf_call(bufnr, function()
              vim.cmd('silent! edit')
            end)
          end
        end
      end)
    end

    -- ============================================================================
    -- WINDOW KEYBIND ACTIONS
    -- ============================================================================

    local Actions = {}

    function Actions.show_diff()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local file = State.window.maps.file[line]
      if file then
        M.show_diff(file.local_path)
      end
    end

    function Actions.toggle_shelf()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local shelf_toggle = State.window.maps.shelf_toggle[line]
      if shelf_toggle then
        State.shelf_expanded[shelf_toggle.cl] = not State.shelf_expanded[shelf_toggle.cl]
        update_display()
      end
    end

    function Actions.edit()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local cl_info = State.window.maps.cl[line]
      local file = State.window.maps.file[line]

      if cl_info then
        -- Edit CL description via input
        local current_desc = cl_info.desc
        vim.ui.input({
          prompt = 'Edit CL ' .. cl_info.cl .. ' description: ',
          default = current_desc
        }, function(new_desc)
          if not new_desc or new_desc == '' or new_desc == current_desc then
            return
          end

          if cl_info.cl == 'default' then
            -- Create new CL and move all default files to it
            local new_cl = create_changelist_with_desc(new_desc)
            if new_cl then
              local moved_count = 0
              for _, f in ipairs(State.files) do
                local file_cl = f.line:match('change (%d+)')
                if not file_cl then  -- File is in default CL
                  p4_cmd('reopen -c ' .. new_cl .. ' ' .. vim.fn.shellescape(f.local_path))
                  moved_count = moved_count + 1
                end
              end
              if moved_count > 0 then
                vim.notify(string.format('Created CL %s and moved %d file(s)', new_cl, moved_count), vim.log.levels.INFO)
              else
                vim.notify('Created CL ' .. new_cl, vim.log.levels.INFO)
              end
              vim.schedule(function()
                refresh_data_and_display()
              end)
            end
          else
            -- Update existing CL description
            if update_cl_description(cl_info.cl, new_desc) then
              vim.notify('Updated CL ' .. cl_info.cl, vim.log.levels.INFO)
              State.grouped[cl_info.cl].desc = new_desc
              vim.schedule(function()
                update_display()
              end)
            end
          end
        end)
      elseif file then
        -- Open file in editor
        vim.api.nvim_win_close(State.window.win, true)
        vim.cmd('edit ' .. vim.fn.fnameescape(file.local_path))
      end
    end

    function Actions.revert()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local file = State.window.maps.file[line]
      local cl_info = State.window.maps.cl[line]

      if file then
        -- Revert single file
        local filename = vim.fn.fnamemodify(file.local_path, ':t')
        vim.ui.input({ prompt = 'Revert ' .. filename .. '? (y/N): ' }, function(input)
          if input and input:lower() == 'y' then
            p4_cmd('revert ' .. vim.fn.shellescape(file.local_path))
            vim.notify('Reverted ' .. filename, vim.log.levels.INFO)
            reload_open_buffers()
            vim.schedule(function()
              refresh_data_and_display()
            end)
          end
        end)
      elseif cl_info then
        -- Revert all files in CL
        local current_files = get_opened_files()
        local files_to_revert = {}
        for _, f in ipairs(current_files) do
          local file_cl = f.line:match('change (%d+)')
          if (cl_info.cl == 'default' and not file_cl) or (file_cl == cl_info.cl) then
            table.insert(files_to_revert, f)
          end
        end

        if #files_to_revert > 0 then
          vim.ui.input({
            prompt = string.format('Revert all %d file(s) in CL %s? (y/N): ', #files_to_revert, cl_info.cl)
          }, function(input)
            if input and input:lower() == 'y' then
              for _, f in ipairs(files_to_revert) do
                p4_cmd('revert ' .. vim.fn.shellescape(f.local_path))
              end
              vim.notify(string.format('Reverted %d file(s) from CL %s', #files_to_revert, cl_info.cl), vim.log.levels.INFO)
              reload_open_buffers()
              vim.schedule(function()
                refresh_data_and_display()
              end)
            end
          end)
        else
          vim.notify('No files to revert in CL ' .. cl_info.cl, vim.log.levels.WARN)
        end
      end
    end

    function Actions.shelve()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local file = State.window.maps.file[line]
      local cl_info = State.window.maps.cl[line]

      if cl_info then
        -- Shelve all files in CL
        if cl_info.cl == 'default' then
          vim.notify('Cannot shelve to default changelist', vim.log.levels.WARN)
          return
        end

        local file_count = #State.grouped[cl_info.cl].files
        if file_count == 0 then
          vim.notify('No files to shelve in CL ' .. cl_info.cl, vim.log.levels.WARN)
          return
        end

        p4_cmd('shelve -c ' .. cl_info.cl)
        vim.notify(string.format('Shelved %d file(s) to CL %s', file_count, cl_info.cl), vim.log.levels.INFO)
        refresh_data_and_display()
      elseif file then
        -- Shelve single file
        local current_cl = file.line:match('change (%d+)') or 'default'
        if current_cl == 'default' then
          vim.notify('Cannot shelve files in default changelist', vim.log.levels.WARN)
          return
        end
        local filename = vim.fn.fnamemodify(file.local_path, ':t')
        p4_cmd('shelve -c ' .. current_cl .. ' ' .. vim.fn.shellescape(file.local_path))
        vim.notify(string.format('Shelved %s to CL %s', filename, current_cl), vim.log.levels.INFO)
        refresh_data_and_display()
      end
    end

    function Actions.unshelve()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local cl_info = State.window.maps.cl[line]
      local shelf_toggle = State.window.maps.shelf_toggle[line]
      local shelf_file = State.window.maps.shelf_file[line]

      local function do_unshelve(cl, depot_path, msg)
        local cmd = 'unshelve -s ' .. cl .. ' -c ' .. cl
        if depot_path then
          cmd = cmd .. ' ' .. vim.fn.shellescape(depot_path)
        end
        p4_cmd(cmd)
        vim.notify(msg, vim.log.levels.INFO)
        reload_open_buffers()
        vim.schedule(function()
          refresh_data_and_display()
        end)
      end

      if cl_info then
        if cl_info.cl == 'default' then
          vim.notify('Default changelist has no shelf', vim.log.levels.WARN)
          return
        end
        local has_shelf = State.grouped[cl_info.cl] and #State.grouped[cl_info.cl].shelved > 0
        if not has_shelf then
          vim.notify('No shelved files in CL ' .. cl_info.cl, vim.log.levels.WARN)
          return
        end
        do_unshelve(cl_info.cl, nil, 'Unshelved all files to CL ' .. cl_info.cl)
      elseif shelf_toggle then
        do_unshelve(shelf_toggle.cl, nil, 'Unshelved all files to CL ' .. shelf_toggle.cl)
      elseif shelf_file then
        local filename = shelf_file.depot_path:match('([^/]+)$')
        do_unshelve(shelf_file.cl, shelf_file.depot_path, 'Unshelved ' .. filename .. ' to CL ' .. shelf_file.cl)
      end
    end

    function Actions.delete()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local cl_info = State.window.maps.cl[line]
      local shelf_toggle = State.window.maps.shelf_toggle[line]
      local shelf_file = State.window.maps.shelf_file[line]

      if cl_info then
        -- Delete entire changelist
        if cl_info.cl == 'default' then
          vim.notify('Cannot delete default changelist', vim.log.levels.WARN)
          return
        end

        local current_files = get_opened_files()
        local files_to_revert = {}
        for _, f in ipairs(current_files) do
          local file_cl = f.line:match('change (%d+)')
          if file_cl == cl_info.cl then
            table.insert(files_to_revert, f)
          end
        end

        local has_shelf = State.grouped[cl_info.cl] and #State.grouped[cl_info.cl].shelved > 0
        local msg = string.format('Delete CL %s?', cl_info.cl)
        if #files_to_revert > 0 then
          msg = msg .. string.format(' (%d file(s) will be reverted', #files_to_revert)
          msg = msg .. (has_shelf and ', shelf will be deleted)' or ')')
        elseif has_shelf then
          msg = msg .. ' (shelf will be deleted)'
        end
        msg = msg .. ' (y/N): '

        vim.ui.input({ prompt = msg }, function(input)
          if input and input:lower() == 'y' then
            -- Revert files
            for _, f in ipairs(files_to_revert) do
              p4_cmd('revert ' .. vim.fn.shellescape(f.local_path))
            end

            -- Delete shelf
            if has_shelf then
              p4_cmd('shelve -d -c ' .. cl_info.cl)
            end

            -- Delete changelist
            p4_cmd('change -d ' .. cl_info.cl)

            vim.notify('Deleted CL ' .. cl_info.cl, vim.log.levels.INFO)

            -- Reload buffers if files were reverted
            if #files_to_revert > 0 then
              reload_open_buffers()
            end

            vim.schedule(function()
              refresh_data_and_display()
            end)
          end
        end)
      elseif shelf_toggle then
        -- Delete entire shelf
        p4_cmd('shelve -d -c ' .. shelf_toggle.cl)
        vim.notify('Deleted shelf for CL ' .. shelf_toggle.cl, vim.log.levels.INFO)
        refresh_data_and_display()
      elseif shelf_file then
        -- Delete single shelved file
        p4_cmd('shelve -d -c ' .. shelf_file.cl .. ' ' .. vim.fn.shellescape(shelf_file.depot_path))
        vim.notify('Deleted shelved file ' .. shelf_file.depot_path:match('([^/]+)$'), vim.log.levels.INFO)
        refresh_data_and_display()
      end
    end

    function Actions.move()
      local line = vim.api.nvim_win_get_cursor(State.window.win)[1]
      local file = State.window.maps.file[line]

      if file then
        local current_cl = file.line:match('change (%d+)') or 'default'
        local cl_options = {}
        for _, cl in ipairs(State.sorted_cls) do
          local desc = State.grouped[cl].desc
          table.insert(cl_options, string.format('%s: %s', cl, desc))
        end

        vim.ui.select(cl_options, {
          prompt = 'Move file to changelist:',
          format_item = function(item) return item end,
        }, function(choice)
          if not choice then return end
          local target_cl = choice:match('^([^:]+)')
          if target_cl and target_cl ~= current_cl then
            local cmd = target_cl == 'default' and 'reopen -c default ' or 'reopen -c ' .. target_cl .. ' '
            p4_cmd(cmd .. vim.fn.shellescape(file.local_path))
            local filename = vim.fn.fnamemodify(file.local_path, ':t')
            vim.notify(string.format('Moved %s to CL %s', filename, target_cl), vim.log.levels.INFO)
            vim.schedule(function()
              refresh_data_and_display()
            end)
          end
        end)
      end
    end

    function Actions.move_visual()
      -- Get selected files
      local start_line = vim.fn.line('v')
      local end_line = vim.fn.line('.')
      if start_line > end_line then start_line, end_line = end_line, start_line end

      local selected_files = {}
      for line = start_line, end_line do
        if State.window.maps.file[line] then
          table.insert(selected_files, State.window.maps.file[line])
        end
      end

      if #selected_files == 0 then return end

      local cl_options = {}
      for _, cl in ipairs(State.sorted_cls) do
        local desc = State.grouped[cl].desc
        table.insert(cl_options, string.format('%s: %s', cl, desc))
      end

      vim.ui.select(cl_options, {
        prompt = string.format('Move %d file%s to changelist:', #selected_files, #selected_files ~= 1 and 's' or ''),
        format_item = function(item) return item end,
      }, function(choice)
        if not choice then return end
        local target_cl = choice:match('^([^:]+)')
        if target_cl then
          local cmd = target_cl == 'default' and 'reopen -c default ' or 'reopen -c ' .. target_cl .. ' '
          for _, file in ipairs(selected_files) do
            p4_cmd(cmd .. vim.fn.shellescape(file.local_path))
          end
          vim.notify(string.format('Moved %d file%s to CL %s', #selected_files, #selected_files ~= 1 and 's' or '', target_cl), vim.log.levels.INFO)
          vim.schedule(function()
            refresh_data_and_display()
          end)
        end
      end)
    end

    function Actions.new_changelist()
      vim.ui.input({ prompt = 'New changelist description: ' }, function(desc)
        if not desc or desc == '' then return end
        local new_cl = create_changelist_with_desc(desc)
        if new_cl then
          vim.notify('Created CL ' .. new_cl, vim.log.levels.INFO)
          vim.schedule(function()
            refresh_data_and_display()
          end)
        end
      end)
    end

    -- ============================================================================
    -- MAIN WINDOW CREATION
    -- ============================================================================

    function M.show_opened()
      -- Close existing window if it's open
      if State.window.win and vim.api.nvim_win_is_valid(State.window.win) then
        vim.api.nvim_win_close(State.window.win, true)
      end

      -- Delete existing buffer if it exists
      if State.window.buf and vim.api.nvim_buf_is_valid(State.window.buf) then
        vim.api.nvim_buf_delete(State.window.buf, { force = true })
      end

      -- Initialize state
      local client_name = get_client_name()
      State.files = get_opened_files()
      local all_cls = get_all_pending_cls(client_name)
      State.grouped = build_grouped_data(State.files, all_cls)
      State.sorted_cls = get_sorted_cls(State.grouped)

      -- Create buffer
      local buf = vim.api.nvim_create_buf(false, true)
      vim.bo[buf].buftype = 'nofile'
      vim.bo[buf].bufhidden = 'wipe'
      vim.bo[buf].swapfile = false
      vim.api.nvim_buf_set_name(buf, 'P4 Opened Files')

      State.window.buf = buf

      -- Build and set initial content
      local lines, maps = build_display_lines()
      vim.api.nvim_buf_set_lines(buf, 0, -1, false, lines)
      vim.bo[buf].modifiable = false
      State.window.maps = maps

      -- Create window
      local width = math.floor(vim.o.columns * 0.9)
      local height = math.min(#lines + 2, math.floor(vim.o.lines * 0.9))
      local win = vim.api.nvim_open_win(buf, true, {
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

      State.window.win = win

      -- Cleanup when window/buffer is closed
      vim.api.nvim_create_autocmd({'WinClosed', 'BufWipeout'}, {
        buffer = buf,
        once = true,
        callback = function()
          State.window.buf = nil
          State.window.win = nil
        end,
      })

      -- Keymaps
      local opts = { buffer = buf, noremap = true, silent = true }
      vim.keymap.set('n', '<CR>', Actions.show_diff, vim.tbl_extend('force', opts, { desc = 'Show diff' }))
      vim.keymap.set('n', '<Tab>', Actions.toggle_shelf, vim.tbl_extend('force', opts, { desc = 'Toggle shelf' }))
      vim.keymap.set('n', 'e', Actions.edit, vim.tbl_extend('force', opts, { desc = 'Edit CL/file' }))
      vim.keymap.set('n', 'r', Actions.revert, vim.tbl_extend('force', opts, { desc = 'Revert' }))
      vim.keymap.set('n', 's', Actions.shelve, vim.tbl_extend('force', opts, { desc = 'Shelve' }))
      vim.keymap.set('n', 'u', Actions.unshelve, vim.tbl_extend('force', opts, { desc = 'Unshelve' }))
      vim.keymap.set('n', 'd', Actions.delete, vim.tbl_extend('force', opts, { desc = 'Delete' }))
      vim.keymap.set('n', 'm', Actions.move, vim.tbl_extend('force', opts, { desc = 'Move file' }))
      vim.keymap.set('v', 'm', Actions.move_visual, vim.tbl_extend('force', opts, { desc = 'Move files' }))
      vim.keymap.set('n', 'N', Actions.new_changelist, vim.tbl_extend('force', opts, { desc = 'New CL' }))
      vim.keymap.set('n', 'q', function() vim.api.nvim_win_close(win, true) end, vim.tbl_extend('force', opts, { desc = 'Close' }))
    end

    -- ============================================================================
    -- SIMPLE FILE OPERATIONS (outside window)
    -- ============================================================================

    function M.edit()
      local file = vim.fn.expand('%:p')
      local result = p4_cmd('edit ' .. vim.fn.shellescape(file))
      if result then
        vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
        vim.bo.readonly = false
        vim.bo.modifiable = true
      end
    end

    function M.add()
      local file = vim.fn.expand('%:p')
      local result = p4_cmd('add ' .. vim.fn.shellescape(file))
      if result then
        vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
      end
    end

    function M.revert()
      local file = vim.fn.expand('%:p')
      vim.ui.input({ prompt = 'Revert ' .. vim.fn.expand('%') .. '? (y/N): ' }, function(input)
        if input and input:lower() == 'y' then
          local result = p4_cmd('revert ' .. vim.fn.shellescape(file))
          if result then
            vim.notify('P4: ' .. result[1], vim.log.levels.INFO)
            vim.cmd('checktime')
            vim.bo.readonly = true
            vim.bo.modifiable = false
          end
        end
      end)
    end

    function M.delete(file)
      file = file or vim.fn.expand('%:p')
      vim.ui.input({ prompt = 'Delete ' .. vim.fn.fnamemodify(file, ':t') .. '? (y/N): ' }, function(input)
        if input and input:lower() == 'y' then
          local result = p4_cmd('delete ' .. vim.fn.shellescape(file))
          if result then
            vim.notify('P4: File marked for delete', vim.log.levels.INFO)
            vim.bo.readonly = true
          end
        end
      end)
    end

    function M.move(old_path, new_path)
      old_path = old_path or vim.fn.expand('%:p')

      if not new_path then
        vim.ui.input({ prompt = 'Move/rename to: ', default = old_path }, function(input)
          if input and input ~= '' and input ~= old_path then
            local result = p4_cmd('move ' .. vim.fn.shellescape(old_path) .. ' ' .. vim.fn.shellescape(input))
            if result then
              vim.notify('P4: File moved/renamed', vim.log.levels.INFO)
              vim.cmd('edit ' .. vim.fn.fnameescape(input))
            end
          end
        end)
      else
        local result = p4_cmd('move ' .. vim.fn.shellescape(old_path) .. ' ' .. vim.fn.shellescape(new_path))
        if result then
          vim.notify('P4: File moved/renamed', vim.log.levels.INFO)
          vim.cmd('edit ' .. vim.fn.fnameescape(new_path))
        end
      end
    end

    function M.show_diff(file)
      file = file or vim.fn.expand('%:p')

      local diff_output = p4_cmd('diff ' .. vim.fn.shellescape(file))
      if not diff_output or #diff_output == 0 then
        vim.notify('No changes in ' .. vim.fn.fnamemodify(file, ':t'), vim.log.levels.INFO)
        return
      end

      local depot_content = p4_cmd('print -q ' .. vim.fn.shellescape(file))
      if not depot_content then
        vim.notify('Failed to get depot content', vim.log.levels.ERROR)
        return
      end

      local current_content = vim.fn.readfile(file)

      -- Detect filetype from the file extension
      local filetype = vim.filetype.match({ filename = file }) or ''

      -- Clean up any existing diff buffers with same names
      local filename = vim.fn.fnamemodify(file, ':t')
      local depot_name = 'P4 Depot: ' .. filename
      local local_name = 'Local: ' .. filename

      for _, buf in ipairs(vim.api.nvim_list_bufs()) do
        if vim.api.nvim_buf_is_valid(buf) then
          local buf_name = vim.api.nvim_buf_get_name(buf)
          -- Clean up old diff buffers and any buffer with the same file path
          if buf_name == depot_name or buf_name == local_name or buf_name == file then
            pcall(vim.api.nvim_buf_delete, buf, { force = true })
          end
        end
      end

      local left_buf = vim.api.nvim_create_buf(false, true)
      local right_buf = vim.api.nvim_create_buf(false, true)

      vim.api.nvim_buf_set_lines(left_buf, 0, -1, false, depot_content or {})
      vim.api.nvim_buf_set_lines(right_buf, 0, -1, false, current_content)

      vim.bo[left_buf].filetype = filetype
      vim.bo[right_buf].filetype = filetype
      vim.bo[left_buf].buftype = 'nofile'
      vim.bo[right_buf].buftype = 'nofile'
      vim.bo[left_buf].bufhidden = 'wipe'
      vim.bo[right_buf].bufhidden = 'wipe'
      vim.api.nvim_buf_set_name(left_buf, depot_name)
      vim.api.nvim_buf_set_name(right_buf, local_name)

      -- Close P4 window if it's open
      if State.window.win and vim.api.nvim_win_is_valid(State.window.win) then
        vim.api.nvim_win_close(State.window.win, true)
      end

      -- Open diff in a new tab to avoid layout issues
      vim.cmd('tabnew')

      local left_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(left_win, left_buf)

      vim.cmd('vsplit')
      vim.cmd('wincmd l')
      local right_win = vim.api.nvim_get_current_win()
      vim.api.nvim_win_set_buf(right_win, right_buf)

      vim.api.nvim_win_call(left_win, function() vim.cmd('diffthis') end)
      vim.api.nvim_win_call(right_win, function() vim.cmd('diffthis') end)

      vim.wo[left_win].scrollbind = true
      vim.wo[right_win].scrollbind = true
      vim.wo[left_win].cursorbind = true
      vim.wo[right_win].cursorbind = true

      local close_both = function()
        -- Delete buffers to ensure cleanup
        pcall(vim.api.nvim_buf_delete, left_buf, { force = true })
        pcall(vim.api.nvim_buf_delete, right_buf, { force = true })

        -- Close the tab if there are multiple tabs, otherwise just close windows
        if vim.fn.tabpagenr('$') > 1 then
          vim.cmd('tabclose')
        else
          pcall(vim.api.nvim_win_close, left_win, true)
          pcall(vim.api.nvim_win_close, right_win, true)
        end
      end

      -- Auto-close both windows when either is closed
      vim.api.nvim_create_autocmd('WinClosed', {
        callback = function(args)
          local closed_win = tonumber(args.match)
          if closed_win == left_win or closed_win == right_win then
            vim.schedule(function()
              close_both()
            end)
          end
        end,
        once = true,
      })

      local revert_hunk = function()
        -- Revert current hunk to depot version (diffget from left to right)
        vim.api.nvim_set_current_win(right_win)
        vim.cmd('diffget')
      end

      local save_file = function()
        -- Save the right buffer (local file)
        vim.api.nvim_win_call(right_win, function()
          local lines = vim.api.nvim_buf_get_lines(right_buf, 0, -1, false)
          vim.fn.writefile(lines, file)
        end)
        vim.notify('Saved changes to ' .. vim.fn.fnamemodify(file, ':t'), vim.log.levels.INFO)
      end

      -- Keymaps - focus on reverting changes
      for _, buf in ipairs({left_buf, right_buf}) do
        vim.keymap.set('n', 'u', revert_hunk, { buffer = buf, noremap = true, silent = true, desc = 'Revert hunk' })
        vim.keymap.set('n', ']c', function() vim.cmd('normal! ]c') end, { buffer = buf, noremap = true, silent = true, desc = 'Next change' })
        vim.keymap.set('n', '[c', function() vim.cmd('normal! [c') end, { buffer = buf, noremap = true, silent = true, desc = 'Previous change' })
      end

      -- Make right buffer writable and set up save commands
      vim.api.nvim_buf_call(right_buf, function()
        vim.bo.buftype = ''  -- Remove nofile buftype to allow writing
        vim.bo.modifiable = true
        vim.bo.modified = false  -- Mark as not modified initially

        -- Don't use the actual file name to avoid "overwrite?" prompts
        -- BufWriteCmd will handle the actual writing

        -- Set up autocommand to handle writes
        vim.api.nvim_create_autocmd('BufWriteCmd', {
          buffer = right_buf,
          callback = function()
            save_file()
            vim.bo[right_buf].modified = false
            return true
          end,
        })

        -- Override wq to save and close
        vim.api.nvim_buf_create_user_command(right_buf, 'Wq', function()
          save_file()
          vim.bo[right_buf].modified = false
          close_both()
        end, {})
      end)

      vim.api.nvim_set_current_win(right_win)
    end

    -- ============================================================================
    -- COMMANDS
    -- ============================================================================

    vim.api.nvim_create_user_command('P4Edit', M.edit, {})
    vim.api.nvim_create_user_command('P4Add', M.add, {})
    vim.api.nvim_create_user_command('P4Revert', M.revert, {})
    vim.api.nvim_create_user_command('P4Delete', function() M.delete() end, {})
    vim.api.nvim_create_user_command('P4Move', function() M.move() end, {})
    vim.api.nvim_create_user_command('P4Opened', M.show_opened, {})
    vim.api.nvim_create_user_command('P4Diff', function() M.show_diff(vim.fn.expand('%:p')) end, {})

    -- Keymaps
    vim.keymap.set('n', '<leader>pe', M.edit, { desc = 'P4: Edit current file' })
    vim.keymap.set('n', '<leader>pa', M.add, { desc = 'P4: Add current file' })
    vim.keymap.set('n', '<leader>pr', M.revert, { desc = 'P4: Revert current file' })
    vim.keymap.set('n', '<leader>px', function() M.delete() end, { desc = 'P4: Delete current file' })
    vim.keymap.set('n', '<leader>pm', function() M.move() end, { desc = 'P4: Move/rename current file' })
    vim.keymap.set('n', '<leader>po', M.show_opened, { desc = 'P4: Show opened files' })
    vim.keymap.set('n', '<leader>pd', function() M.show_diff(vim.fn.expand('%:p')) end, { desc = 'P4: Diff current file' })
  end,
}
