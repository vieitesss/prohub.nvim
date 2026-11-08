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
---The rows of a hub are built by `prohub.hub.render`, which reads the
---worktrees and their status and writes nothing, so the render of a hub is the
---one step that touches the buffer. The hub marks its tabpage through
---`prohub.tab`, which is how a review that cannot return to the tabpage it was
---opened from finds the hub.
---
---    local hub = require('prohub.hub')
---
---    local ok, err = hub.open({ cwd = path })
---
---The keys of a hub are buffer-local mappings from the options, and they live
---in `prohub.hub.keymaps`: the hub hands that module the worktree of the row
---under the cursor, a refresh and a close.
---
---A hub also renders itself again while it is shown in a window of the current
---tabpage and Neovim has focus, on the timer and the events of
---`prohub.hub.refresh`. The hub hands that module its buffer and the action
---that renders it again, and such a render writes the buffer in place and
---drops a result whose hub is gone, so the timer never takes the user back to
---the hub.
---@class prohub.hub
local M = {}

local config = require('prohub.config')
local keymaps = require('prohub.hub.keymaps')
local log = require('prohub.log')
local paths = require('prohub.path')
local render = require('prohub.hub.render')
local status = require('prohub.status')
local tab = require('prohub.tab')
local validate = require('prohub.validate')
local watch = require('prohub.hub.refresh')
local workset = require('prohub.workset')
local worktree = require('prohub.worktree')

---The prefix of the name of the buffer of a hub.
---@type string
local prefix = 'prohub://'

---The namespace of the highlights of the hub buffers.
local namespace = vim.api.nvim_create_namespace('prohub_hub')

---An open hub.
---@class prohub.hub.Hub
---@field key string Identity of the hub.
---@field buffer integer The buffer that holds the rows.
---@field tabpage integer The tabpage the hub lives in.
---@field paths table<integer, string> The worktree of each line of the buffer.
---@field missing? table<string, true> The worktrees git reports as missing.
---@field worktrees? prohub.Worktree[] The worktrees the last render listed.
---@field dir? string The directory the hub was opened from.
---@field workset? boolean Whether the hub shows the worktrees of a workset.
---@field mapped? boolean Whether the keys of the hub are on its buffer.
---@field watching? boolean Whether the timer and the events of the hub follow
---its buffer.
---@field rendering? integer The renders of the hub that are in flight.

---The open hubs, by key.
---@type table<string, prohub.hub.Hub>
local hubs = {}

---Whether the highlight groups of the hub are defined already.
---@type boolean
local highlighted = false

---Define the highlight groups of the hub, unless the user already set them.
local function define_highlights()
    if highlighted then
        return
    end
    highlighted = true
    vim.api.nvim_set_hl(0, render.missing_group, {
        link = 'Comment',
        default = true,
    })
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
    tab.mark_hub(tabpage)

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

---The steps below call each other, so the two that the timer and the keys
---reach through more than one step are named before they are written.
local attach, rerender

---Close the hub: the tabpage it occupies when it is not the last one, else an
---empty buffer in that tabpage, which only hides the hub buffer. The hub is
---forgotten either way, so opening it again makes it new.
---@param hub prohub.hub.Hub
---@return true|nil ok
---@return string? err
local function close(hub)
    hubs[hub.key] = nil
    watch.detach(hub.buffer)
    hub.watching = false

    local tabpage = hub.tabpage
    hub.tabpage = nil
    if not tabpage or not vim.api.nvim_tabpage_is_valid(tabpage) then
        return true
    end

    local closed, close_err = tab.close(tabpage)
    if close_err then
        return nil,
            ('prohub: the hub could not be closed: %s'):format(close_err)
    end
    if closed then
        return true
    end

    -- Neovim cannot close the last tabpage, so the hub buffer is replaced by
    -- an empty one and the tabpage stays.
    local hidden, hide_err = pcall(function()
        vim.api.nvim_set_current_tabpage(tabpage)
        vim.cmd('enew')
        tab.clear_hub(tabpage)
    end)
    if not hidden then
        return nil,
            ('prohub: the hub could not be closed: %s'):format(
                tostring(hide_err)
            )
    end
    return true
