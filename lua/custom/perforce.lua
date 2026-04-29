-- Perforce integration for Neovim
local utils = require('custom.utils')
local diffsplit = require('custom.diffsplit')

-- ============================================================================
-- SIMPLE FILE OPERATIONS
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

-- Batch check file revision status using a single `p4 -ztag fstat` call.
-- Returns a table mapping depot_path -> { have_rev, head_rev, unresolved }
local function batch_check_file_status(depot_paths)
    if not depot_paths or #depot_paths == 0 then return {} end

    local cmd = 'p4 -ztag fstat'
    for _, depot_path in ipairs(depot_paths) do
        cmd = cmd .. ' ' .. url_encode(vim.fn.shellescape(depot_path))
    end

    local ok, result = pcall(vim.fn.systemlist, cmd)
    if not ok or vim.v.shell_error ~= 0 then return {} end

    local status_map = {}
    local current_depot
    local current_status = {}

    for _, line in ipairs(result) do
        line = url_decode(line)
        local depot = line:match('^%.%.%. depotFile%s+(.+)$')
        if depot then
            -- Save previous entry
            if current_depot then
                status_map[current_depot] = current_status
            end
            current_depot = depot
            current_status = {}
        else
            local have = line:match('^%.%.%. haveRev%s+(%d+)$')
            if have then current_status.have_rev = tonumber(have) end

            local head = line:match('^%.%.%. headRev%s+(%d+)$')
            if head then current_status.head_rev = tonumber(head) end

            if line:match('^%.%.%. unresolved') then current_status.unresolved = true end
        end
    end
    -- Save last entry
    if current_depot then
        status_map[current_depot] = current_status
    end

    return status_map
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

    diffsplit.open_file_diffsplit({
        filepath = file,
        left_content = depot_content,
        left_name = (depot_file or 'P4 Depot') .. (have_rev and ('#' .. have_rev) or ''),
        notify_message = 'P4 Diff: [ / ] jump hunks, r reverts hunk, q closes base, Q closes both',
    })
end

--- Get current Perforce client info (name and root)
local function get_client_info()
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

