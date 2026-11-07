---The worksets of prohub. A workset is the list of worktrees the hub shows
---when it is opened outside a git repository, chosen by the directory the hub
---is opened from.
---
---    local workset = require('prohub.workset')
---
---    local key, entries = workset.match(dir, options.worksets)
---    workset.list(dir, function(worktrees, err) end)
---
---Both functions report an expected failure as `nil` and an error instead of
---throwing, and a directory that matches no workset is not a failure.
---@class prohub.workset
local M = {}

local config = require('prohub.config')
local log = require('prohub.log')
local validate = require('prohub.validate')
local worktree = require('prohub.worktree')

---@param value any
---@return boolean
local function is_string_list(value)
    if not vim.islist(value) then
        return false
    end
    for _, item in ipairs(value) do
        if type(item) ~= 'string' then
            return false
        end
    end
    return true
end

---@param path string
---@return boolean
local function is_absolute(path)
    if vim.fn.has('win32') == 1 then
        return path:match('^%a:/') ~= nil or path:match('^//') ~= nil
    end
    return path:match('^/') ~= nil
end

---Expand `~`, make a path absolute, resolve the symbolic links it may contain
---and drop a trailing slash. The file system is only read for a path that
---exists, so a path that is about to be reported can still be normalized.
---@param path string
---@param base string Directory a relative path is resolved against.
---@return string
local function normalize(path, base)
    local result = vim.fs.normalize(path)
    if not is_absolute(result) then
        result = vim.fs.normalize(vim.fs.joinpath(base, result))
    end
    return vim.uv.fs_realpath(result) or result
end

