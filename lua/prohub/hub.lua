---The hub: one row per worktree of a project or of a workset, in a scratch
---buffer of its own tabpage.
---
---A hub is identified by a key, so opening it again reuses its tabpage and its
---buffer. In a git project the key is the path of the first worktree the hub
---shows, which is the main worktree unless the project has a bare layout, so
---every worktree of the project finds the same hub. Outside a git project the
---key is the key of the workset that holds the directory the hub is opened
---from.
---
---A render reads the worktrees and then the status of each of them, and it
---only writes the buffer once every collection has answered. Nothing in the
---editor changes before that last step, so a slow git command never leaves a
---half written hub behind.
---
---A row shows a name, the path of its worktree and the counts of its status:
---
---    name  path  s u ?  a b  c  p
---
---The name is the branch of the worktree, or the short commit when HEAD is
---detached. The path is the last part of the worktree path, with the
---directory that holds it where two worktrees share that last part. `s`, `u`
---and `?` are the staged, unstaged and untracked entries, `a` and `b` the
---commits ahead of and behind the default branch, `c` the files that differ
---from the base, and `p` the unpushed commits, which a row only shows when its
---status has them. A count that does not apply is a dash, a row without a base
---ends with the reason why, and a worktree git reports as missing is dimmed
---and ends with `missing`.
---
---    local hub = require('prohub.hub')
---
---    local ok, err = hub.open({ cwd = path })
---
---The keys of a hub are buffer-local mappings from the options, and they live
---in `prohub.hub.keymaps`: the hub hands that module the worktree of the row
---under the cursor, a refresh and a close.
---@class prohub.hub
local M = {}

local config = require('prohub.config')
local keymaps = require('prohub.hub.keymaps')
local log = require('prohub.log')
local paths = require('prohub.path')
local status = require('prohub.status')
local validate = require('prohub.validate')
local workset = require('prohub.workset')

---The prefix of the name of the buffer of a hub.
---@type string
local prefix = 'prohub://'

---The tab variable that marks the tabpage of a hub, which is the whole
---contract between the hub and `prohub.review`.
---@type string
local hub_variable = 'prohub_hub'

---The highlight group of the row of a worktree that is missing.
---@type string
local missing = 'ProhubMissing'

---The counts of a row, in the order the row writes them.
---@type string[]
local count_columns = {
    'staged',
    'unstaged',
    'untracked',
    'ahead',
    'behind',
    'changed',
    'unpushed',
}

---The label of each count in the header of the buffer.
---@type table<string, string>
local count_labels = {
    staged = 's',
    unstaged = 'u',
    untracked = '?',
    ahead = 'a',
    behind = 'b',
    changed = 'c',
    unpushed = 'p',
}

---The namespace of the highlights of the hub buffers.
local namespace = vim.api.nvim_create_namespace('prohub_hub')

---The status of one worktree as its row shows it: the collected status, or
---the error that kept the collection from finishing.
---@class prohub.hub.Collection
---@field status prohub.Status?
---@field err string?

---The counts of one row. `unpushed` is missing when the status has none.
---@class prohub.hub.Counts
---@field staged string
---@field unstaged string
---@field untracked string
---@field ahead string
---@field behind string
---@field changed string
---@field unpushed string?

---The cells of one row.
---@class prohub.hub.Cells
---@field name string
---@field path string
---@field counts prohub.hub.Counts
---@field note string?

---One row that carries a highlight group.
---@class prohub.hub.Highlight
---@field line integer Line number of the row.
---@field group string Highlight group of the row.

---An open hub.
---@class prohub.hub.Hub
---@field key string Identity of the hub.
---@field buffer integer The buffer that holds the rows.
---@field tabpage integer The tabpage the hub lives in.
---@field paths table<integer, string> The worktree of each line of the buffer.
---@field missing? table<string, true> The worktrees git reports as missing.
---@field worktrees? prohub.Worktree[] The worktrees the last render listed.
---@field dir? string The directory the hub was opened from.
---@field mapped? boolean Whether the keys of the hub are on its buffer.

---The open hubs, by key.
---@type table<string, prohub.hub.Hub>
local hubs = {}

---Whether the highlight groups of the hub are defined already.
---@type boolean
local highlighted = false

---The number of screen cells a string occupies.
---@param value string
---@return integer
local function width_of(value)
    return vim.api.nvim_strwidth(value)
end

---Pad a cell on the right, so a column of left aligned cells lines up.
---@param value string
---@param width integer
---@return string
local function pad_right(value, width)
    return value .. string.rep(' ', math.max(0, width - width_of(value)))
