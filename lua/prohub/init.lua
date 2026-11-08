---The public API of prohub: the options, the hub and one review.
---
---Every function returns `true` (or a value) or `nil` and an error, and never
---throws. A failure is returned, not notified, so a caller that is not a
---command can decide what to do with it. The commands of the plugin live in
---`lua/prohub/command.lua` and are the one caller that notifies.
---
---    local prohub = require('prohub')
---
---    local ok, err = prohub.open()
---    local reviewed, review_err = prohub.review('/projects/one', {
---        scope = 'unpushed',
---    })
---@class prohub
local M = {}

local config = require('prohub.config')
local hub = require('prohub.hub')
local review = require('prohub.review')
local validate = require('prohub.validate')

---Which changes a review shows: the session changes, the unpushed changes or
---the uncommitted changes.
---@alias prohub.Scope 'branch'|'unpushed'|'uncommitted'

---Change the options of prohub. It is optional: `vim.g.prohub` works on its
---own, and options set after the plugin loads are honoured. A value that is
---not valid returns an error and leaves the options as they were.
---@param opts? prohub.ConfigOverrides The options to change.
---@return true|nil ok
---@return string? err
function M.setup(opts)
    return config.setup(opts)
end

---The options of the hub: the directory to open it from.
---@class prohub.OpenOpts
---@field cwd? string Directory to open the hub from. Defaults to the current
---one.

---The options of a review: which changes it shows.
---@class prohub.ReviewOpts
---@field scope? prohub.Scope Which changes the review shows. Defaults to the
---configured `default_scope`, which is `branch`.

---Open the hub for the current project or workset.
---@param opts? prohub.OpenOpts
---@return true|nil ok
---@return string? err
function M.open(opts)
    return hub.open(opts)
end

---Open a review of one worktree in its own tabpage, or go to the review of
---that worktree that is already open. `path` is a directory of the worktree,
---and prohub resolves the root of the worktree that holds it. The scope is the
---one the options name, else the configured default, which is `branch`. A name
---that is not a scope returns an error that lists the valid ones, and a path
---outside a git worktree returns an error instead of opening a review.
---@param path string Path of a directory of the worktree to review.
---@param opts? prohub.ReviewOpts
---@return true|nil ok
---@return string? err
function M.review(path, opts)
    local ok, err = validate.check({
        path = { path, 'string' },
        opts = { opts, 'table', true },
    })
    if not ok then
        return nil, err
    end

    return review.open(path, opts)
end

return M
