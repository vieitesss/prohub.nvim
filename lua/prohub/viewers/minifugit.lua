---The minifugit diff viewer, the one prohub opens by default.
---
---minifugit is loaded when a review opens, so a machine without it opens no
---review and gets an error instead of a fallback to another viewer. prohub owns
---the tabpage of a review (docs/adr/0003), so the review is always rendered
---into the current tab: minifugit never creates a tab here.
---
---A base revision means minifugit shows the changes since that revision in a
---read-only working tree comparison. Without one it shows the worktree as git
---status does, which is the uncommitted changes.
---
---    local minifugit = require('prohub.viewers.minifugit')
---
---    local ok, err = minifugit.open(ctx)
---@class prohub.viewers.minifugit
local M = {}

local log = require('prohub.log')

---The error a machine without minifugit gets. There is no fallback to another
---viewer: a review that cannot be drawn with the configured viewer does not
---open.
---@type string
local not_installed = 'prohub: the minifugit diff viewer is not installed'

---Open a review with minifugit.
---
---A missing minifugit, and one that has no `open` function, return an error
---that names what is missing; the reason minifugit did not load reaches the
---log, because it is useful when the plugin is there and broken. minifugit
---throws through `vim.validate` on options it does not accept, so the call runs
---under `pcall` and a throw becomes an error like any other failure.
---@param ctx prohub.ViewerContext
---@return true|nil ok
---@return string? err
function M.open(ctx)
    local found, minifugit = pcall(require, 'minifugit')
    if not found then
        log.debug('minifugit could not be loaded: %s', tostring(minifugit))
        return nil, not_installed
    end
    if type(minifugit) ~= 'table' or type(minifugit.open) ~= 'function' then
        return nil, not_installed
    end

    local called, result, err = pcall(minifugit.open, {
        cwd = ctx.path,
        base = ctx.base,
        open_in_tab = false,
        on_close = ctx.on_close,
    })
    if not called then
        return nil,
            ('prohub: the minifugit diff viewer failed: %s'):format(
                tostring(result)
            )
    end

    return result, err
end

return M