end

---Pad a cell on the left, so a column of right aligned cells lines up.
---@param value string
---@param width integer
---@return string
local function pad_left(value, width)
    return string.rep(' ', math.max(0, width - width_of(value))) .. value
end

---Write a message on a single line, so every row keeps exactly one line and
---the line of a worktree stays known.
---@param message string
---@return string
local function one_line(message)
    return (vim.trim((message:gsub('%s+', ' '))))
end

---The last part of each worktree path, with the directory that holds it where
---that is not enough to tell two worktrees apart.
---@param worktrees prohub.Worktree[]
---@return table<integer, string>
local function short_paths(worktrees)
    local counts = {}
    for _, record in ipairs(worktrees) do
        local name = vim.fs.basename(record.path)
        counts[name] = (counts[name] or 0) + 1
    end

    local result = {}
    for index, record in ipairs(worktrees) do
        local name = vim.fs.basename(record.path)
        if counts[name] > 1 then
            local directory = vim.fs.basename(vim.fs.dirname(record.path))
            name = vim.fs.joinpath(directory, name)
        end
        result[index] = name
    end
    return result
end

---A count a row shows: the number, or the dash that says it does not apply.
---@param value integer?
---@return string
local function count_of(value)
    if value == nil then
        return '-'
    end
    return tostring(value)
end

---The name a row starts with: the branch, or the short commit of a detached
---HEAD.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@return string
local function name_of(record, collection)
    if record.branch then
        return record.branch
    end
    if record.detached then
        return record.detached
    end

    local collected = collection and collection.status
    if collected and collected.head then
        return collected.head
    end
    return '-'
end

---The note a row ends with, when it has one.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@return string?
local function note_of(record, collection)
    if record.missing then
        return 'missing'
    end
    if collection and collection.err then
        return 'error: ' .. one_line(collection.err)
    end
    if collection and collection.status then
        return collection.status.reason
    end
end

---The cells of the row of one worktree.
---@param record prohub.Worktree
---@param collection prohub.hub.Collection?
---@param path string Short path of the worktree.
---@return prohub.hub.Cells
local function cells_of(record, collection, path)
    local collected = collection and collection.status
    local unpushed
    if collected and collected.unpushed then
        unpushed = tostring(collected.unpushed)
    end

    return {
        name = name_of(record, collection),
        path = path,
        counts = {
            staged = count_of(collected and collected.staged),
            unstaged = count_of(collected and collected.unstaged),
            untracked = count_of(collected and collected.untracked),
            ahead = count_of(collected and collected.ahead),
            behind = count_of(collected and collected.behind),
            changed = count_of(collected and collected.changed),
            unpushed = unpushed,
        },
        note = note_of(record, collection),
    }
end

---The header of the rows, which also names every count.
---@return prohub.hub.Cells
local function header_cells()
    local counts = {}
    for _, column in ipairs(count_columns) do
        counts[column] = count_labels[column]
    end
    return { name = 'name', path = 'path', counts = counts }
end

---The width of each column, wide enough for its label and every value.
---@param rows prohub.hub.Cells[]
---@param header prohub.hub.Cells
---@return table<string, integer>
local function widths_of(rows, header)
    local widths = {
        name = width_of(header.name),
        path = width_of(header.path),
    }
    for _, column in ipairs(count_columns) do
        widths[column] = width_of(header.counts[column])
    end

    for _, cells in ipairs(rows) do
        widths.name = math.max(widths.name, width_of(cells.name))
        widths.path = math.max(widths.path, width_of(cells.path))
        for _, column in ipairs(count_columns) do
            local value = cells.counts[column]
            if value then
                widths[column] = math.max(widths[column], width_of(value))
            end
        end
    end
    return widths
end

---Write the cells of one row as one line. A count a row does not have is left
---out, so no line ends with padding.
---@param cells prohub.hub.Cells
---@param widths table<string, integer>
---@return string
local function line_of(cells, widths)
    local counts = cells.counts
    local changes = table.concat({
        pad_left(counts.staged, widths.staged),
        pad_left(counts.unstaged, widths.unstaged),
        pad_left(counts.untracked, widths.untracked),
    }, ' ')
    local commits = table.concat({
        pad_left(counts.ahead, widths.ahead),
        pad_left(counts.behind, widths.behind),
    }, ' ')

    local parts = {
        pad_right(cells.name, widths.name),
        pad_right(cells.path, widths.path),
        changes,
        commits,
        pad_left(counts.changed, widths.changed),
    }
    if counts.unpushed then
        table.insert(parts, pad_left(counts.unpushed, widths.unpushed))
    end
    if cells.note then
        table.insert(parts, cells.note)
    end
    return table.concat(parts, '  ')
