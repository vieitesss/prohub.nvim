local M = {}

local config = require('prohub.config')
local review = require('prohub.review')
local validate = require('prohub.validate')

---@alias prohub.Scope 'branch'|'unpushed'|'uncommitted'

---Change the options of prohub. It is optional: `vim.g.prohub` works on its
---own, and options set after the plugin loads are honoured. A value that is
---not valid returns an error and leaves the options as they were.
---@param opts? prohub.ConfigOverrides
---@return true|nil ok
---@return string? err
function M.setup(opts)
    return config.setup(opts)
end

---@class prohub.OpenOpts
---@field cwd? string Directory to open the hub from. Defaults to the current one.

---@class prohub.ReviewOpts
---@field scope? prohub.Scope Which changes the review shows.

---Open the hub for the current project or workset.
---@param opts? prohub.OpenOpts
---@return true|nil ok
---@return string? err
function M.open(opts)
    local ok, err = validate.check({ opts = { opts, 'table', true } })
    if not ok then
        return nil, err
    end

    return nil, 'prohub: the hub is not implemented yet'
end

---Open a review of one worktree in its own tabpage, or go to the review of
---that worktree that is already open.
---@param path string Path of the worktree to review.
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
