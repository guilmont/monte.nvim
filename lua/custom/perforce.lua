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
    return (str:gsub('%%(%x%x)', function(hex) return string.char(tonumber(hex, 16)) end))
end
-- End the way back
-- This function encodes special characters in paths
local function url_encode(str)
    return (str:gsub('([@#%%*])', function(c) return string.format('%%%02X', string.byte(c)) end))
end


-- Run a p4 command and return its output lines, with CR stripped (p4 may
-- return CRLF) and nothing decoded: callers decode the depot paths they parse
-- out (see parse_tagged), so free text such as descriptions stays verbatim.
-- Errors with p4's output when it exits non-zero, unless args.allow_failure.
--   cmd:       command and options, e.g. 'revert -c 123'
--   filepath, newpath: paths appended to cmd, URL-encoded unless args.literal
--   revision:  appended to the last path as #rev
--   paths:     depot paths, encoded and passed on stdin (`p4 -x -`), so the
--              command line stays short (cmd.exe limits it to 8191 chars).
--              p4 goes on past a failing path and exits non-zero.
--   input:     lines for stdin, e.g. a spec for `change -i`
local function p4_cmd(args)
    if args.paths and #args.paths == 0 then return {} end
    local cmd = 'p4 ' .. (args.paths and '-x - ' or '') .. args.cmd
    for _, path in ipairs({ args.filepath, args.newpath }) do
        cmd = cmd .. ' ' .. vim.fn.shellescape(args.literal and path or url_encode(path))
    end
    if args.revision then
        cmd = cmd .. '#' .. args.revision
    end

    local input = args.paths and vim.tbl_map(url_encode, args.paths) or args.input
    local result = input and vim.fn.systemlist(cmd, input) or vim.fn.systemlist(cmd)
    for i, line in ipairs(result) do
        result[i] = line:gsub('\r$', '')
    end
    if vim.v.shell_error ~= 0 and not args.allow_failure then
        local message = vim.trim(table.concat(result, '\n'))
        error(message ~= '' and message or 'p4 ' .. args.cmd .. ' failed', 0)
    end
    return result
end

