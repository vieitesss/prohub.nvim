---The keys of the hub: the buffer-local mappings that open a review of the
---row under the cursor, ask for a scope, render the hub again, close it and
---list the keys themselves.
---
---The hub owns the rows and the tabpage, so it hands this module a small table
---of actions: the worktree of the row under the cursor and whether it is
---missing, a refresh and a close. The keys themselves come from
---`prohub.config`, and they are read when the buffer of a hub is made, so a
---key set to `false` gets no mapping at all.
---
---Every action runs under a guard: a failure becomes a message the user can
---act on and never an error trace.
---
---    local keymaps = require('prohub.hub.keymaps')
---
---    keymaps.attach(buffer, { cursor = cursor, refresh = refresh })
---@class prohub.hub.keymaps
local M = {}

local config = require('prohub.config')
local log = require('prohub.log')
local review = require('prohub.review')
local validate = require('prohub.validate')

---What the hub lets the keys do.
---@class prohub.hub.KeymapActions
---@field cursor fun(): (string?, boolean) The worktree of the row under the
---cursor, which is nil when the row holds none, and whether git reports that
---worktree as missing.
---@field refresh fun(): true|nil ok, string? err Render the hub again.
---@field close fun(): true|nil ok, string? err Close the hub.

---The order the keys are mapped and listed in.
---@type string[]
local order = { 'review', 'scope', 'refresh', 'close', 'help' }

---What each key does, both as the description of its mapping and as the line
---the help writes for it.
---@type table<string, string>
local descriptions = {
    review = 'open the review of the row under the cursor',
    scope = 'ask for a scope and open its review',
    refresh = 'render the hub again',
    close = 'close the hub',
    help = 'list these keys',
}

---The scopes a review can show, in the order the question lists them.
---@type prohub.Scope[]
local scopes = { 'branch', 'unpushed', 'uncommitted' }

---The label of each scope, in the words the glossary uses.
---@type table<prohub.Scope, string>
local labels = {
    branch = 'session changes',
    unpushed = 'unpushed changes',
    uncommitted = 'uncommitted changes',
}

---The worktree of the row under the cursor, or the message that says why no
---review opens.
---@param actions prohub.hub.KeymapActions
---@return string? path
---@return string? err
local function target(actions)
    local path, missing = actions.cursor()
    if not path then
        return nil, 'prohub: the row under the cursor holds no worktree'
    end
    if missing then
        return nil,
            ('prohub: the worktree of this row is missing: %s'):format(path)
    end
    return path
end

---Run one action of the hub. A failure is the outcome of a key the user
---pressed, so it is notified and the log names its cause.
---@param action fun(): true|nil ok, string? err
---@param description string What the key does, for the message.
local function guarded(action, description)
    local called, ok, err = pcall(action)
    if not called then
        log.error('%s failed: %s', description, tostring(ok))
        vim.notify(
            ('prohub: %s failed: %s'):format(description, tostring(ok)),
            vim.log.levels.ERROR
        )
        return
    end
    if not ok then
        log.debug('%s failed: %s', description, tostring(err))
        vim.notify(
            err or ('prohub: %s failed'):format(description),
            vim.log.levels.ERROR
        )
    end
end

---Open the review of the row under the cursor with the default scope. A row
---that holds no worktree, or whose worktree is missing, only says so.
---@param actions prohub.hub.KeymapActions
---@return true|nil ok
---@return string? err
local function review_row(actions)
    local path, err = target(actions)
    if not path then
        vim.notify(err, vim.log.levels.WARN)
        return true
    end
    return review.open(path)
end

---Ask for a scope and open the review of the row under the cursor with the
---choice. A row that holds no worktree only says so, and a cancelled question
---opens nothing.
---@param actions prohub.hub.KeymapActions
---@return true|nil ok
---@return string? err
local function review_with_scope(actions)
    local path, err = target(actions)
    if not path then
        vim.notify(err, vim.log.levels.WARN)
        return true
    end

    vim.ui.select(scopes, {
        prompt = 'prohub: which changes does the review show?',
        format_item = function(name)
            return labels[name]
        end,
    }, function(choice)
        if not choice then
            return
        end
        guarded(function()
            return review.open(path, { scope = choice })
        end, descriptions.scope)
    end)
    return true
end

---List the keys that are active and what each of them does, in one message,
---in the fixed order of `order`.
---@param keys prohub.Keymaps
---@return true
local function list_keys(keys)
    local lines = {}
    for _, name in ipairs(order) do
        local lhs = keys[name]
        if lhs then
            table.insert(lines, ('%s  %s'):format(lhs, descriptions[name]))
        end
    end

    vim.notify(table.concat(lines, '\n'), vim.log.levels.INFO)
    return true
end

---The action each key runs.
---@type table<string, fun(actions: prohub.hub.KeymapActions, keys: prohub.Keymaps): true|nil, string?>
local handlers = {
    review = review_row,
    scope = review_with_scope,
    refresh = function(actions)
        return actions.refresh()
    end,
    close = function(actions)
        return actions.close()
    end,
    help = function(_, keys)
        return list_keys(keys)
    end,
}

---Map the keys of a buffer from the options of a hub.
---@param buffer integer
---@param keys prohub.Keymaps
---@param actions prohub.hub.KeymapActions
local function install(buffer, keys, actions)
    for _, name in ipairs(order) do
        local lhs = keys[name]
        if lhs then
            local handler = handlers[name]
            local description = descriptions[name]
            vim.keymap.set('n', lhs, function()
                guarded(function()
                    return handler(actions, keys)
                end, description)
            end, {
                buffer = buffer,
                nowait = true,
                desc = 'prohub: ' .. description,
            })
        end
    end
end

---Map the keys of a hub onto its buffer, from the options in use. A key set to
---`false` gets no mapping. Invalid arguments and options return `nil` and the
---error, and this function never throws.
---@param buffer integer
---@param actions prohub.hub.KeymapActions
---@return true|nil ok
---@return string? err
function M.attach(buffer, actions)
    local ok, err = validate.check({
        buffer = { buffer, 'number' },
        actions = { actions, 'table' },
    })
    if not ok then
        return nil, err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    local mapped, map_err = pcall(install, buffer, options.keymaps, actions)
    if not mapped then
        return nil,
            ('prohub: the keys of the hub could not be mapped: %s'):format(
                tostring(map_err)
            )
    end
    return true
end

return M