end

---Show the hub in its tabpage, which it makes current when the user moved
---away and creates when the tabpage is gone.
---@param hub prohub.hub.Hub
local function present(hub)
    if hub.tabpage and vim.api.nvim_tabpage_is_valid(hub.tabpage) then
        vim.api.nvim_set_current_tabpage(hub.tabpage)
    else
        hub.tabpage = new_tab(hub.buffer, hub.key)
    end
end

---The hub of `key`, with the buffer, the keys and the timer that belong to it.
---A tabpage the user closed and a buffer the user wiped are made again, so a
---hub never finds one of them gone. Neither is shown.
---@param key string
---@return prohub.hub.Hub
local function ensure(key)
    local hub = hubs[key]
    if not hub then
        hub = { key = key, buffer = new_buffer(key), paths = {} }
        hubs[key] = hub
    elseif not vim.api.nvim_buf_is_valid(hub.buffer) then
        hub.buffer = new_buffer(key)
        hub.paths = {}
        hub.mapped = false
        hub.watching = false
    end

    attach(hub)
    return hub
end

---Map the keys of a hub onto its buffer and follow it with the timer and the
---events of `prohub.hub.refresh`, once per buffer.
---@param hub prohub.hub.Hub
attach = function(hub)
    if not hub.mapped then
        local ok, err = keymaps.attach(hub.buffer, {
            cursor = function()
                return cursor_row(hub)
            end,
            refresh = function()
                return rerender(hub, false)
            end,
            close = function()
                return close(hub)
            end,
        })
        if ok then
            hub.mapped = true
        else
            log.error(
                'the keys of the hub could not be mapped: %s',
                tostring(err)
            )
        end
    end

    if hub.watching then
        return
    end
    local watching, watch_err = watch.attach(hub.buffer, function()
        return rerender(hub, true)
    end)
    if not watching then
        log.error(
            'the refresh of the hub could not be watched: %s',
            tostring(watch_err)
        )
        return
    end
    hub.watching = true
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
---row when that row is gone. A hub whose tabpage is gone has no window to keep
---the cursor in, so there is nothing to do.
---@param hub prohub.hub.Hub
---@param path string?
local function restore_cursor(hub, path)
    if not hub.tabpage or not vim.api.nvim_tabpage_is_valid(hub.tabpage) then
        return
    end

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

---Write the rows of a hub into its buffer and keep the cursor of its window on
---the worktree it was on. Nothing else of the editor changes, so a render that
---runs while the user is elsewhere does not take the user to the hub.
---@param hub prohub.hub.Hub
---@param dir string Directory the hub was opened from.
---@param worktrees prohub.Worktree[]
---@param collections table<string, prohub.hub.Collection>
local function render_rows(hub, dir, worktrees, collections)
    local rows = render.build(worktrees, collections)
    local previous = cursor_row(hub)

    define_highlights()
    hub.dir = dir
    hub.worktrees = worktrees
    hub.paths = rows.paths
    hub.missing = rows.missing
    write(hub.buffer, rows.lines, rows.highlights)
    restore_cursor(hub, previous)
end

---Write the rows of a listing into a hub, and show the hub first when the
---render comes from an open. The record of the render is dropped whether the
---rows are written or not, so a failure never keeps the next render out.
---@param hub prohub.hub.Hub
---@param show boolean Whether to make the tabpage of the hub current.
---@param dir string Directory the hub was opened from.
---@param worktrees prohub.Worktree[]
---@param collections table<string, prohub.hub.Collection>
local function draw(hub, show, dir, worktrees, collections)
    hub.rendering = (hub.rendering or 0) + 1
    local ok, err = pcall(function()
        if show then
            present(hub)
        end
        render_rows(hub, dir, worktrees, collections)
    end)
    hub.rendering = (hub.rendering or 1) - 1
    if not ok then
        log.error(
            'the hub of %s could not be rendered: %s',
            hub.key,
            tostring(err)
        )
    end