end

---Turn the worktrees and their collected status into the lines of the buffer,
---the highlights of its rows and the worktree of every line. It only reads its
---arguments, so a render is computed before anything in the editor changes.
---@param worktrees prohub.Worktree[]
---@param collections table<string, prohub.hub.Collection>
---@return string[] lines
---@return prohub.hub.Highlight[] highlights
---@return table<integer, string> paths
---@return table<string, true> absent
local function build(worktrees, collections)
    if #worktrees == 0 then
        return {}, {}, {}, {}
    end

    local header = header_cells()
    local short = short_paths(worktrees)
    local rows = {}
    for index, record in ipairs(worktrees) do
        rows[index] = cells_of(record, collections[record.path], short[index])
    end

    local widths = widths_of(rows, header)
    local lines = { line_of(header, widths) }
    local highlights = {}
    local paths = {}
    local absent = {}
    for index, record in ipairs(worktrees) do
        local line = index + 1
        lines[line] = line_of(rows[index], widths)
        paths[line] = record.path
        if record.missing then
            absent[record.path] = true
            table.insert(highlights, { line = line, group = missing })
        end
    end
    return lines, highlights, paths, absent
end

---Define the highlight groups of the hub, unless the user already set them.
local function define_highlights()
    if highlighted then
        return
    end
    highlighted = true
    vim.api.nvim_set_hl(0, missing, { link = 'Comment', default = true })
end

---The buffer of a hub: the one that already carries its name, so a hub that
---was closed and opened again finds its buffer back, or a new one. Neither is
---shown.
---@param key string
---@return integer
local function new_buffer(key)
    local name = prefix .. key
    for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
        if
            vim.api.nvim_buf_is_valid(buffer)
            and vim.api.nvim_buf_get_name(buffer) == name
        then
            return buffer
        end
    end

    local buffer = vim.api.nvim_create_buf(false, true)
    local named, err = pcall(vim.api.nvim_buf_set_name, buffer, name)
    if not named then
        log.warn('the hub buffer could not be named: %s', tostring(err))
    end

    for option, value in pairs({
        buftype = 'nofile',
        bufhidden = 'hide',
        swapfile = false,
        buflisted = false,
        modifiable = false,
        filetype = 'prohub',
    }) do
        vim.api.nvim_set_option_value(option, value, { buf = buffer })
    end
    return buffer
end

---Open a tabpage that shows a hub buffer and make it current.
---@param buffer integer
---@param key string
---@return integer
local function new_tab(buffer, key)
    vim.cmd('tabnew')
    local win = vim.api.nvim_get_current_win()
    local empty = vim.api.nvim_win_get_buf(win)
    vim.api.nvim_win_set_buf(win, buffer)
    if empty ~= buffer then
        pcall(vim.api.nvim_buf_delete, empty, { force = true })
    end

    local tabpage = vim.api.nvim_get_current_tabpage()
    vim.t[tabpage][hub_variable] = true

    if vim.fn.isdirectory(key) == 1 then
        local changed, err = pcall(vim.cmd, 'tcd ' .. vim.fn.fnameescape(key))
        if not changed then
            log.warn('the directory of the hub could not be set: %s', err)
        end
    end

    return tabpage
end

---The worktree of the line the cursor of a hub is on, when it still is one,
---and whether git reports that worktree as missing.
---@param hub prohub.hub.Hub
---@return string? path
---@return boolean missing
local function cursor_row(hub)
    if not vim.api.nvim_buf_is_valid(hub.buffer) then
        return nil, false
    end
    if not hub.tabpage or not vim.api.nvim_tabpage_is_valid(hub.tabpage) then
        return nil, false
    end

    local win = vim.api.nvim_tabpage_get_win(hub.tabpage)
    if vim.api.nvim_win_get_buf(win) ~= hub.buffer then
        return nil, false
    end

    local path = hub.paths[vim.api.nvim_win_get_cursor(win)[1]]
    if not path then
        return nil, false
    end
    return path, hub.missing ~= nil and hub.missing[path] == true
end

---Collect the status of every worktree of a hub again and render the hub, so
---the rows show what the worktrees hold now. The hub is rendered again through
---the same path an open takes, so a worktree added since the last render shows
---up too.
---@param hub prohub.hub.Hub
---@return true|nil ok
---@return string? err
local function refresh(hub)
    if not hub.dir then
        return nil, 'prohub: the hub has no directory to render again'
    end

    for _, record in ipairs(hub.worktrees or {}) do
        status.invalidate(record.path)
    end
    return M.open({ cwd = hub.dir })
