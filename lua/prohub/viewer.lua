---The diff viewer interface of prohub. A review is opened by an existing
---plugin, and `viewer` is the one place that knows which plugin is configured
---and how to reach it.
---
---A context carries everything a viewer needs: the worktree to show, the scope
---of the changes and the base revision, which prohub computed itself. A viewer
---never decides what a scope means, and it never draws a tab of its own: it
---renders a review into the current tabpage.
---
---A viewer is a function, or a table with an `open` function, that takes the
---context and returns `true`, or `nil` and an error message. There is no
---fallback: a viewer that is missing, or that does not support what is asked,
---returns a clear error to the caller, and the review does not open.
---
---    local viewer = require('prohub.viewer')
---
---    local ok, err = viewer.open({
---        path = '/projects/one',
---        scope = 'branch',
---        base = 'a1b2c3',
---    })
---@class prohub.viewer
local M = {}

local config = require('prohub.config')
local log = require('prohub.log')
local paths = require('prohub.path')
local validate = require('prohub.validate')

---What a review needs to know. `base` is missing exactly when the scope is
---`uncommitted`, which is what `prohub.ScopeResult` carries.
---@class prohub.ViewerContext
---@field path string Absolute path of the worktree to review.
---@field scope prohub.Scope Which changes the review shows.
---@field base string? The revision the review shows the changes since.
---@field on_close fun()? Called once, when the viewer closed the review.

---A viewer draws a review and says whether it opened one.
---@alias prohub.Viewer fun(ctx: prohub.ViewerContext): true|nil, string?

---What the `diff_viewer` option accepts: the name of a built-in viewer, a
---viewer function, or a table with an `open` function.
---@alias prohub.ViewerSpec string|prohub.Viewer|{ open: prohub.Viewer }

---The built-in viewers, by the name the `diff_viewer` option gives them. They
---are loaded when they are used, so a project does not need the one that is
---configured for another project.
---@type table<string, string>
local builtins = {
    minifugit = 'prohub.viewers.minifugit',
}

---The names of the built-in viewers, in the order an error message lists them.
---@type string[]
local names = vim.tbl_keys(builtins)
table.sort(names)

---Check the arguments of `open`. The context is what a review of one scope
---produces, so a scope that needs a revision has one, and the uncommitted
---scope has none.
---@param ctx any
---@return true|nil ok
---@return string? err
local function check_context(ctx)
    local ok, err = validate.check({ ctx = { ctx, 'table' } })
    if not ok then
        return nil, err
    end

    ok, err = validate.check({
        ['ctx.path'] = { ctx.path, 'string' },
        ['ctx.scope'] = { ctx.scope, 'string' },
        ['ctx.base'] = {
            ctx.base,
            function(value)
                return value == nil or (type(value) == 'string' and value ~= '')
            end,
            'a non-empty string',
        },
        ['ctx.on_close'] = { ctx.on_close, 'function', true },
    })
    if not ok then
        return nil, err
    end

    if not config.scopes[ctx.scope] then
        return nil, ('prohub: ctx.scope: unknown scope: %s'):format(ctx.scope)
    end
    if ctx.scope == 'uncommitted' then
        if ctx.base ~= nil then
            return nil,
                'prohub: ctx.base: the uncommitted scope has no revision'
        end
    elseif ctx.base == nil then
        return nil,
            ('prohub: ctx.base: the %s scope needs a revision'):format(
                ctx.scope
            )
    end

    return paths.check(ctx.path)
end

---Turn a configured diff viewer into something callable. A name resolves to
---the built-in viewer of that name, a function is its own viewer, and a table
---is called through its `open` function. Anything else returns an error naming
---what was expected.
---@param spec any
---@return prohub.Viewer? viewer
---@return string? err
function M.resolve(spec)
    if type(spec) == 'string' then
        local module = builtins[spec]
        if not module then
            return nil,
                ('prohub: unknown diff viewer: %s (known viewers: %s)'):format(
                    spec,
                    table.concat(names, ', ')
                )
        end

        local ok, loaded = pcall(require, module)
        if not ok then
            return nil,
                ('prohub: could not load the %s diff viewer: %s'):format(
                    spec,
                    tostring(loaded)
                )
        end
        return M.resolve(loaded)
    end

    if type(spec) == 'function' then
        return spec
    end

    if type(spec) == 'table' then
        local open = spec.open
        if type(open) ~= 'function' then
            return nil, 'prohub: the diff viewer has no open function'
        end
        return function(ctx)
            return open(ctx)
        end
    end

    return nil,
        (
            'prohub: the diff viewer must be a name, a function or a table '
            .. 'with an open function, got %s'
        ):format(type(spec))
end

---Check the value a viewer returned. A viewer reports success with `true` and
---failure with an error message, and anything else is a mistake worth telling
---the caller about.
---@param result any
---@param err any
---@return true|nil ok
---@return string? message
local function check_result(result, err)
    if result == true then
        return true
    end
    if result == nil then
        if type(err) == 'string' and err ~= '' then
            return nil, err
        end
        return nil,
            'prohub: the diff viewer returned no error message for a failure'
    end
    return nil,
        (
            'prohub: the diff viewer returned %s, expected true or nil and an '
            .. 'error message'
        ):format(vim.inspect(result))
end

---Open a review of one worktree with the configured diff viewer.
---
---The context is validated first, then the configured viewer is resolved, so a
---mistake in the options is reported before anything opens. A viewer that
---throws, that returns an unexpected value or that cannot be loaded returns
---`nil` and an error instead. This function never throws.
---@param ctx prohub.ViewerContext
---@return true|nil ok
---@return string? err
function M.open(ctx)
    local ok, err = check_context(ctx)
    if not ok then
        return nil, err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    local viewer, resolve_err = M.resolve(options.diff_viewer)
    if not viewer then
        return nil, resolve_err
    end

    local called, result, result_err = pcall(viewer, ctx)
    if not called then
        local message = ('prohub: the diff viewer failed: %s'):format(
            tostring(result)
        )
        log.debug('the review of %s did not open: %s', ctx.path, message)
        return nil, message
    end

    ok, err = check_result(result, result_err)
    if not ok then
        log.debug('the review of %s did not open: %s', ctx.path, err)
        return nil, err
    end
    return true
end

return M