--- Get all changelists, their descriptions, jobs, shelved files, and opened files for the current client
local function get_client_changelists(client_info)
    local file_map = {}
    local cl_numbers = {}

    -- Get all pending changelists for the current client
    local changes_output = p4_cmd({cmd = 'changes -s pending -c ' .. vim.fn.shellescape(client_info.name)})
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
                                table.insert(file_map[current_cl].jobs, { id = job_id })
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

    -- Batch check revision status for all opened files
    local status_mapping = batch_check_file_status(depot_paths)

    -- Second pass: add files with resolved local paths and revision status to changelists
    for _, file_data in ipairs(files_data) do
        local local_path = path_mapping[file_data.depot_path] or ''
        local status = status_mapping[file_data.depot_path] or {}
        local have_rev = status.have_rev
        local head_rev = status.head_rev
        table.insert(file_map[file_data.change_number].opened_files, {
            depot_path = file_data.depot_path,
            action = file_data.action,
            local_path = local_path,
            relative_path = local_path:sub(#client_info.root + 2),
            have_rev = have_rev,
            head_rev = head_rev,
            outdated = have_rev and head_rev and head_rev > have_rev,
            unresolved = status.unresolved,
        })
    end

    -- Return the complete changelist file map
    return file_map
end

-- ============================================================================
-- WINDOW KEYBIND ACTIONS
-- ============================================================================

-- Shared state and buffer naming
local BUFFER_NAME = 'Perforce Window'
local EXPAND_SHELF = {}  -- per-changelist: EXPAND_SHELF[cn] = true/false
local CHANGELISTS = {}
local INDEX_MAP = {}

local show_window -- forward declaration for actions use

--- Return window for perforce window if it exists
local function get_perforce_window()
    -- Find buffer for perforce window
    local buf = utils.find_buffer_by_name(BUFFER_NAME)
    if not buf then
        error('No valid Perforce buffer for action')
    end
    -- Find window displaying that buffer
    local win = utils.find_window_by_buffer(buf)
    if win then
        return win
    end
    error('No valid Perforce window for action')
end

-- Return the INDEX_MAP entry for the line under the cursor
local function get_action_data()
    local win = get_perforce_window()
    local line = utils.get_cursor_position(win).line
    local data = INDEX_MAP[line]
    if not data then
        error('No action data found for line ' .. line)
    end
    return data
end

--- Edit the description of a changelist
local function edit_changelist_description(cn)
    -- Get the change spec
    local change_spec = p4_cmd({cmd = 'change -o' .. (cn ~= 'default' and ' ' .. cn or '')})

    -- Filter out comment lines (starting with #)
    local filtered_spec = {}
    for _, line in ipairs(change_spec) do
        if not line:match('^#') then
            table.insert(filtered_spec, line)
        end
    end

    -- Add documentation header
    local doc_lines = {
        '# Perforce Editor',
        '#',
        '# Edit the changelist below. When done:',
        '#   w - Save changes to Perforce',
        '#   q - Discard and go back',
        '#',
    }

    -- Combine documentation and spec
    local buffer_content = {}
    for _, line in ipairs(doc_lines) do
        table.insert(buffer_content, line)
    end
    for _, line in ipairs(filtered_spec) do
        table.insert(buffer_content, line)
    end

    -- Scratch buffer: unlisted, not a file, no swapfile
    local buf = utils.create_scratch_buffer('P4-Change-' .. cn, true)
    vim.bo[buf].filetype = 'conf'
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, buffer_content)

    -- Remember the window, then show the edit buffer
    local edit_win = vim.api.nvim_get_current_win()
    utils.set_window_buffer(edit_win, buf)

    -- Apply syntax highlighting
    local ns_id = vim.api.nvim_create_namespace('P4ChangeSpec')
    for i, line in ipairs(buffer_content) do
        local line_idx = i - 1
        -- Highlight comments
        if line:match('^#') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
        -- Highlight separator
        elseif line:match('^%-%-%-') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
        -- Highlight field names (e.g., "Change:", "Client:", "Description:")
        elseif line:match('^%a+:') then
            local colon_pos = line:find(':')
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, colon_pos)
        end
    end

    -- Close the edit buffer and return to the Perforce window
    local function close_edit_buffer()
        utils.dismiss_buffer_window(edit_win, buf)
        show_window()
    end

    -- w: save changes to Perforce, then close
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
    vim.keymap.set('n', 'w', function()
        -- Get buffer contents and filter out documentation comments
        local all_lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
        local spec_lines = {}
        for _, line in ipairs(all_lines) do
            if not line:match('^#') and not line:match('^%-%-%-$') then
                table.insert(spec_lines, line)
            end
        end

        -- Re-encode special characters in depot paths (Files: section)
        -- p4 change -o returns encoded paths (%40 for @, %23 for #) but
        -- p4_cmd url_decodes everything.  We must re-encode before feeding
        -- the spec back to p4 change -i.
        local in_files = false
        for idx, line in ipairs(spec_lines) do
            if line:match('^Files:') then
                in_files = true
            elseif line:match('^%a') then
                in_files = false
            elseif in_files and line:match('^%s+//') then
                -- Line format: "\t//depot/path\t# action"
                -- Only encode the depot path, not the trailing "\t# action" suffix.
                local leading, depot_path, suffix = line:match('^(%s+)(//.-)(%s+#.*)$')
                if depot_path then
                    spec_lines[idx] = leading .. url_encode(depot_path) .. suffix
                else
                    spec_lines[idx] = url_encode(line)
                end
            end
        end

        -- Write to temp file and submit
        local tmpname = vim.fn.tempname()
        vim.fn.writefile(spec_lines, tmpname)

        local result = vim.fn.systemlist('p4 change -i < ' .. vim.fn.shellescape(tmpname))
        os.remove(tmpname)

        if vim.v.shell_error ~= 0 then
            vim.notify('Failed to update: ' .. table.concat(result, '\n'), vim.log.levels.ERROR)
        else
            vim.notify('Changelist updated', vim.log.levels.INFO)
            close_edit_buffer()
        end
    end, opts)

    -- q: discard and go back
    vim.keymap.set('n', 'q', close_edit_buffer, opts)
end

--- Cursor based action handler
local function input_action()
    local data = get_action_data()

    -- Toggle shelf expansion
    if data.type == 'shelf_toggle' then
        local cn = data.change_number
        EXPAND_SHELF[cn] = not EXPAND_SHELF[cn]
        show_window()

    -- Open file in editor
    elseif data.type == 'opened_file' then
        vim.cmd('edit ' .. vim.fn.fnameescape(data.opened_file.local_path))

    -- Edit the description of a changelist
    elseif data.type == 'description_line' or data.type == 'changelist'
           or data.type == 'jobs_header' or data.type == 'job_line' then
        edit_changelist_description(data.change_number)
    end
end

local function shelve_files()
    local data = get_action_data()

    -- Shelve single file
    if data.type == 'opened_file' then
        local file = data.opened_file
        local current_cl = data.change_number
        if current_cl == 'default' then
            vim.notify('Cannot shelve files in default changelist', vim.log.levels.WARN)
            return
        end
        p4_cmd({cmd = 'shelve -f -c ' .. current_cl .. ' ', filepath = file.depot_path})
        show_window()
    -- Shelve all files in changelist (via Files header)
    elseif data.type == 'files_header' then
        local cn = data.change_number
        if cn == 'default' then
            vim.notify('Cannot shelve files in default changelist', vim.log.levels.WARN)
            return
        end
        p4_cmd({cmd = 'shelve -f -c ' .. cn})
        show_window()
    end
end

local function notify_unresolved(depot_paths)
    local status = batch_check_file_status(depot_paths)
    local count = 0
    for _, st in pairs(status) do
        if st.unresolved then count = count + 1 end
    end
    if count > 0 then
        vim.notify(string.format('P4: %d file%s need resolve (press R)', count, count ~= 1 and 's' or ''), vim.log.levels.WARN)
    end
end

local function unshelve_files()
    local data = get_action_data()

    if data.type == 'shelved_file' then
        local cn = data.change_number
        local depot_path = data.shelved_file
        p4_cmd({cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn .. ' ', filepath = depot_path})
        vim.cmd('checktime')
        notify_unresolved({depot_path})
        show_window()
    elseif data.type == 'shelf_toggle' then
        local cn = data.change_number
        -- Bulk unshelve may partially succeed with warnings (e.g. "also opened by",
        -- "Can't clobber writable file").  Don't treat that as a fatal error.
        local ok, err = pcall(p4_cmd, {cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn})
        if not ok then
            vim.notify(err, vim.log.levels.WARN)
        end
        vim.cmd('checktime')
        notify_unresolved(CHANGELISTS[cn].shelved_files)
        show_window()
    end
end

local function revert_files()
    local data = get_action_data()

    -- Revert single file
    if data.type == 'opened_file' then
        local file = data.opened_file
        vim.ui.input(
            { prompt = 'Revert ' .. file.relative_path .. '? (y/N): ' },
            function(input)
                if not (input and input:lower() == 'y') then return end
                p4_cmd({cmd = 'revert ', filepath = file.local_path})
                vim.cmd('checktime') -- Refresh file in editor if open
                show_window()
            end
        )
    -- Revert entire changelist
    elseif data.type == 'files_header' then
        local cn = data.change_number
        vim.ui.input(
            { prompt = 'Revert all files in changelist ' .. cn .. '? (y/N): ' },
            function(input)
                if not (input and input:lower() == 'y') then return end
                vim.cmd('checktime') -- Refresh files in editor if open
                p4_cmd({cmd = 'revert -c ' .. cn .. ' //...'})
                show_window()
            end
        )
    end
end

local function move_files()
    local data = get_action_data()

    if data.type == 'opened_file' or data.type == 'files_header' then
        local cl_options = {}
        for cn, content in pairs(CHANGELISTS) do
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
                -- Move all files
                if data.type == 'files_header' then
                    local cn = data.change_number
                    local files_to_move = CHANGELISTS[cn].opened_files
                    for _, file in ipairs(files_to_move) do
                        p4_cmd({cmd = 'reopen -c ' .. target .. ' ', filepath = file.depot_path})
                    end
                -- Move single file
                elseif data.type == 'opened_file' then
                    p4_cmd({cmd = 'reopen -c ' .. target .. ' ', filepath = data.opened_file.depot_path})
                end
                -- Refresh and update display
                vim.schedule(show_window)
            end
        )
    end
