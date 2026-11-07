local M = {}

local validate = require('prohub.validate')

---@alias prohub.Scope 'branch'|'unpushed'|'uncommitted'

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

---Open a review of one worktree.
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

    return nil, 'prohub: reviews are not implemented yet'
end

return M
