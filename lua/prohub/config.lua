---The options of prohub. They come from three layers, each one overriding the
---one before it: the defaults, `vim.g.prohub` and the optional `setup` call.
---`get` merges them and validates the result, so a caller reads the options
---once and never has to know where a value came from.
---
---`setup` is optional and `get` reads `vim.g.prohub` at call time, so options
---set after the plugin was loaded are honoured.
---
---    local config = require('prohub.config')
---    local options, err = config.get()
---    if not options then
---        return err
---    end
---@class prohub.config
local M = {}

local validate = require('prohub.validate')

---A keymap of the hub, or `false` to disable the action it triggers.
---@class prohub.Keymaps
---@field review string|false
---@field scope string|false
---@field refresh string|false
---@field close string|false
---@field help string|false

---The merged and validated options of prohub.
---@class prohub.Config
---@field default_scope prohub.Scope The scope of a review that is given none.
---@field default_branch string? The branch of a project whose base is unknown.
---@field diff_viewer string Name of the diff viewer that draws a review.
---@field refresh_interval integer Milliseconds between two refreshes of the hub.
---@field worksets table<string, string[]|fun(): string[]> Worktrees shown per directory.
---@field keymaps prohub.Keymaps

---The options accepted by `setup`. Every field is optional, and an omitted
---field keeps the value it already has.
---@class prohub.ConfigOverrides
---@field default_scope? prohub.Scope
---@field default_branch? string
---@field diff_viewer? string
---@field refresh_interval? integer
---@field worksets? table<string, string[]|fun(): string[]>
---@field keymaps? table<string, string|false>

---The defaults of every option. `nil` fields are unset, and the table is only
---ever read, so a returned option never shares a table with it.
---@type prohub.Config
local defaults = {
    default_scope = 'branch',
    default_branch = nil,
    diff_viewer = 'minifugit',
    refresh_interval = 5000,
    worksets = {},
    keymaps = {
        review = '<CR>',
        scope = 's',
        refresh = 'r',
        close = 'q',
        help = '?',
    },
}

---The scopes a review can show. The `prohub.Scope` alias names them.
---@type table<string, true>
local scopes = {
    branch = true,
    unpushed = true,
    uncommitted = true,
}

---The options a user can set.
---@type table<string, true>
local names = {
    default_scope = true,
    default_branch = true,
    diff_viewer = true,
    refresh_interval = true,
    worksets = true,
    keymaps = true,
}

---The keymaps of the hub.
---@type table<string, true>
local keymap_names = {
    review = true,
    scope = true,
    refresh = true,
    close = true,
    help = true,
}

---@param value any
---@return boolean
local function is_scope(value)
    return type(value) == 'string' and scopes[value] == true
end

---@param value any
---@return boolean
local function is_non_empty_string(value)
    return type(value) == 'string' and value ~= ''
end

---@param value any
---@return boolean
local function is_positive_integer(value)
    return type(value) == 'number' and value > 0 and value % 1 == 0
end

---A keymap is a key, or `false` to disable the action.
---@param value any
---@return boolean
local function is_keymap(value)
    return type(value) == 'string' or value == false
end

---A workset is a list of entries, or a function that returns them. What an
---entry points at is decided when the hub reads it, so only the shape is
---checked here.
---@param value any
---@return boolean
local function is_workset(value)
    if type(value) == 'function' then
        return true
    end
    if not vim.islist(value) then
        return false
    end
    for _, entry in ipairs(value) do
        if type(entry) ~= 'string' then
            return false
        end
    end
    return true
end

---Check the merged options. Every message names the option, so a mistake in
---`vim.g.prohub` or in `setup` is easy to find.
---@param options table
---@return true|nil ok
---@return string? err
local function check_options(options)
    local ok, err = validate.check({
        default_scope = {
            options.default_scope,
            is_scope,
            "one of 'branch', 'unpushed' and 'uncommitted'",
        },
        default_branch = {
            options.default_branch,
            function(value)
                return value == nil or is_non_empty_string(value)
            end,
            'a non-empty string',
        },
        diff_viewer = {
            options.diff_viewer,
            is_non_empty_string,
            'a non-empty string',
        },
        refresh_interval = {
            options.refresh_interval,
            is_positive_integer,
            'a positive integer',
        },
        keymaps = { options.keymaps, 'table' },
        worksets = { options.worksets, 'table' },
    })
    if not ok then
        return nil, err
    end

    for name in pairs(options) do
        if not names[name] then
            return nil, ('prohub: %s: unknown option'):format(tostring(name))
        end
    end

    for name, value in pairs(options.keymaps) do
        if not keymap_names[name] then
            return nil,
                ('prohub: keymaps.%s: unknown option'):format(tostring(name))
        end
        ok, err = validate.check({
            ['keymaps.' .. name] = { value, is_keymap, 'string or false' },
        })
        if not ok then
            return nil, err
        end
    end

    for directory, workset in pairs(options.worksets) do
        if type(directory) ~= 'string' then
            return nil,
                ('prohub: worksets: expected directory keys, got %s'):format(
                    type(directory)
                )
        end
        ok, err = validate.check({
            ['worksets.' .. directory] = {
                workset,
                is_workset,
                'a list of strings or a function',
            },
        })
        if not ok then
            return nil, err
        end
    end

    return true
end

---The options set by `setup`, merged over the defaults and `vim.g.prohub`.
---@type table
local stored = {}

---Copy a table, keeping any function it holds by reference.
---@param value any
---@return any
local function copy(value)
    if type(value) ~= 'table' then
        return value
    end

    local result = {}
    for key, item in pairs(value) do
        result[key] = copy(item)
    end
    return result
end

---@param value any
---@return boolean
local function is_table(value)
    return type(value) == 'table'
end

---Overlay one layer of options on another. Omitted fields keep the value they
---already have, and `keymaps` is merged key by key, so overriding one keymap
---keeps the others.
---@param base table
---@param layer table
---@return table
local function merge(base, layer)
    local result = copy(base)
    for name, value in pairs(layer) do
        if name == 'keymaps' and is_table(value) then
            result.keymaps =
                vim.tbl_extend('force', result.keymaps or {}, value)
        else
            result[name] = value
        end
    end
    return result
end

---`vim.g.prohub`, or an empty table when the user has not set it.
---@return table? global
---@return string? err
local function read_global()
    local global = vim.g.prohub
    if global == nil or global == vim.NIL then
        return {}
    end
    if type(global) ~= 'table' then
        return nil,
            ('prohub: vim.g.prohub: expected table, got %s'):format(
                type(global)
            )
    end
    return global
end

---The options in use: the defaults, over `vim.g.prohub`, over `setup`.
---@return prohub.Config? options
---@return string? err
function M.get()
    local global, err = read_global()
    if not global then
        return nil, err
    end

    local options = merge(merge(defaults, global), stored)
    local ok, check_err = check_options(options)
    if not ok then
        return nil, check_err
    end
    return options
end

---Change the options. Omitted fields keep their value. A value that is not
---valid returns an error, and the options in use stay as they were.
---@param opts? prohub.ConfigOverrides
---@return true|nil ok
---@return string? err
function M.setup(opts)
    local ok, err = validate.check({ opts = { opts, 'table', true } })
    if not ok then
        return nil, err
    end

    local global, gerr = read_global()
    if not global then
        return nil, gerr
    end

    local layer = opts and copy(opts) or {}
    local options = merge(merge(merge(defaults, global), stored), layer)
    ok, err = check_options(options)
    if not ok then
        return nil, err
    end

    stored = merge(stored, layer)
    return true
end

return M