end

---Close the hub: the tabpage it occupies when it is not the last one, else an
---empty buffer in that tabpage, which only hides the hub buffer. The hub is
---forgotten either way, so opening it again makes it new.
---@param hub prohub.hub.Hub
---@return true|nil ok
---@return string? err
local function close(hub)
    hubs[hub.key] = nil

    local tabpage = hub.tabpage
    hub.tabpage = nil
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return true
    end

    local closed, err = pcall(function()
        vim.api.nvim_set_current_tabpage(tabpage)
        if #vim.api.nvim_list_tabpages() > 1 then
            vim.cmd('tabclose')
            return
        end
        vim.cmd('enew')
        vim.t[tabpage][hub_variable] = nil
    end)
    if not closed then
        return nil,
            ('prohub: the hub could not be closed: %s'):format(tostring(err))
    end
    return true
end

---Map the keys of a hub onto its buffer, once per buffer.
---@param hub prohub.hub.Hub
local function attach(hub)
    if hub.mapped then
        return
    end

    local ok, err = keymaps.attach(hub.buffer, {
        cursor = function()
            return cursor_row(hub)
        end,
        refresh = function()
            return refresh(hub)
        end,
        close = function()
            return close(hub)
        end,
    })
    if not ok then
        log.error('the keys of the hub could not be mapped: %s', tostring(err))
        return
    end
    hub.mapped = true
end

---The hub of `key`, with its tabpage current. A tabpage the user closed and a
---buffer the user wiped are made again, so a hub never finds one of them gone.
---@param key string
---@return prohub.hub.Hub
local function show(key)
    local hub = hubs[key]
    if not hub then
        hub = { key = key, buffer = new_buffer(key), paths = {} }
        hubs[key] = hub
    elseif not vim.api.nvim_buf_is_valid(hub.buffer) then
        hub.buffer = new_buffer(key)
        hub.paths = {}
        hub.mapped = false
    end

    attach(hub)

    if hub.tabpage and vim.api.nvim_tabpage_is_valid(hub.tabpage) then
        vim.api.nvim_set_current_tabpage(hub.tabpage)
    else
        hub.tabpage = new_tab(hub.buffer, key)
    end
    return hub
end

---The first line that holds a row.
---@param listed table<integer, string>
---@return integer?
local function first_line(listed)
    local first
    for line in pairs(listed) do
        if not first or line < first then
            first = line
        end
    end
    return first
end

---Put the cursor back on the row of the worktree it was on, or on the first
---row when that row is gone.
---@param hub prohub.hub.Hub
---@param path string?
local function restore_cursor(hub, path)
    local win = vim.api.nvim_tabpage_get_win(hub.tabpage)
    if vim.api.nvim_win_get_buf(win) ~= hub.buffer then
        return
    end

    local wanted
    if path then
        for line, listed in pairs(hub.paths) do
            if listed == path then
                wanted = line
            end
        end
    end
    wanted = wanted or first_line(hub.paths) or 1

    local last = math.max(vim.api.nvim_buf_line_count(hub.buffer), 1)
    vim.api.nvim_win_set_cursor(win, { math.min(wanted, last), 0 })
end

---Write the rows of a hub into its buffer, and nothing else.
---@param buffer integer
---@param lines string[]
---@param highlights prohub.hub.Highlight[]
local function write(buffer, lines, highlights)
    vim.api.nvim_set_option_value('modifiable', true, { buf = buffer })
    vim.api.nvim_buf_clear_namespace(buffer, namespace, 0, -1)
    vim.api.nvim_buf_set_lines(buffer, 0, -1, false, lines)
    for _, row in ipairs(highlights) do
        vim.api.nvim_buf_set_extmark(buffer, namespace, row.line - 1, 0, {
            end_row = row.line,
            end_col = 0,
            hl_group = row.group,
            hl_eol = true,
        })
    end
    vim.api.nvim_set_option_value('modifiable', false, { buf = buffer })
end