end

local function delete_stuff()
    local data = get_action_data()

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
                if #CHANGELISTS[cn].opened_files > 0 then
                    p4_cmd({cmd = 'revert -c ' .. cn .. ' //...'})
                    vim.cmd('checktime') -- Refresh files in editor if open
                end
                -- Then delete all shelved files (if any).
                if #CHANGELISTS[cn].shelved_files > 0 then
                    p4_cmd({cmd = 'shelve -d -c ' .. cn})
                end
                -- Remove all jobs from the changelist
                for _, job in ipairs(CHANGELISTS[cn].jobs) do
                    p4_cmd({cmd = 'fix -d -c ' .. cn .. ' ' .. job.id})
                end
                -- Finally delete the changelist itself
                p4_cmd({cmd = 'change -d ' .. cn})
                vim.schedule(show_window)
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
                show_window()
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
                show_window()
            end
        )
    end
end

local function show_diff()
    local data = get_action_data()

    if data.type == 'opened_file' then
        vim.schedule(function() p4_vdiffsplit(data.opened_file.local_path) end)
    end
end

local function sync_files()
    local data = get_action_data()

    if data.type == 'opened_file' then
        local file = data.opened_file
        p4_cmd({cmd = 'sync ', filepath = file.depot_path})
        vim.cmd('checktime')
        notify_unresolved({file.depot_path})
        show_window()
    elseif data.type == 'files_header' then
        local cn = data.change_number
        local depot_paths = {}
        for _, file in ipairs(CHANGELISTS[cn].opened_files) do
            p4_cmd({cmd = 'sync ', filepath = file.depot_path})
            table.insert(depot_paths, file.depot_path)
        end
        vim.cmd('checktime')
        notify_unresolved(depot_paths)
        show_window()
    end
