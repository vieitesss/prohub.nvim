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

---The oldest Neovim minifugit supports, as its README states. prohub supports
---Neovim 0.10, so the default viewer needs the editor to be newer than that.
---@type string
local minimum_neovim = '0.11'

---The minifugit module, or nil when it cannot be loaded or has no `open`.
---A load that fails writes its reason to the log, because a broken install is
---worth diagnosing even though the caller only needs `nil`.
---@return table? minifugit
local function load()
    local found, minifugit = pcall(require, 'minifugit')
    if not found then
        log.debug('minifugit could not be loaded: %s', tostring(minifugit))
        return nil
    end
    if type(minifugit) ~= 'table' or type(minifugit.open) ~= 'function' then
        return nil
    end
    return minifugit
end

---Check that minifugit is installed and runs on this editor. `prohub.health`
---reports the result, and the advice names what the user can do about a
---failure.
---@return true|nil ok
---@return string? err
---@return string? advice
function M.check()
    if not load() then
        return nil,
            not_installed,
            'Install minifugit, or configure another diff viewer with the '
                .. 'diff_viewer option.'
    end

    local version = vim.version()
    -- A development build of 0.11 has the API minifugit needs, so the
    -- comparison ignores the prerelease tag and reads the numeric fields.
    local release =
        { major = version.major, minor = version.minor, patch = version.patch }
    if not vim.version.ge(release, minimum_neovim) then
        return nil,
            (
                'prohub: the minifugit diff viewer needs Neovim %s or newer, '
                .. 'and this is %s'
            ):format(minimum_neovim, tostring(version)),
            (
                'Upgrade Neovim to %s or newer, or configure another diff '
                .. 'viewer with the diff_viewer option.'
            ):format(minimum_neovim)
    end

    return true
end

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
    local minifugit = load()
    if not minifugit then
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