---Render the rows of a hub, creating or reusing its tabpage, and keep the
---cursor on the worktree it was on.
---@param key string
---@param dir string Directory the hub was opened from.
---@param worktrees prohub.Worktree[]
---@param collections table<string, prohub.hub.Collection>
local function render(key, dir, worktrees, collections)
    local lines, highlights, listed, absent = build(worktrees, collections)
    local previous = hubs[key] and cursor_row(hubs[key]) or nil

    local hub = show(key)
    define_highlights()
    hub.dir = dir
    hub.worktrees = worktrees
    hub.paths = listed
    hub.missing = absent
    write(hub.buffer, lines, highlights)
    restore_cursor(hub, previous)
end

---Collect the status of every worktree that is not missing, all at the same
---time, and render the hub once every collection has answered. A collection
---that fails renders its own row with the error and does not fail the hub.
---@param key string
---@param dir string Directory the hub was opened from.
---@param worktrees prohub.Worktree[]
local function collect(key, dir, worktrees)
    local collections = {}
    local remaining = 0
    for _, entry in ipairs(worktrees) do
        if not entry.missing then
            remaining = remaining + 1
        end
    end

    local collecting = true
    local rendered = false
    local function finish()
        if collecting or rendered or remaining > 0 then
            return
        end
        rendered = true
        render(key, dir, worktrees, collections)
    end

    local function record(path, result, message)
        if result then
            collections[path] = { status = result }
        else
            message = message or 'the status could not be collected'
            log.warn('the status of %s is missing: %s', path, message)
            collections[path] = { err = message }
        end
        remaining = remaining - 1
        finish()
    end

    for _, entry in ipairs(worktrees) do
        local path = entry.path
        if not entry.missing then
            local started, err = status.collect(path, function(result, message)
                record(path, result, message)
            end)
            if not started then
                record(path, nil, err)
            end
        end
    end

    collecting = false
    finish()
end

---Whether `dir` is `path` or a directory inside it.
---@param path string
---@param dir string
---@return boolean
local function contains(path, dir)
    if path == '/' then
        return true
    end
    return dir == path or dir:sub(1, #path + 1) == path .. '/'
end

---The identity of the hub that holds a directory: the first worktree of its
---project, so every worktree of the project opens the same hub, or the key of
---the workset that holds it.
---@param dir string
---@param worktrees prohub.Worktree[]
---@param worksets table<string, string[]|fun(): string[]>
---@return string
local function identity(dir, worktrees, worksets)
    for _, record in ipairs(worktrees) do
        if contains(record.path, dir) then
            return worktrees[1].path
        end
    end

    local match = workset.match(dir, worksets)
    if match then
        return match.key
    end
    return worktrees[1].path
end

---Show the worktrees a listing delivered. A failure is the one the user can
---act on, so it is notified, and a listing that holds no worktree opens no
---tabpage, because the workset already warned the user.
---@param dir string
---@param worksets table<string, string[]|fun(): string[]>
---@param worktrees prohub.Worktree[]?
---@param err string?
local function shown(dir, worksets, worktrees, err)
    if err then
        log.debug('the worktrees of %s could not be listed: %s', dir, err)
        vim.notify(err, vim.log.levels.ERROR)
        return
    end
    if not worktrees or #worktrees == 0 then
        return
    end

    collect(identity(dir, worktrees, worksets), dir, worktrees)
end

---@param opts? prohub.OpenOpts
---@return true|nil ok
---@return string? err
local function start(opts)
    local ok, err = validate.check({ opts = { opts, 'table', true } })
    if not ok then
        return nil, err
    end

    ok, err = validate.check({
        ['opts.cwd'] = { opts and opts.cwd, 'string', true },
    })
    if not ok then
        return nil, err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    local base = vim.fn.getcwd()
    local dir = paths.normalize((opts and opts.cwd) or base, base)

    local started, list_err = workset.list(
        dir,
        function(worktrees, list_failure)
            shown(dir, options.worksets, worktrees, list_failure)
        end
    )
    if not started then
        return nil, list_err
    end
    return true
end

---Open the hub of the project or the workset that holds a directory, in its
---own tabpage. A hub that is already open is reused and rendered again, and
---the cursor stays on the worktree it was on.
---
---The rows appear once every status has been collected, so this function only
---starts the work and returns. A failure to list the worktrees is notified,
---because the user can act on it, and a directory outside every project and
---workset opens no tabpage. Invalid arguments and a directory that does not
---exist return an error instead, and this function never throws.
---@param opts? prohub.OpenOpts
---@return true|nil ok
---@return string? err
function M.open(opts)
    local called, ok, err = pcall(start, opts)
    if not called then
        log.error('the hub could not be opened: %s', tostring(ok))
        return nil,
            ('prohub: the hub could not be opened: %s'):format(tostring(ok))
    end
    return ok, err
end

return M