end

local function resolve_files()
    local data = get_action_data()

    if data.type ~= 'opened_file' then return end

    local file = data.opened_file

    -- Try auto-merge first — if it works, no user decision needed
    pcall(p4_cmd, {cmd = 'resolve -am ', filepath = file.depot_path})

    -- Check if still unresolved (auto-merge failed or had conflicts)
    local status = batch_check_file_status({file.depot_path})
    local st = status[file.depot_path]
    if not (st and st.unresolved) then
        vim.notify('P4: Auto-merged ' .. file.relative_path, vim.log.levels.INFO)
        vim.cmd('checktime')
        show_window()
        return
    end

    -- Conflicts remain — ask the user how to proceed
    local resolve_options = {
        'Merge with conflict markers (edit manually)',
        'Accept theirs (discard your changes)',
        'Accept yours (discard their changes)',
    }

    vim.ui.select(resolve_options, {
        prompt = 'Auto-merge failed for ' .. file.relative_path .. ' — conflicts remain:',
    }, function(choice)
        if not choice then return end

        if choice:match('^Accept theirs') then
            p4_cmd({cmd = 'resolve -at ', filepath = file.depot_path})
            vim.cmd('checktime')
            show_window()
        elseif choice:match('^Accept yours') then
            p4_cmd({cmd = 'resolve -ay ', filepath = file.depot_path})
            vim.cmd('checktime')
            show_window()
        elseif choice:match('^Merge') then
            -- Use fstat to get the exact resolve versions p4 recorded.
            -- After `p4 sync`, haveRev is already bumped to the new head, so
            -- using file.have_rev as the base would be the same rev as theirs
            -- and diff3 would mark every local line as a conflict.
            -- fstat exposes (index N varies by resolve type):
            --   resolveBaseFileN / resolveBaseRevN  → common ancestor (ORIGINAL)
            --   resolveFromFileN / resolveEndFromRevN → incoming version (THEIRS)
            local fstat_cmd = 'p4 -ztag fstat -Or ' .. url_encode(vim.fn.shellescape(file.local_path))
            local fstat_out = vim.fn.systemlist(fstat_cmd)
            if vim.v.shell_error ~= 0 then
                vim.notify('P4: fstat -Or failed: ' .. table.concat(fstat_out, '\n'), vim.log.levels.ERROR)
                return
            end
            local base_file, base_rev, from_file, from_rev
            local resolve_records = {}
            for _, line in ipairs(fstat_out) do
                line = url_decode(line)
                local n, val
                n, val = line:match('^%.%.%. resolveType(%d+)%s+(.+)$')
                if n then resolve_records[n] = resolve_records[n] or {}; resolve_records[n].type = val end
                n, val = line:match('^%.%.%. resolveBaseFile(%d+)%s+(.+)$')
                if n then resolve_records[n] = resolve_records[n] or {}; resolve_records[n].base_file = val end
                -- base_rev can be "none" when there is no common ancestor (e.g. new file)
                n, val = line:match('^%.%.%. resolveBaseRev(%d+)%s+(.+)$')
                if n then resolve_records[n] = resolve_records[n] or {}; resolve_records[n].base_rev = val end
                n, val = line:match('^%.%.%. resolveFromFile(%d+)%s+(.+)$')
                if n then resolve_records[n] = resolve_records[n] or {}; resolve_records[n].from_file = val end
                n, val = line:match('^%.%.%. resolveEndFromRev(%d+)%s+(%d+)$')
                if n then resolve_records[n] = resolve_records[n] or {}; resolve_records[n].from_rev = val end
                -- Fallback: some resolve types only have resolveStartFromRev
                n, val = line:match('^%.%.%. resolveStartFromRev(%d+)%s+(%d+)$')
                if n then
                    resolve_records[n] = resolve_records[n] or {}
                    if not resolve_records[n].from_rev then resolve_records[n].from_rev = val end
                end
            end
            -- Find the first content resolve record (skip filetype resolves)
            for _, rec in pairs(resolve_records) do
                if rec.type == 'content' and rec.base_file and rec.base_rev and rec.from_file and rec.from_rev then
                    base_file = rec.base_file
                    base_rev = rec.base_rev
                    from_file = rec.from_file
                    from_rev = rec.from_rev
                    break
                end
            end
            if not (base_file and base_rev and from_file and from_rev) then
                -- Dump resolve-related fstat fields for debugging
                local resolve_lines = {}
                for _, line in ipairs(fstat_out) do
                    local decoded = url_decode(line)
                    if decoded:match('resolve') then
                        table.insert(resolve_lines, decoded)
                    end
                end
                local diag = #resolve_lines > 0
                    and 'Resolve fields:\n' .. table.concat(resolve_lines, '\n')
                    or 'No resolve fields found in fstat output'
                vim.notify('P4: Could not get resolve versions from fstat.\n' .. diag, vim.log.levels.ERROR)
                return
            end

            -- Get the three versions for diff3:
            --   yours  = current file on disk (your local edits)
            --   base   = common ancestor (what you originally synced from)
            --   theirs = incoming version (what was just synced/unshelved)
            local tmp_theirs = vim.fn.tempname()
            local tmp_base   = vim.fn.tempname()
            vim.fn.systemlist('p4 print -q -o ' .. vim.fn.shellescape(tmp_theirs)
                .. ' ' .. url_encode(vim.fn.shellescape(from_file)) .. '#' .. from_rev)
            if base_rev == 'none' then
                -- No common ancestor (new file) — use empty base for diff3
                vim.fn.writefile({}, tmp_base)
            else
                vim.fn.systemlist('p4 print -q -o ' .. vim.fn.shellescape(tmp_base)
                    .. ' ' .. url_encode(vim.fn.shellescape(base_file)) .. '#' .. base_rev)
            end

            -- Run diff3 to produce merged content with conflict markers
            local merged = vim.fn.systemlist(string.format(
                'diff3 -m --label LOCAL %s --label ORIGINAL %s --label INCOMING %s',
                vim.fn.shellescape(file.local_path),
                vim.fn.shellescape(tmp_base),
                vim.fn.shellescape(tmp_theirs)
            ))
            os.remove(tmp_theirs)
            os.remove(tmp_base)

            -- Open the file and replace content with merged result (don't save yet)
            vim.cmd('edit ' .. vim.fn.fnameescape(file.local_path))
            local buf = vim.api.nvim_get_current_buf()
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, merged)

            -- Highlight conflict markers
            local ns = vim.api.nvim_create_namespace('P4ConflictMarkers')
            local function apply_conflict_highlights()
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)
                local section
                for i, l in ipairs(lines) do
                    local li = i - 1
                    if l:match('^<<<<<<< LOCAL') then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiagnosticInfo', li, 0, #l)
                        section = 'local'
                    elseif l:match('^||||||| ORIGINAL') then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiagnosticError', li, 0, #l)
                        section = 'original'
                    elseif l:match('^=======') then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiagnosticWarn', li, 0, #l)
                        section = 'incoming'
                    elseif l:match('^>>>>>>> INCOMING') then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiagnosticWarn', li, 0, #l)
                        section = nil
                    elseif section == 'local' then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiffAdd', li, 0, #l)
                    elseif section == 'original' then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiffDelete', li, 0, #l)
                    elseif section == 'incoming' then
                        vim.api.nvim_buf_add_highlight(buf, ns, 'DiffChange', li, 0, #l)
                    end
                end
            end
            apply_conflict_highlights()

            local function cleanup_resolve_keymaps()
                for _, key in ipairs({ ']', '[', 'q', '<Esc>' }) do
                    pcall(vim.keymap.del, 'n', key, { buffer = buf })
                end
            end

            -- Re-apply highlights when buffer changes
            vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
                buffer = buf,
                callback = function()
                    local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
                    if not content:match('<<<<<<< LOCAL') then
                        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                        -- All conflicts resolved — auto-save, press q to accept and return
                        vim.cmd('write')
                        vim.notify('P4: All conflicts resolved — press q to accept and return', vim.log.levels.INFO)
                        return true
                    end
                    apply_conflict_highlights()
                end,
            })

            -- [ and ] to jump between conflict sections
            local map_opts = { buffer = buf, nowait = true, noremap = true, silent = true }
            vim.keymap.set('n', ']', function()
                vim.fn.search('<<<<<<< LOCAL', 'W')
            end, map_opts)
            vim.keymap.set('n', '[', function()
                vim.fn.search('<<<<<<< LOCAL', 'bW')
            end, map_opts)

            -- q: save and accept resolve (when all markers gone)
            vim.keymap.set('n', 'q', function()
                local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
                if content:match('<<<<<<< LOCAL') then
                    vim.notify('P4: Conflict markers still present — resolve all conflicts first', vim.log.levels.WARN)
                    return
                end
                cleanup_resolve_keymaps()
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                vim.cmd('write')
                p4_cmd({cmd = 'resolve -ay ', filepath = file.depot_path})
                vim.schedule(show_window)
            end, map_opts)

            -- Esc: cancel — reload original file, nothing changes in p4
            vim.keymap.set('n', '<Esc>', function()
                cleanup_resolve_keymaps()
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                vim.cmd('edit!')
                vim.schedule(show_window)
            end, map_opts)

            vim.schedule(function()
                vim.notify('P4 Resolve: [ / ] jump conflicts | q save and return | Esc cancel', vim.log.levels.INFO)
            end)

            -- Jump to first conflict
            vim.fn.cursor(1, 1)
            vim.fn.search('<<<<<<< LOCAL', 'W')
        end
    end)