end

---Collect the status of every worktree that is not missing, all at the same
---time, and deliver the rows once every collection has answered. A collection
---that fails renders its own row with the error and does not fail the hub.
---@param worktrees prohub.Worktree[]
---@param finish fun(worktrees: prohub.Worktree[], collections: table<string, prohub.hub.Collection>)
local function collect(worktrees, finish)
    local collections = {}
    local remaining = 0
    for _, entry in ipairs(worktrees) do
        if not entry.missing then
            remaining = remaining + 1
        end
    end

    local collecting = true
    local delivered = false
    local function deliver()
        if collecting or delivered or remaining > 0 then
            return
        end
        delivered = true
        finish(worktrees, collections)
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
        deliver()
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
    deliver()
end

---Render a hub again from a fresh listing, into the hub it was started for.
---The timer and the events of the hub render in place; the refresh key renders
---through the path an open takes, which shows the hub.
---@param hub prohub.hub.Hub
---@param automatic boolean Whether the timer or an event asked for the render,
---rather than a key. Such a failure is logged instead of notified, and a
---result whose hub is gone is dropped.
---@return true|nil ok
---@return string? err
rerender = function(hub, automatic)
    if not hub.dir then
        return nil, 'prohub: the hub has no directory to render again'
    end
    if (hub.rendering or 0) > 0 then
        log.debug('the hub of %s is rendered already', hub.key)
        return true
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    for _, record in ipairs(hub.worktrees or {}) do
        status.invalidate(record.path)
    end

    -- One render per hub at a time: the record stays until the listing and
    -- every status have answered, so nothing else starts meanwhile.
    hub.rendering = 1
    local buffer = hub.buffer
    local key, dir = hub.key, hub.dir

    local function settle()
        hub.rendering = 0
    end

    local function failed(message)
        settle()
        if automatic then
            log.warn('the hub of %s was not rendered: %s', key, message)
            return
        end
        log.debug('the hub of %s was not rendered: %s', key, message)
        vim.notify(message, vim.log.levels.ERROR)
    end

    -- A project lists its worktrees itself, so an automatic refresh of a
    -- project that stopped being one fails quietly instead of warning the user
    -- again on every tick. A workset is resolved again, as it was opened.
    local list = worktree.list
    if hub.workset then
        list = workset.list
    end

    local started, list_err = list(dir, function(worktrees, err)
        if err then
            return failed(err)
        end
        if not worktrees or #worktrees == 0 then
            settle()
            if automatic then
                log.warn('the hub of %s lists no worktree', key)
            end
            return
        end

        collect(worktrees, function(listed, collections)
            local rendered, render_err = pcall(function()
                if automatic then
                    if
                        hubs[key] ~= hub
                        or hub.buffer ~= buffer
                        or not vim.api.nvim_buf_is_valid(buffer)
                    then
                        log.debug(
                            'the hub of %s is gone, so the render is dropped',
                            key
                        )
                        return
                    end
                    draw(hub, false, dir, listed, collections)
                else
                    local target = ensure(key)
                    target.workset = hub.workset
                    draw(target, true, dir, listed, collections)
                end
            end)
            settle()
            if not rendered then
                log.error(
                    'the hub of %s could not be rendered: %s',
                    key,
                    tostring(render_err)
                )
            end
        end)
    end)
    if not started then
        failed(list_err)
    end
    return true
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
---@return string key
---@return boolean workset Whether the key names a workset.
local function identity(dir, worktrees, worksets)
    for _, record in ipairs(worktrees) do
        if contains(record.path, dir) then
            return worktrees[1].path, false
        end
    end

    local match = workset.match(dir, worksets)
    if match then
        return match.key, true
    end
    return worktrees[1].path, false
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

    local key, is_workset = identity(dir, worktrees, worksets)
    collect(worktrees, function(listed, collections)
        local hub = ensure(key)
        hub.workset = is_workset
        draw(hub, true, dir, listed, collections)
    end)
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