-- Parse tagged output (-ztag, and fstat's) into records of field -> value, one
-- per block of '... field value' lines. Fields holding a depot path (depotFile,
-- movedFile, resolveFromFile0, ...) are URL-decoded; others, such as the local
-- path of `where`, are kept as they are. Other lines (errors) are skipped.
local function parse_tagged(lines)
    local records = {}
    local record
    for _, line in ipairs(lines) do
        local field, value = line:match('^%.%.%. (%S+) ?(.*)$')
        if field then
            if not record then
                record = {}
                table.insert(records, record)
            end
            record[field] = field:match('File%d*$') and url_decode(value) or value
        elseif line == '' then
            record = nil
        end
    end
    return records
end

-- Batch resolve multiple depot paths to local paths using a single `p4 where` call.
-- Returns a table mapping depot_path -> local_path
local function batch_depot_to_local(depot_paths)
    -- p4 where exits non-zero if any single path is unmapped, but still
    -- outputs valid entries for the rest
    local mapping = {}
    for _, rec in ipairs(parse_tagged(p4_cmd({cmd = '-ztag where', paths = depot_paths, allow_failure = true}))) do
        if rec.depotFile and rec.path then
            mapping[rec.depotFile] = rec.path
        end
    end
    return mapping
end

-- Batch check file revision status using a single `p4 -ztag fstat` call.
-- Returns a table mapping depot_path -> { have_rev, head_rev, unresolved, moved_file }
local function batch_check_file_status(depot_paths)
    -- p4 fstat exits non-zero if any path fails, but still outputs valid
    -- entries for the rest
    local status_map = {}
    for _, rec in ipairs(parse_tagged(p4_cmd({cmd = '-ztag fstat', paths = depot_paths, allow_failure = true}))) do
        if rec.depotFile then
            status_map[rec.depotFile] = {
                have_rev = tonumber(rec.haveRev),
                head_rev = tonumber(rec.headRev),
                unresolved = rec.unresolved ~= nil,
                -- Source of a move/add (the file that move/delete opened)
                moved_file = rec.movedFile,
            }
        end
    end
    return status_map
end

-- p4_cmd for the file commands: notifies a failure and returns nil
local function p4_or_notify(args)
    local ok, result = pcall(p4_cmd, args)
    if ok then return result end
    utils.notify_error('Perforce: ', result)
end

-- Show the first output line of a file command ("//depot/a.c#3 - opened for edit")
local function notify_output(result)
    vim.notify('Perforce: ' .. url_decode(result[1] or ''), vim.log.levels.INFO)
end

local function p4_edit()
    local result = p4_or_notify({cmd = 'edit', filepath = vim.fn.expand('%:p')})
    if result then
        notify_output(result)
        vim.bo.readonly = false
    end
end

local function p4_add()
    local file = vim.fn.expand('%:p')
    -- p4 add takes literal local names, and needs -f to accept @#%* in them
    -- (it then stores them encoded in the depot)
    local wildcards = file:find('[@#%%*]') ~= nil
    local result = p4_or_notify({cmd = wildcards and 'add -f' or 'add', filepath = file, literal = true})
    if result then
        notify_output(result)
    end
end

local function p4_revert()
    local file = vim.fn.expand('%:p')
    utils.confirm('Revert ' .. file .. '? (y/N): ', function()
        local result = p4_or_notify({cmd = 'revert', filepath = file})
        if result then
            notify_output(result)
            -- The file on disk is reverted already: drop unsaved changes too
            vim.cmd('edit!')
        end
    end)
end

local function p4_delete()
    local file = vim.fn.expand('%:p')
    utils.confirm('Delete ' .. file .. '? (y/N): ', function()
        if p4_or_notify({cmd = 'delete', filepath = file}) then
            vim.notify('Perforce: File marked for delete', vim.log.levels.INFO)
            -- p4 removed the file from disk; a buffer with unsaved changes is kept
            utils.drop_buffers_of_missing_files({ file })
        end
    end)
end

local function p4_rename()
    local filepath = vim.fn.expand('%:p')
    -- The buffer is replaced by the new path, so unsaved changes would be lost
    if vim.bo.modified then
        vim.notify('Perforce: ' .. vim.fn.fnamemodify(filepath, ':t') .. ' has unsaved changes, write it before renaming', vim.log.levels.WARN)
        return
    end
    vim.ui.input(
        { prompt = 'Move/rename to: ', default = filepath },
        function(new_path)
            if not (new_path and new_path ~= filepath) then return end
            -- First we need to edit the source file if not already opened
            if p4_or_notify({cmd = 'edit', filepath = filepath})
                and p4_or_notify({cmd = 'move', filepath = filepath, newpath = new_path}) then
                vim.notify('Perforce: File moved/renamed', vim.log.levels.INFO)
                vim.cmd('edit ' .. vim.fn.fnameescape(new_path))
                -- Drop the buffer of the old name, which is gone from disk
                utils.drop_buffers_of_missing_files({ filepath })
            end
        end)
end

-- Gvdiffsplit-like view: left = depot have, right = real file buffer
local function p4_vdiffsplit(file)
    local fstat = parse_tagged(p4_cmd({cmd = 'fstat', filepath = file}))[1] or {}
    if not fstat.depotFile then
        error(file .. ' is not in the depot', 0)
    end
    -- Left buffer content: depot #have, empty for add; a move/add's comes
    -- from its source (movedFile)
    local depot_content = {}
    if fstat.action ~= 'add' then
        depot_content = p4_cmd({
            cmd = 'print -q',
            filepath = fstat.action == 'move/add' and fstat.movedFile or fstat.depotFile,
            revision = fstat.haveRev,
        })
    end

    diffsplit.open_file_diffsplit({
        filepath = file,
        left_content = depot_content,
        left_name = fstat.depotFile .. (fstat.haveRev and ('#' .. fstat.haveRev) or ''),
        notify_message = 'Perforce diff: [ / ] jump hunks, r reverts hunk, q closes base, Q closes both',
    })
end

local function diff_current_file()
    local ok, err = pcall(p4_vdiffsplit, vim.fn.expand('%:p'))
    if not ok then
        utils.notify_error('Perforce: ', err)
    end
end

--- Get current Perforce client info (name and root)
local function get_client_info()
    local client_name, client_root
    for _, line in ipairs(p4_cmd({cmd = 'info'})) do
        if not client_name then
            client_name = line:match('^Client name:%s+(.+)$')
        end
        if not client_root then
            client_root = line:match('^Client root:%s+(.+)$')
        end
        if client_name and client_root then break end
    end

    -- Trim trailing slashes/backslashes from root (p4 may include them)
    if client_root then
        client_root = client_root:gsub('[/\\]+$', '')
    end

    return {
        name = client_name or '',
        root = client_root or '',
    }
end

local function new_changelist(description_lines)
    return { description_lines = description_lines, jobs = {}, shelved_files = {}, opened_files = {} }
end

--- Get all changelists, their descriptions, jobs, shelved files, and opened files for the current client
local function get_client_changelists(client_info)
    local file_map = {}
    local cl_numbers = {}

    -- Get all pending changelists for the current client
    -- Only depot paths are decoded, never free text such as descriptions
    -- (a literal "%25" in a description must stay as is)
    local changes_output = p4_cmd({cmd = 'changes -s pending -c ' .. vim.fn.shellescape(client_info.name)})
    for _, line in ipairs(changes_output) do
        local change_number = line:match('^Change (%d+)')
        if change_number then
            table.insert(cl_numbers, change_number)
            file_map[change_number] = new_changelist({})
        end
    end

    -- Batch describe all changelists in one call to get descriptions, jobs, and shelves
    if #cl_numbers > 0 then
        local describe_output = p4_cmd({cmd = 'describe -s -S ' .. table.concat(cl_numbers, ' ')})

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
                if in_description then
                    -- Description lines start with a tab; a blank line in
                    -- the description is a bare tab
                    local desc_line = line:match('^\t(.*)$')
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
                        table.insert(file_map[current_cl].shelved_files, url_decode(depot_path))
                    end
                end
            end
        end

        -- Set default description for changelists without one
        for _, cn in ipairs(cl_numbers) do
            local desc = file_map[cn].description_lines
            while #desc > 0 and desc[#desc]:match('^%s*$') do
                table.remove(desc)
            end
            if #desc == 0 then
                file_map[cn].description_lines = {'(no description)'}
            end
        end
    end

    -- Ensure default changelist is included
    if not file_map['default'] then
        file_map['default'] = new_changelist({'Default changelist'})
    end
    -- Search for all opened files and group by changelist
    -- Parsed before decoding: an encoded '#' (%23) in a depot path must not end the path
    local files_output = p4_cmd({cmd = 'opened'})
    local depot_paths = {}
    local files_data = {}

    -- First pass: collect depot paths and basic file info
    -- Line format: "//depot/path#rev - action change 123 (type)" or
    -- "//depot/path#rev - action default change (type)"
    for _, line in ipairs(files_output) do
        local encoded_path, action, rest = line:match('^(//[^#]+)#%S+ %- (%S+) (.*)$')
        if encoded_path then
            local depot_path = url_decode(encoded_path)
            local change_number = rest:match('^change (%d+)') or 'default'
            if not file_map[change_number] then
                -- Not listed by `p4 changes` (e.g. created meanwhile)
                file_map[change_number] = new_changelist({'(no description)'})
            end
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
        local where_path = path_mapping[file_data.depot_path] or ''
        -- p4 where may report a different drive letter than the actual client root
        -- (e.g. subst'd drives). Reconstruct local_path using the real root.
        local relative_path = where_path ~= '' and where_path:sub(#client_info.root + 2) or ''
        local local_path = relative_path ~= '' and (client_info.root .. where_path:sub(#client_info.root + 1, #client_info.root + 1) .. relative_path) or ''
        local status = status_mapping[file_data.depot_path] or {}
        local have_rev = status.have_rev
        local head_rev = status.head_rev
        table.insert(file_map[file_data.change_number].opened_files, {
            depot_path = file_data.depot_path,
            action = file_data.action,
            local_path = local_path,
            relative_path = relative_path,
            have_rev = have_rev,
            head_rev = head_rev,
            outdated = have_rev and head_rev and head_rev > have_rev,
            unresolved = status.unresolved,
            moved_file = status.moved_file,
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
local EDIT_BUFS = {}  -- changelist description edit buffers: EDIT_BUFS[cn] = buf
local cached_buf = nil

local show_window -- forward declaration for actions use

-- Changelist numbers in display order: default first, then ascending
local function sorted_changelists()
    local cns = vim.tbl_keys(CHANGELISTS)
    table.sort(cns, function(a, b)
        if a == 'default' or b == 'default' then return a == 'default' and b ~= 'default' end
        return tonumber(a) < tonumber(b)
    end)
    return cns
end

-- Identity of an INDEX_MAP entry, to find it again after a refresh, or nil
local function entry_key(data)
    if not data or data.type == 'separator' then return nil end
    if data.type == 'opened_file' then
        return 'opened_file ' .. data.opened_file.depot_path
    elseif data.type == 'shelved_file' then
        return 'shelved_file ' .. data.change_number .. ' ' .. data.shelved_file
    elseif data.type == 'job_line' then
        return 'job_line ' .. data.change_number .. ' ' .. data.job_id
    elseif data.type == 'description_line' then
        return nil    -- several lines share the same data
    end
    return data.type .. ' ' .. data.change_number
end

-- Return the INDEX_MAP entry for the line under the cursor, or nil (e.g. the
-- help line). Actions are buffer-local maps, so the current window shows it.
local function get_action_data()
    return INDEX_MAP[vim.fn.line('.')]
end

local function notify_unresolved(depot_paths)
    local count = 0
    for _, st in pairs(batch_check_file_status(depot_paths)) do
        if st.unresolved then count = count + 1 end
    end
    if count > 0 then
        vim.notify(string.format('Perforce: %d file%s need resolve (press R)', count, count ~= 1 and 's' or ''), vim.log.levels.WARN)
    end
end

-- Do the p4 work of an action, then report what failed, reload the files it
-- changed and refresh the window. work(run, errors) calls run(p4_cmd args) for
-- each command, which returns false when it failed, and may add messages of
-- its own to errors.
--   opts.local_paths:   drop the buffers of these files if they are gone from disk
--   opts.check_resolve: depot paths to report if they need a resolve afterwards
local function run_action(work, opts)
    opts = opts or {}
    local errors = {}
    work(function(args)
        local ok, err = pcall(p4_cmd, args)
        if not ok then
            table.insert(errors, vim.trim(tostring(err)))
        end
        return ok
    end, errors)
    if #errors > 0 then
        utils.notify_error('Perforce: ', table.concat(errors, '\n'))
    end
    utils.drop_buffers_of_missing_files(opts.local_paths or {})
    if opts.check_resolve then
        notify_unresolved(opts.check_resolve)
    end
    show_window()
end

-- Split items into per-changelist lists of paths, in first-seen order:
-- { { change_number = cn, paths = { path_of(item), ... } }, ... }
local function group_by_changelist(items, path_of)
    local groups, by_cn = {}, {}
    for _, item in ipairs(items) do
        local cn = item.change_number
        if not by_cn[cn] then
            by_cn[cn] = { change_number = cn, paths = {} }
            table.insert(groups, by_cn[cn])
        end
        table.insert(by_cn[cn].paths, path_of(item))
    end
    return groups
end

local function opened_depot_path(f) return f.opened_file.depot_path end
local function shelved_depot_path(s) return s.shelved_file end

-- Collect the opened files on lines start_line..end_line, without duplicates.
-- Unless only_file_lines, a Files header line stands for all files of its changelist.
-- Returns a list of { change_number, opened_file }.
local function collect_opened_files(start_line, end_line, only_file_lines)
    local files = {}
    local seen = {}
    local function add(cn, file)
        if not seen[file.depot_path] then
            seen[file.depot_path] = true
            table.insert(files, { change_number = cn, opened_file = file })
        end
    end
    for line_nr = start_line, end_line do
        local data = INDEX_MAP[line_nr]
        if data and data.type == 'files_header' and not only_file_lines then
            for _, file in ipairs(CHANGELISTS[data.change_number].opened_files) do
                add(data.change_number, file)
            end
        elseif data and data.type == 'opened_file' then
            add(data.change_number, data.opened_file)
        end
    end
    return files
end

-- Same for the shelved files: unless only_file_lines, a Shelf line stands for its whole shelf.
-- Returns a list of { change_number, shelved_file }.
local function collect_shelved_files(start_line, end_line, only_file_lines)
    local shelved = {}
    local seen = {}
    local function add(cn, depot_path)
        if not seen[cn .. ' ' .. depot_path] then
            seen[cn .. ' ' .. depot_path] = true
            table.insert(shelved, { change_number = cn, shelved_file = depot_path })
        end
    end
    for line_nr = start_line, end_line do
        local data = INDEX_MAP[line_nr]
        if data and data.type == 'shelf_toggle' and not only_file_lines then
            for _, depot_path in ipairs(CHANGELISTS[data.change_number].shelved_files) do
                add(data.change_number, depot_path)
            end
        elseif data and data.type == 'shelved_file' then
            add(data.change_number, data.shelved_file)
        end
    end
    return shelved
end

--- Edit the description of a changelist
local function edit_changelist_description(cn)
    local buf_name = 'P4-Change-' .. cn
    -- Still shown somewhere (e.g. another tab): go back to it, keeping its edits
    local existing = EDIT_BUFS[cn]
    if existing and vim.api.nvim_buf_is_valid(existing) and utils.is_buffer_displayed(existing) then
        utils.set_current_window(utils.find_window_by_buffer(existing))
        return
    end

    -- Get the change spec
    -- Not decoded: the spec goes back through `p4 change -i` unchanged, so depot
    -- paths in Files: stay encoded and descriptions are kept verbatim
    local ok, change_spec = pcall(p4_cmd, {cmd = 'change -o' .. (cn ~= 'new' and cn ~= 'default' and ' ' .. cn or '')})
    if not ok then
        utils.notify_error('Perforce: ', change_spec)
        return
    end

    -- Filter out comment lines (starting with #)
    -- For new changelists, also strip the Files: section so it creates empty
    local filtered_spec = {}
    local skip_files_section = false
    for _, line in ipairs(change_spec) do
        if line:match('^#') then
            goto continue
        end
        if cn == 'new' and line:match('^Files:') then
            skip_files_section = true
            goto continue
        end
        if skip_files_section then
            if line:match('^%S') then
                skip_files_section = false
            else
                goto continue
            end
        end
        table.insert(filtered_spec, line)
        ::continue::
    end

    -- Documentation header, then the spec
    local buffer_content = vim.list_extend({
        '# Perforce Editor',
        '#',
        '# Edit the changelist below. When done:',
        '#   w - Save changes to Perforce',
        '#   q - Discard and go back',
        '#',
    }, filtered_spec)

    -- Scratch buffer: unlisted, not a file, no swapfile. Wiped when hidden;
    -- create_scratch_buffer frees the name from a stale buffer.
    local created, buf = pcall(utils.create_scratch_buffer, buf_name, true)
    if not created then
        utils.notify_error('Perforce: ', buf)
        return
    end
    EDIT_BUFS[cn] = buf
    vim.bo[buf].bufhidden = 'wipe'
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
        -- Buffer contents without the documentation comments
        local spec_lines = vim.tbl_filter(function(line)
            return not line:match('^#')
        end, vim.api.nvim_buf_get_lines(buf, 0, -1, false))

        local saved, err = pcall(p4_cmd, {cmd = 'change -i', input = spec_lines})
        if not saved then
            utils.notify_error('Perforce: ', err)
        else
            vim.notify('Perforce: Changelist updated', vim.log.levels.INFO)
            close_edit_buffer()
        end
    end, opts)

    -- q: discard and go back
    vim.keymap.set('n', 'q', close_edit_buffer, opts)
end

--- Cursor based action handler
local function input_action()
    local data = get_action_data()
    if not data then return end

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

local function shelve_files(start_line, end_line)
    -- A single Files header line shelves the whole changelist
    local data = INDEX_MAP[start_line]
    local whole_cl = start_line == end_line and data and data.type == 'files_header'
    local files = whole_cl and { { change_number = data.change_number } } or collect_opened_files(start_line, end_line)
    if #files == 0 then return end
    for _, f in ipairs(files) do
        if f.change_number == 'default' then
            vim.notify('Perforce: Cannot shelve files in default changelist', vim.log.levels.WARN)
            return
        end
    end
    run_action(function(run)
        if whole_cl then
            run({cmd = 'shelve -f -c ' .. data.change_number})
            return
        end
        for _, group in ipairs(group_by_changelist(files, opened_depot_path)) do
            run({cmd = 'shelve -f -c ' .. group.change_number, paths = group.paths})
        end
    end)
end

local function unshelve_files(start_line, end_line)
    -- A single Shelf line unshelves the whole shelf
    local data = INDEX_MAP[start_line]
    if start_line == end_line and data and data.type == 'shelf_toggle' then
        local cn = data.change_number
        run_action(function(run)
            run({cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn})
        end, { check_resolve = CHANGELISTS[cn].shelved_files })
        return
    end
    -- Otherwise the shelved files in the range (a Shelf line stands for its whole shelf)
    local shelved = collect_shelved_files(start_line, end_line)
    if #shelved == 0 then return end
    run_action(function(run)
        for _, group in ipairs(group_by_changelist(shelved, shelved_depot_path)) do
            local cn = group.change_number
            run({cmd = 'unshelve -s ' .. cn .. ' -c ' .. cn, paths = group.paths})
        end
    end, { check_resolve = vim.tbl_map(shelved_depot_path, shelved) })
end

local function revert_files(start_line, end_line)
    -- A single Files header line reverts the whole changelist
    local data = INDEX_MAP[start_line]
    if start_line == end_line and data and data.type == 'files_header' then
        local cn = data.change_number
        utils.confirm('Revert all files in changelist ' .. cn .. '? (y/N): ', function()
            run_action(function(run)
                run({cmd = 'revert -c ' .. cn .. ' //...'})
            end)
        end)
        return
    end
    local files = collect_opened_files(start_line, end_line)
    if #files == 0 then return end
    local prompt = #files == 1
        and 'Revert ' .. files[1].opened_file.relative_path .. '? (y/N): '
        or 'Revert ' .. #files .. ' file(s)? (y/N): '
    utils.confirm(prompt, function()
        run_action(function(run)
            -- Depot paths: the local path is empty for an unmapped file
            run({cmd = 'revert', paths = vim.tbl_map(opened_depot_path, files)})
        end)
    end)
end

local function move_files(start_line, end_line)
    local files = collect_opened_files(start_line, end_line)
    if #files == 0 then return end
    local source_cls = {}
    for _, f in ipairs(files) do
        source_cls[f.change_number] = true
    end
    local cl_options = {}
    for _, cn in ipairs(sorted_changelists()) do
        if not source_cls[cn] then
            table.insert(cl_options, string.format('%s: %s', cn, CHANGELISTS[cn].description_lines[1]))
        end
    end
    vim.ui.select(cl_options,
        { prompt = 'Target changelist:', format_item = function(item) return item end },
        function(choice)
            if not choice then return end
            local target = choice:match('^([^:]+)')
            run_action(function(run)
                run({cmd = 'reopen -c ' .. target, paths = vim.tbl_map(opened_depot_path, files)})
            end)
        end
    )
end

-- What D does to an opened file. D means "I want the file gone", whatever its state:
--   'delete' - in the depot: revert, then mark for delete in the same changelist
--   'remove' - not in the depot (add, branch): revert and remove it from disk
--   'move'   - move/add: revert the move (both halves), then mark the original for delete
--   'none'   - already marked for delete
local function delete_kind(file)
    if file.action == 'delete' or file.action == 'move/delete' then
        return 'none'
    elseif file.action == 'move/add' then
        return 'move'
    elseif file.action == 'add' or file.action == 'branch' then
        return 'remove'
    end
    return 'delete'
end

-- Make the opened files (list of { change_number, opened_file }) gone, see delete_kind
local function delete_opened_files(files, run, errors)
    local reverts, removes, deletes = {}, {}, {}
    for _, f in ipairs(files) do
        local file = f.opened_file
        local kind = delete_kind(file)
        if kind == 'delete' then
            table.insert(reverts, file.depot_path)
            table.insert(deletes, { change_number = f.change_number, path = file.depot_path })
        elseif kind == 'remove' then
            table.insert(removes, file.depot_path)
        elseif kind == 'move' then
            if not file.moved_file then
                table.insert(errors, 'No move source found for ' .. file.depot_path)
            else
                table.insert(reverts, file.depot_path)
                table.insert(deletes, { change_number = f.change_number, path = file.moved_file })
            end
        end
    end
    run({cmd = 'revert', paths = reverts})
    run({cmd = 'revert -w', paths = removes})
    -- Even when a revert failed: p4 refuses to delete a file that is still opened
    for _, group in ipairs(group_by_changelist(deletes, function(d) return d.path end)) do
        local cn = group.change_number
        run({cmd = 'delete' .. (cn ~= 'default' and ' -c ' .. cn or ''), paths = group.paths})
    end
end

-- Confirmation prompt for D on opened and shelved files
local function delete_prompt(opened, shelved)
    if #opened + #shelved == 1 then
        if #shelved == 1 then
            return 'Delete ' .. shelved[1].shelved_file .. '? (y/N): '
        end
        local file = opened[1].opened_file
        local kind = delete_kind(file)
        if kind == 'remove' then
            return 'Remove ' .. file.relative_path .. ' from disk (opened for ' .. file.action .. ')? (y/N): '
        elseif kind == 'move' then
            return 'Undo move to ' .. file.relative_path .. ' and mark ' .. (file.moved_file or 'its source')
                .. ' for delete (discards local changes)? (y/N): '
        end
        return 'Mark ' .. file.relative_path .. ' for delete (discards local changes)? (y/N): '
    end
    local counts = { delete = 0, remove = 0, move = 0 }
    for _, f in ipairs(opened) do
        local kind = delete_kind(f.opened_file)
        counts[kind] = counts[kind] + 1
    end
    local parts = {}
    if counts.delete > 0 then table.insert(parts, 'mark ' .. counts.delete .. ' file(s) for delete') end
    if counts.remove > 0 then table.insert(parts, 'remove ' .. counts.remove .. ' added file(s) from disk') end
    if counts.move > 0 then table.insert(parts, 'undo ' .. counts.move .. ' move(s) and delete the originals') end
    if #shelved > 0 then table.insert(parts, 'delete ' .. #shelved .. ' shelved file(s)') end
    local prompt = table.concat(parts, ', ')
    prompt = prompt:sub(1, 1):upper() .. prompt:sub(2)
    if #opened > 0 then
        prompt = prompt .. ' (discards local changes)'
    end
    return prompt .. '? (y/N): '
end

local function delete_stuff(start_line, end_line)
    local data = INDEX_MAP[start_line]

    -- Single-line special cases
    if start_line == end_line and data then
        local cn = data.change_number
        if data.type == 'changelist' then
            if cn == 'default' then
                vim.notify('Perforce: Cannot delete the default changelist', vim.log.levels.WARN)
                return
            end
            local cl = CHANGELISTS[cn]
            utils.confirm('Delete changelist ' .. cn .. ' and all its files? (y/N): ', function()
                run_action(function(run)
                    -- Stop at the first failure: e.g. don't delete the shelf
                    -- when the changelist itself can't be deleted
                    if #cl.opened_files > 0 and not run({cmd = 'revert -c ' .. cn .. ' //...'}) then return end
                    if #cl.shelved_files > 0 and not run({cmd = 'shelve -d -c ' .. cn}) then return end
                    for _, job in ipairs(cl.jobs) do
                        if not run({cmd = 'fix -d -c ' .. cn .. ' ' .. job.id}) then return end
                    end
                    run({cmd = 'change -d ' .. cn})
                end)
            end)
            return
        end
        if data.type == 'shelf_toggle' then
            utils.confirm('Delete all shelved files in changelist ' .. cn .. '? (y/N): ', function()
                run_action(function(run)
                    run({cmd = 'shelve -d -c ' .. cn})
                end)
            end)
            return
        end
    end

    -- General case: the opened and shelved file lines in the range
    local opened = {}
    local already_deleted = 0
    for _, f in ipairs(collect_opened_files(start_line, end_line, true)) do
        if delete_kind(f.opened_file) == 'none' then
            already_deleted = already_deleted + 1
        else
            table.insert(opened, f)
        end
    end
    local shelved = collect_shelved_files(start_line, end_line, true)
    if already_deleted > 0 then
        vim.notify(string.format('Perforce: %d file%s already marked for delete', already_deleted, already_deleted ~= 1 and 's' or ''), vim.log.levels.INFO)
    end
    if #opened + #shelved == 0 then return end
    utils.confirm(delete_prompt(opened, shelved), function()
        run_action(function(run, errors)
            for _, group in ipairs(group_by_changelist(shelved, shelved_depot_path)) do
                run({cmd = 'shelve -d -c ' .. group.change_number, paths = group.paths})
            end
            delete_opened_files(opened, run, errors)
        end, { local_paths = vim.tbl_map(function(f) return f.opened_file.local_path end, opened) })
    end)
end

local function show_diff()
    local data = get_action_data()

    if data and data.type == 'opened_file' then
        vim.schedule(function()
            local ok, err = pcall(p4_vdiffsplit, data.opened_file.local_path)
            if not ok then
                utils.notify_error('Perforce: ', err)
            end
        end)
    end
end

local function sync_files(start_line, end_line)
    local depot_paths = vim.tbl_map(opened_depot_path, collect_opened_files(start_line, end_line))
    if #depot_paths == 0 then return end
    run_action(function(run)
        run({cmd = 'sync', paths = depot_paths})
    end, { check_resolve = depot_paths })
end

local CONFLICT_MARKERS = {
    -- pattern, highlight, section the lines below belong to
    { '^<<<<<<< LOCAL', 'DiagnosticInfo', 'local' },
    { '^||||||| ORIGINAL', 'DiagnosticError', 'original' },
    { '^=======', 'DiagnosticWarn', 'incoming' },
    { '^>>>>>>> INCOMING', 'DiagnosticWarn', nil },
}
local CONFLICT_SECTION_HL = { ['local'] = 'DiffAdd', original = 'DiffDelete', incoming = 'DiffChange' }

local function conflict_marker(line)
    for _, marker in ipairs(CONFLICT_MARKERS) do
        if line:match(marker[1]) then return marker end
    end
end

-- Open the file with diff3 conflict markers (yours / base / theirs) for a manual merge
local function merge_resolve(file)
    -- The merge replaces the buffer content, so unsaved changes would be lost
    local existing = utils.find_buffer_by_path(file.local_path)
    if existing and vim.bo[existing].modified then
        vim.notify('Perforce: ' .. file.relative_path .. ' has unsaved changes, write it before merging', vim.log.levels.WARN)
        return
    end
    if vim.fn.executable('diff3') ~= 1 then
        vim.notify('Perforce: diff3 not found on PATH, it is needed to merge', vim.log.levels.ERROR)
        return
    end

    -- Use fstat to get the exact resolve versions p4 recorded.
    -- After `p4 sync`, haveRev is already bumped to the new head, so
    -- using file.have_rev as the base would be the same rev as theirs
    -- and diff3 would mark every local line as a conflict.
    -- fstat exposes (index N varies by resolve type):
    --   resolveBaseFileN / resolveBaseRevN  → common ancestor (ORIGINAL)
    --   resolveFromFileN / resolveEndFromRevN → incoming version (THEIRS)
    local ok, fstat_out = pcall(p4_cmd, {cmd = '-ztag fstat -Or', filepath = file.local_path})
    if not ok then
        utils.notify_error('Perforce: fstat -Or failed: ', fstat_out)
        return
    end
    local rec = parse_tagged(fstat_out)[1] or {}
    local base_file, base_rev, from_file, from_rev
    -- Find the first content resolve record (skip filetype resolves)
    for field, resolve_type in pairs(rec) do
        local n = field:match('^resolveType(%d+)$')
        if n and resolve_type == 'content' then
            base_file = rec['resolveBaseFile' .. n]
            -- base_rev can be "none" when there is no common ancestor (e.g. new file)
            base_rev = rec['resolveBaseRev' .. n]
            from_file = rec['resolveFromFile' .. n]
            -- Fallback: some resolve types only have resolveStartFromRev
            from_rev = rec['resolveEndFromRev' .. n] or rec['resolveStartFromRev' .. n]
            if base_file and base_rev and from_file and from_rev then break end
        end
    end
    if not (base_file and base_rev and from_file and from_rev) then
        -- Dump resolve-related fstat fields for debugging
        local resolve_lines = vim.tbl_filter(function(line) return line:match('resolve') ~= nil end, fstat_out)
        local diag = #resolve_lines > 0
            and 'Resolve fields:\n' .. table.concat(resolve_lines, '\n')
            or 'No resolve fields found in fstat output'
        vim.notify('Perforce: Could not get resolve versions from fstat.\n' .. diag, vim.log.levels.ERROR)
        return
    end

    -- Get the three versions for diff3:
    --   yours  = current file on disk (your local edits)
    --   base   = common ancestor (what you originally synced from)
    --   theirs = incoming version (what was just synced/unshelved)
    local tmp_theirs = vim.fn.tempname()
    local tmp_base   = vim.fn.tempname()
    local errors = {}
    local function print_to(tmp, depot_path, rev)
        local printed, err = pcall(p4_cmd, {cmd = 'print -q -o ' .. vim.fn.shellescape(tmp), filepath = depot_path, revision = rev})
        if not printed then table.insert(errors, vim.trim(err)) end
    end
    print_to(tmp_theirs, from_file, from_rev)
    if base_rev == 'none' then
        -- No common ancestor (new file) — use empty base for diff3
        vim.fn.writefile({}, tmp_base)
    else
        print_to(tmp_base, base_file, base_rev)
    end

    -- Run diff3 to produce merged content with conflict markers.
    -- It exits with 0 (no conflicts), 1 (conflicts) or 2 (trouble).
    local result
    if #errors == 0 then
        result = vim.system({
            'diff3', '-m',
            '--label', 'LOCAL', file.local_path,
            '--label', 'ORIGINAL', tmp_base,
            '--label', 'INCOMING', tmp_theirs,
        }, { text = true }):wait()
        if result.code ~= 0 and result.code ~= 1 then
            table.insert(errors, 'diff3 failed: ' .. vim.trim((result.stderr or '') .. ' ' .. (result.stdout or '')))
        end
    end
    os.remove(tmp_theirs)
    os.remove(tmp_base)
    -- Nothing is touched when a step failed
    if #errors > 0 then
        vim.notify('Perforce: merge of ' .. file.relative_path .. ' aborted:\n' .. table.concat(errors, '\n'), vim.log.levels.ERROR)
        return
    end
    local merged = vim.split(result.stdout or '', '\n', { plain = true })
    if merged[#merged] == '' then table.remove(merged) end

    -- Open the file and replace content with merged result (don't save yet)
    local edit_ok, edit_err = pcall(vim.cmd, 'edit ' .. vim.fn.fnameescape(file.local_path))
    if not edit_ok then
        utils.notify_error('Perforce: ', edit_err)
        return
    end
    local buf = vim.api.nvim_get_current_buf()
    vim.api.nvim_buf_set_lines(buf, 0, -1, false, merged)

    -- Highlight conflict markers, and the lines of each side
    local ns = vim.api.nvim_create_namespace('P4ConflictMarkers')
    local function apply_conflict_highlights()
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
        local section
        for i, l in ipairs(vim.api.nvim_buf_get_lines(buf, 0, -1, false)) do
            local marker = conflict_marker(l)
            local hl_group
            if marker then
                hl_group, section = marker[2], marker[3]
            else
                hl_group = CONFLICT_SECTION_HL[section]
            end
            if hl_group then
                vim.api.nvim_buf_add_highlight(buf, ns, hl_group, i - 1, 0, #l)
            end
        end
    end
    apply_conflict_highlights()

    -- Re-apply highlights when buffer changes. The group is deleted when the
    -- merge ends (q / Esc), so later edits of the file are never auto-saved.
    local group = vim.api.nvim_create_augroup('P4Resolve' .. buf, { clear = true })
    local function cleanup_resolve()
        for _, key in ipairs({ ']', '[', 'q', '<Esc>' }) do
            pcall(vim.keymap.del, 'n', key, { buffer = buf })
        end
        pcall(vim.api.nvim_del_augroup_by_id, group)
        vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
    end
    vim.api.nvim_create_autocmd({'TextChanged', 'TextChangedI'}, {
        group = group,
        buffer = buf,
        callback = function()
            local content = table.concat(vim.api.nvim_buf_get_lines(buf, 0, -1, false), '\n')
            if not content:match('<<<<<<< LOCAL') then
                vim.api.nvim_buf_clear_namespace(buf, ns, 0, -1)
                -- All conflicts resolved — auto-save, press q to accept and return
                vim.cmd('write')
                vim.notify('Perforce: All conflicts resolved — press q to accept and return', vim.log.levels.INFO)
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
            vim.notify('Perforce: Conflict markers still present — resolve all conflicts first', vim.log.levels.WARN)
            return
        end
        cleanup_resolve()
        vim.cmd('write')
        run_action(function(run)
            run({cmd = 'resolve -ay', filepath = file.depot_path})
        end)
    end, map_opts)

    -- Esc: cancel — reload original file, nothing changes in p4
    vim.keymap.set('n', '<Esc>', function()
        cleanup_resolve()
        vim.cmd('edit!')
        show_window()
    end, map_opts)

    vim.schedule(function()
        vim.notify('Perforce resolve: [ / ] jump conflicts | q save and return | Esc cancel', vim.log.levels.INFO)
    end)

    -- Jump to first conflict
    vim.fn.cursor(1, 1)
    vim.fn.search('<<<<<<< LOCAL', 'W')
end

local function resolve_files()
    local data = get_action_data()

    if not (data and data.type == 'opened_file') then return end

    local file = data.opened_file

    -- Try auto-merge first — if it works, no user decision needed
    local unresolved = false
    run_action(function(run, errors)
        if not run({cmd = 'resolve -am', filepath = file.depot_path}) then return end
        -- Check if still unresolved (auto-merge failed or had conflicts)
        local st = batch_check_file_status({file.depot_path})[file.depot_path]
        if not st then
            table.insert(errors, 'Could not check the resolve status of ' .. file.relative_path)
        elseif st.unresolved then
            unresolved = true
        else
            vim.notify('Perforce: Auto-merged ' .. file.relative_path, vim.log.levels.INFO)
        end
    end)
    if not unresolved then return end

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
        if choice:match('^Merge') then
            merge_resolve(file)
            return
        end
        local accept = choice:match('^Accept theirs') and '-at' or '-ay'
        run_action(function(run)
            run({cmd = 'resolve ' .. accept, filepath = file.depot_path})
        end)
    end)
end

local function resolve_files_range(start_line, end_line)
    local depot_paths = vim.tbl_map(opened_depot_path, collect_opened_files(start_line, end_line))
    if #depot_paths == 0 then return end
    run_action(function(run)
        run({cmd = 'resolve -am', paths = depot_paths})
    end)
end

-- ===========================================================================
-- PERFORCE WINDOW
-- ===========================================================================

local function setup_keymaps(buf)
    local opts = { buffer = buf, nowait = true, noremap = true, silent = true }
    vim.keymap.set('n', 'q', function()
        local win = utils.find_window_by_buffer(buf)
        utils.dismiss_buffer_window(win, buf)
        cached_buf = nil
    end, opts)
    vim.keymap.set('n', '<CR>', input_action, opts)
    vim.keymap.set('n', 'd', show_diff, opts)
    vim.keymap.set('n', 'R', resolve_files, opts)
    vim.keymap.set('n', 'n', function() edit_changelist_description('new') end, opts)

    local function normal(fn)
        return function()
            local line = vim.fn.line('.')
            fn(line, line)
        end
    end
    vim.keymap.set('n', 'r', normal(revert_files), opts)
    vim.keymap.set('n', 'm', normal(move_files), opts)
    vim.keymap.set('n', 's', normal(shelve_files), opts)
    vim.keymap.set('n', 'u', normal(unshelve_files), opts)
    vim.keymap.set('n', 'D', normal(delete_stuff), opts)
    vim.keymap.set('n', 'S', normal(sync_files), opts)
    local function visual(fn)
        return function()
            local start_line = vim.fn.line('v')
            local end_line = vim.fn.line('.')
            if start_line > end_line then start_line, end_line = end_line, start_line end
            vim.api.nvim_feedkeys(vim.api.nvim_replace_termcodes('<Esc>', true, false, true), 'nx', false)
            fn(start_line, end_line)
        end
    end
    vim.keymap.set('v', 'r', visual(revert_files), opts)
    vim.keymap.set('v', 'm', visual(move_files), opts)
    vim.keymap.set('v', 's', visual(shelve_files), opts)
    vim.keymap.set('v', 'u', visual(unshelve_files), opts)
    vim.keymap.set('v', 'D', visual(delete_stuff), opts)
    vim.keymap.set('v', 'S', visual(sync_files), opts)
    vim.keymap.set('v', 'R', visual(resolve_files_range), opts)
end

local function setup_display_lines()
    INDEX_MAP = {}
    local lines = {}
    for _, cn in ipairs(sorted_changelists()) do
        local content = CHANGELISTS[cn]
        -- CL header line
        table.insert(lines, string.format('CL %s :', cn))
        table.insert(INDEX_MAP, { type = 'changelist', change_number = cn })

        -- All description lines indented
        for _, desc_line in ipairs(content.description_lines) do
            table.insert(lines, string.format('  %s', desc_line))
            table.insert(INDEX_MAP, { type = 'description_line', change_number = cn })
        end

        -- Jobs section (if available)
        if #content.jobs > 0 then
            table.insert(lines, '')
            table.insert(INDEX_MAP, { type = 'separator' })
            table.insert(lines, '  Jobs')
            table.insert(INDEX_MAP, { type = 'jobs_header', change_number = cn })
            for _, job in ipairs(content.jobs) do
                table.insert(lines, string.format('    (%s) %s', job.id, job.description or ''))
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

    -- Help lines
    table.insert(lines, '[Enter=open/edit/toggle | d=diff | r=revert | m=move | s=shelve | u=unshelve | D=delete | S=sync | R=resolve | n=new CL ]')

    return lines
end

-- Highlight of the action of an opened file
local ACTION_HL = {
    edit = 'DiffChange',
    add = 'DiffAdd',
    delete = 'DiffDelete',
    ['move/add'] = 'DiffText',
    ['move/delete'] = 'DiffText',
}

local function apply_syntax_highlighting(buf)
    -- Clear existing highlights
    vim.api.nvim_buf_clear_namespace(buf, -1, 0, -1)

    local ns_id = vim.api.nvim_create_namespace('P4Highlight')
    local lines = vim.api.nvim_buf_get_lines(buf, 0, -1, false)

    -- What a line is comes from INDEX_MAP, not from its text: descriptions
    -- can contain anything, and the arrows/markers are multibyte
    for i, line in ipairs(lines) do
        local line_idx = i - 1
        local data = INDEX_MAP[i]
        local kind = data and data.type

        -- CL header lines
        if kind == 'changelist' then
            -- Highlight entire CL header line
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Title', line_idx, 0, #line)

        -- Description lines (indented with 2 spaces)
        elseif kind == 'description_line' then
            -- A CR: or RB: tag gets special highlighting
            local tag_start = line:find('CR:', 1, true) or line:find('RB:', 1, true)
            if tag_start then
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, tag_start - 1, tag_start + 2)
            else
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
            end

        -- Jobs header
        elseif kind == 'jobs_header' then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, #line)

        -- Job lines: highlight the job ID in parentheses ("    (id) description")
        elseif kind == 'job_line' then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Number', line_idx, 4, 4 + #data.job_id + 2)

        -- Files header
        elseif kind == 'files_header' then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, 0, 7)
            -- Highlight count
            local count_start = line:find('%(')
            local count_end = line:find('%)')
            if count_start and count_end then
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Number', line_idx, count_start - 1, count_end)
            end

        -- Shelf toggle lines ("  ▶ Shelf (N files)", the arrow is 3 bytes)
        elseif kind == 'shelf_toggle' then
            local shelf_start = line:find('Shelf', 1, true)
            local paren_start = line:find('(', 1, true)
            if shelf_start and paren_start then
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Special', line_idx, 0, shelf_start - 1)
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'Keyword', line_idx, shelf_start - 1, paren_start - 1)
            end

        -- File action lines ("    action        marker path")
        elseif kind == 'opened_file' then
            local file_entry = data.opened_file
            local action = file_entry.action or ''
            vim.api.nvim_buf_add_highlight(buf, ns_id, ACTION_HL[action] or 'Identifier', line_idx, 4, 4 + #action)

            -- A status marker ('✘' unresolved in red, '↑' outdated in yellow: 3
            -- bytes at offset 18) colors the path too
            local marker_hl = (file_entry.unresolved and 'DiagnosticError') or (file_entry.outdated and 'WarningMsg')
            if marker_hl then
                vim.api.nvim_buf_add_highlight(buf, ns_id, marker_hl, line_idx, 18, 21)
                vim.api.nvim_buf_add_highlight(buf, ns_id, marker_hl, line_idx, 22, #line)
            else
                -- Normal: path starts at offset 20 (after 2 spaces)
                vim.api.nvim_buf_add_highlight(buf, ns_id, 'String', line_idx, 20, #line)
            end

        -- Shelved file lines (indented with 4 spaces, depot paths)
        elseif kind == 'shelved_file' then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Directory', line_idx, 0, #line)

        -- Help line (the only line without an INDEX_MAP entry)
        elseif not data and line:match('^%[.*%]$') then
            vim.api.nvim_buf_add_highlight(buf, ns_id, 'Comment', line_idx, 0, #line)
        end
    end
end


show_window = function()
    -- Query Perforce before touching any buffers or windows, so a failure (no
    -- server, not inside a client workspace) leaves the editor untouched.
    local ok, result = pcall(function()
        local info = get_client_info()
        if info.root == '' then
            error('not inside a Perforce client workspace (p4 info reports no client root)', 0)
        end
        return get_client_changelists(info)
    end)
    if not ok then
        utils.notify_error('Perforce: ', result)
        return
    end
    CHANGELISTS = result

    local buf_ok, buffer, created = pcall(utils.get_or_create_scratch_buffer, BUFFER_NAME, cached_buf, false)
    if not buf_ok then
        utils.notify_error('Perforce: ', buffer)
        return
    end
    cached_buf = buffer
    if created then
        setup_keymaps(buffer)
    end

    local saved_cursor_pos = nil
    local saved_key = nil    -- entry under the cursor, found again after the rebuild
    local win = utils.find_window_by_buffer(buffer)
    if win then
        saved_cursor_pos = utils.get_cursor_position(win)
        saved_key = entry_key(INDEX_MAP[saved_cursor_pos.line])
    end

    -- Take over as main window
    local target_win = utils.close_other_windows()

    -- Build lines and index map
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
    -- Restore cursor position if we had one saved: on the same entry if it is
    -- still there (lines above it may have changed), else on the same line
    if saved_cursor_pos then
        local line = saved_cursor_pos.line
        if saved_key then
            for i, data in ipairs(INDEX_MAP) do
                if entry_key(data) == saved_key then
                    line = i
                    break
                end
            end
        end
        pcall(utils.set_cursor_position, target_win, line, saved_cursor_pos.column)
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
vim.api.nvim_create_user_command('P4Diff', diff_current_file, { desc = 'P4: Diff current file' })

-- Keymaps
vim.keymap.set('n', '<leader>ps', show_window, { desc = 'P4: Show opened files' })
vim.keymap.set('n', '<leader>pe', p4_edit, { desc = 'P4: Edit current file' })
vim.keymap.set('n', '<leader>pa', p4_add, { desc = 'P4: Add current file' })
vim.keymap.set('n', '<leader>pr', p4_revert, { desc = 'P4: Revert current file' })
vim.keymap.set('n', '<leader>pD', p4_delete, { desc = 'P4: Delete current file' })
vim.keymap.set('n', '<leader>pR', p4_rename, { desc = 'P4: Rename/move current file' })
vim.keymap.set('n', '<leader>pd', diff_current_file, { desc = 'P4: Diff current file' })
