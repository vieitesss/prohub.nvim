local M = {}

---Check argument types with the table form of `vim.validate`, the only one
---Neovim 0.10 supports, without throwing.
---@param spec table<string, {[1]: any, [2]: string, [3]: boolean?}>
---@return string? err
local function check_args(spec)
    local ok, err = pcall(vim.validate, spec)
    if not ok then
        return 'prohub: ' .. err
    end
end

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
    local err = check_args({ opts = { opts, 'table', true } })
    if err then
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
    local err = check_args({
        path = { path, 'string' },
        opts = { opts, 'table', true },
    })
    if err then
        return nil, err
    end

    return nil, 'prohub: reviews are not implemented yet'
end

return M