---Whether `key` is `dir` or a directory that contains it.
---@param key string
---@param dir string
---@return boolean
local function contains(key, dir)
    if key == '/' then
        return true
    end
    return dir == key or dir:sub(1, #key + 1) == key .. '/'
end

---The entries of one workset as absolute paths, resolved against the key.
---@param entries string[]|fun(): string[]
---@param key string The key of the workset, as it was configured.
---@param base string The normalized key, relative entries are resolved against.
---@return string[]|nil paths
---@return string? err
local function resolve(entries, key, base)
    if type(entries) == 'function' then
        local called, result = pcall(entries)
        if not called then
            return nil,
                ('prohub: worksets.%s: %s'):format(key, tostring(result))
        end
        if not is_string_list(result) then
            return nil,
                ('prohub: worksets.%s: expected a list of strings'):format(key)
        end
        entries = result
    elseif not is_string_list(entries) then
        return nil,
            ('prohub: worksets.%s: expected a list of strings'):format(key)
    end

    local paths, seen = {}, {}
    for _, entry in ipairs(entries) do
        local pattern = normalize(entry, base)
        local matches = vim.fn.glob(pattern, false, true)
        if #matches == 0 then
            -- A glob that matches nothing, or a plain path that does not exist,
            -- is kept as it was written, so the caller can report the path.
            matches = { pattern }
        end
        for _, match in ipairs(matches) do
            local path = normalize(match, base)
            if not seen[path] then
                seen[path] = true
                table.insert(paths, path)
            end
        end
    end
    return paths
end

---The key of the nearest ancestor of `dir`, and the entries of that workset as
---absolute paths.
---
---Keys are directories that contain `dir`, or that are `dir` itself. The
---deepest key wins, so a workset of a subdirectory hides the workset of the
---directory that holds it. An entry is a path, a glob, or a function that
---returns paths. Glob matches keep the order of the workset, and a glob that
---matches nothing keeps its own text, so the caller reports it as a path that
---is not a worktree.
---@param dir string Directory the hub is opened from.
---@param worksets table<string, string[]|fun(): string[]> The option of the
---same name.
---@return string? key The key of the nearest workset, as it was configured.
---@return string[]|string? entries The entries as absolute paths, or the error
---of a function that failed.
function M.match(dir, worksets)
    local ok, err = validate.check({
        dir = { dir, 'string' },
        worksets = { worksets, 'table' },
    })
    if not ok then
        return nil, err
    end

    local target = normalize(dir, vim.fn.getcwd())
    local nearest, base, deepest
    for _, key in ipairs(vim.tbl_keys(worksets)) do
        if type(key) ~= 'string' then
            return nil,
                ('prohub: worksets: expected directory keys, got %s'):format(
                    type(key)
                )
        end
        local normalized = normalize(key, vim.fn.getcwd())
        if contains(normalized, target) and #normalized > (deepest or -1) then
            nearest, base, deepest = key, normalized, #normalized
        end
    end
    if not nearest then
        return nil
    end

    local paths, resolve_err = resolve(worksets[nearest], nearest, base)
    if not paths then
        return nil, resolve_err
    end
    return nearest, paths
end

---Deliver a result of `list` on the main loop, where the hub can use the API.
---@param callback fun(worktrees: prohub.Worktree[]?, err: string?)
---@param worktrees prohub.Worktree[]?
---@param err string?
local function deliver(callback, worktrees, err)
    if vim.in_fast_event() then
        vim.schedule(function()
            callback(worktrees, err)
        end)
    else
        callback(worktrees, err)
    end
end

---The record of the worktree that `path` is, or `nil` when `path` is not a
---worktree of the project that holds it.
---@param worktrees prohub.Worktree[]?
---@param path string
---@return prohub.Worktree?
local function pick(worktrees, path)
    local wanted = vim.uv.fs_realpath(path) or path
    for _, record in ipairs(worktrees or {}) do
        if (vim.uv.fs_realpath(record.path) or record.path) == wanted then
            return record
        end
    end
end

---The worktrees of the workset whose key is the nearest ancestor of `dir`.
---@param dir string
---@param callback fun(worktrees: prohub.Worktree[]?, err: string?)
local function from_workset(dir, callback)
    local options, err = config.get()
    if not options then
        return deliver(callback, nil, err)
    end

    local matched, entries = M.match(dir, options.worksets)
    if not matched then
        -- `match` returns its error in place of the entries.
        if entries then
            return deliver(callback, nil, entries)
        end
        vim.notify(
            ('prohub: no workset matches %s'):format(dir),
            vim.log.levels.WARN
        )
        return deliver(callback, {})
    end

    local paths = {}
    for _, entry in ipairs(entries) do
        local stat = vim.uv.fs_stat(entry)
        if stat and stat.type == 'directory' then
            table.insert(paths, entry)
        else
            log.warn('prohub: skipping %s: not a git worktree', entry)
        end
    end

    local records = {}
    local remaining = #paths
    local function finish(index, record, warning)
        records[index] = record
        if warning then
            log.warn('%s', warning)
        end
        remaining = remaining - 1
        if remaining > 0 then
            return
        end
        local worktrees = {}
        for i = 1, #paths do
            if records[i] then
                table.insert(worktrees, records[i])
            end
        end
        deliver(callback, worktrees)
    end

    if remaining == 0 then
        return deliver(callback, {})
    end

    -- Every entry is listed at the same time, so a workset of many worktrees
    -- costs one git command per entry and not a chain of them. The records keep
    -- the order of the workset.
    for index, entry in ipairs(paths) do
        local ok, start_err = worktree.list(entry, function(worktrees, list_err)
            local record = pick(worktrees, entry)
            local warning
            if not record then
                warning = ('prohub: skipping %s: %s'):format(
                    entry,
                    list_err or 'not a git worktree'
                )
            end
            finish(index, record, warning)
        end)
        if not ok then
            finish(
                index,
                nil,
                ('prohub: skipping %s: %s'):format(entry, start_err)
            )
        end
    end
end

---The worktrees the hub shows for `dir`, in the order of the hub, without
---blocking the editor. Inside a git project they are the ones git reports for
---that project; outside one they are the entries of the workset whose key is the
---nearest ancestor of `dir`, one worktree per entry.
---
---Return `nil` and an error for invalid arguments or a directory that does not
---exist, without calling the callback. Otherwise the callback receives the
---worktrees, or `nil` and an error, on the main loop. A directory outside
---every workset notifies the user with a warning and delivers no worktree.
---@param dir string Directory the hub is opened from.
---@param callback fun(worktrees: prohub.Worktree[]?, err: string?)
---@return true|nil ok
---@return string? err
function M.list(dir, callback)
    local ok, err = validate.check({
        dir = { dir, 'string' },
        callback = { callback, 'function' },
    })
    if not ok then
        return nil, err
    end

    local path = normalize(dir, vim.fn.getcwd())
    local stat = vim.uv.fs_stat(path)
    if not stat then
        return nil, ('prohub: the path does not exist: %s'):format(dir)
    end
    if stat.type ~= 'directory' then
        return nil, ('prohub: the path is not a directory: %s'):format(dir)
    end

    return worktree.list(path, function(worktrees, list_err)
        if worktrees then
            return deliver(callback, worktrees)
        end
        log.debug('prohub: %s is not a git repository: %s', path, list_err)
        from_workset(path, callback)
    end)
end

return M