end

-- ===========================================================================
-- PERFORCE WINDOW
-- ===========================================================================

--- Initialize or clear the output buffer
local function initialize_buffer()
    -- Create a brand new buffer
    local buf = utils.create_scratch_buffer(BUFFER_NAME, false)
    -- Setup keymaps for the buffer
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
    vim.keymap.set('n', 'q', function()
        local win = utils.find_window_by_buffer(buf)
        utils.dismiss_buffer_window(win, buf)
    end, opts)
    vim.keymap.set('n', '<CR>', input_action, opts)
    vim.keymap.set('n', 'r', revert_files, opts)
    vim.keymap.set('n', 'm', move_files, opts)
    vim.keymap.set('n', 's', shelve_files, opts)
    vim.keymap.set('n', 'u', unshelve_files, opts)
    vim.keymap.set('n', 'D', delete_stuff, opts)
    vim.keymap.set('n', 'd', show_diff, opts)
    vim.keymap.set('n', 'S', sync_files, opts)
    vim.keymap.set('n', 'R', resolve_files, opts)

    return buf
end

local function setup_display_lines()
    INDEX_MAP = {}
    local lines = {}
    for cn, content in pairs(CHANGELISTS) do
        -- CL header line
        table.insert(lines, string.format('CL %s :', cn))
        table.insert(INDEX_MAP, { type = 'changelist', change_number = cn })

        -- All description lines indented
        local desc_start_line = #lines + 1    -- 1-indexed for cursor operations
        for _, desc_line in ipairs(content.description_lines) do
            table.insert(lines, string.format('  %s', desc_line))
            table.insert(INDEX_MAP, {
                type = 'description_line',
                change_number = cn,
                desc_start = desc_start_line,
                desc_end = desc_start_line + #content.description_lines - 1,
            })
        end

        -- Jobs section (if available)
        if content.jobs and #content.jobs > 0 then
            table.insert(lines, '')
            table.insert(INDEX_MAP, { type = 'separator' })
            local jobs_header_line = #lines + 1
            table.insert(lines, '  Jobs')
            table.insert(INDEX_MAP, {
                type = 'jobs_header',
                change_number = cn,
                jobs_header_line = jobs_header_line,
            })
            for _, job in ipairs(content.jobs) do
                table.insert(lines, string.format('    (%s) %s', job.id, job.description or job.line))
                table.insert(INDEX_MAP, { type = 'job_line', change_number = cn, job_id = job.id })
            end
        end

        -- Files section
        local file_count = #content.opened_files
        if file_count > 0 then
            table.insert(lines, '')
            table.insert(INDEX_MAP, { type = 'separator' })
            local count_str = string.format(' (%d file%s)', file_count, file_count ~= 1 and 's' or '')
            table.insert(lines, string.format('  Files%s', count_str))
            table.insert(INDEX_MAP, { type = 'files_header', change_number = cn })
            for _, file in ipairs(content.opened_files) do
                local marker = '  '
                if file.unresolved then
                    marker = '✘ '
                elseif file.outdated then
                    marker = '↑ '
                end
                table.insert(lines, string.format('    %-13s %s%s', file.action, marker, file.relative_path))
                table.insert(INDEX_MAP, { type = 'opened_file', change_number = cn, opened_file = file })
            end
        end

        -- Shelf toggle line
        local shelf_size = #content.shelved_files
        if shelf_size > 0 then
            table.insert(lines, '')    -- Empty line before shelf
            table.insert(INDEX_MAP, { type = 'separator' })    -- Corresponding index_map entry
            local expand_char = EXPAND_SHELF[cn] and '▼' or '▶'
            table.insert(lines, string.format('  %s Shelf (%d file%s)', expand_char, shelf_size, shelf_size ~= 1 and 's' or ''))
            table.insert(INDEX_MAP, { type = 'shelf_toggle', change_number = cn })
            -- Shelved files (if expanded)
            if EXPAND_SHELF[cn] then
                for _, depot_path in ipairs(content.shelved_files) do
                    table.insert(lines, string.format('    %s', depot_path))
                    table.insert(INDEX_MAP, { type = 'shelved_file', change_number = cn, shelved_file = depot_path })
                end
            end
        end
        -- Empty line separator
        table.insert(lines, '')
        table.insert(INDEX_MAP, { type = 'separator' })
    end

    -- Help line
    table.insert(lines, '[Enter=open/edit/toggle | d=diff | r=revert | m=move | s=shelve | u=unshelve | D=delete | S=sync | R=resolve]')

    return lines
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
            else
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
            end
        -- Jobs header
        elseif line:match('^  Jobs$') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, #line)

        -- Job lines (indented with 4 spaces, starts with parenthesis)
        elseif line:match('^     %([^%)]+%)') then
            -- Highlight job ID in parentheses
        elseif line:match('^    %([^%)]+%)') then
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

                -- Check for status markers and highlight accordingly
                local file_entry = INDEX_MAP[i] and INDEX_MAP[i].opened_file
                if file_entry and file_entry.unresolved then
                    -- Highlight marker '✘' (3 bytes at offset 18) and path in red
                    vim.api.nvim_buf_add_highlight(buf, ns_id, 'DiagnosticError', line_idx, 18, 21)
                    vim.api.nvim_buf_add_highlight(buf, ns_id, 'DiagnosticError', line_idx, 22, #line)
                elseif file_entry and file_entry.outdated then
                    -- Highlight marker '↑' (3 bytes at offset 18) and path in yellow
                    vim.api.nvim_buf_add_highlight(buf, ns_id, 'WarningMsg', line_idx, 18, 21)
                    vim.api.nvim_buf_add_highlight(buf, ns_id, 'WarningMsg', line_idx, 22, #line)
                else
                    -- Normal: path starts at offset 20 (after 2 spaces)
                    vim.api.nvim_buf_add_highlight(buf, ns_id, 'String', line_idx, 20, #line)
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


show_window = function()
    -- Capture cursor position from existing perforce window before recreating buffer
    local saved_cursor_pos = nil
    local buffer = utils.find_buffer_by_name(BUFFER_NAME)
    if buffer then
        local win = utils.find_window_by_buffer(buffer)
        if win then
            saved_cursor_pos = utils.get_cursor_position(win)
        end
    else
        -- Create a fresh buffer
        buffer = initialize_buffer()
    end

    -- Take over as main window
    local target_win = utils.close_other_windows()

    -- Build lines and index map
    local info = get_client_info()
    CHANGELISTS = get_client_changelists(info)
    local lines = setup_display_lines()

    -- Show buffer in the single remaining window
    if target_win and utils.is_window_valid(target_win) then
        vim.api.nvim_win_set_buf(target_win, buffer)
    else
        target_win = utils.reuse_or_create_window_for_buffer(buffer)
    end
    utils.set_buffer_lines(buffer, 0, -1, lines)
    apply_syntax_highlighting(buffer)

    -- Focus on the perforce window
    utils.set_current_window(target_win)
    -- Restore cursor position if we had one saved
    if saved_cursor_pos then
        pcall(utils.set_cursor_position, target_win, saved_cursor_pos.line, saved_cursor_pos.col)
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
vim.api.nvim_create_user_command('P4Diff', function() p4_vdiffsplit(vim.fn.expand('%:p')) end,    { desc = 'P4: Diff current file' })

-- Keymaps
vim.keymap.set('n', '<leader>ps', show_window, { desc = 'P4: Show opened files' })
vim.keymap.set('n', '<leader>pe', p4_edit, { desc = 'P4: Edit current file' })
vim.keymap.set('n', '<leader>pa', p4_add, { desc = 'P4: Add current file' })
vim.keymap.set('n', '<leader>pr', p4_revert, { desc = 'P4: Revert current file' })
vim.keymap.set('n', '<leader>pD', p4_delete, { desc = 'P4: Delete current file' })
vim.keymap.set('n', '<leader>pR', p4_rename, { desc = 'P4: Rename/move current file' })
vim.keymap.set('n', '<leader>pd', function() p4_vdiffsplit(vim.fn.expand('%:p')) end, { desc = 'P4: Diff current file' })
