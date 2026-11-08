---Turn a scope into the revision a review needs. A review of the session
---changes or of the unpushed changes shows the changes since a revision,
---while a review of the uncommitted changes needs no revision at all: it
---shows the worktree as git status does.
---
---The revision of each scope comes from git every time it is asked for, so a
---default branch or a remote counterpart that moves produces a new revision
---on the next call:
---
--- - `branch` is the base of the worktree, as `prohub.base` resolves it.
--- - `unpushed` is the last commit `HEAD` shares with its remote counterpart,
---   which is the configured upstream, else `origin/<branch>`, else the base.
--- - `uncommitted` needs no revision.
---
---A scope that cannot be resolved falls back to the uncommitted changes, so a
---review always opens on something the user can act on. The fallback is a
---normal result, not an error: it names the scope that was used and it tells
---the user, once, through `vim.notify` why the requested scope was not shown.
---
---    local scope = require('prohub.scope')
---
---    scope.resolve(path, 'branch', function(result, err) end)
---    local result, err = scope.resolve_sync(path, 'branch')
---@class prohub.scope
local M = {}

local base = require('prohub.base')
local config = require('prohub.config')
local git = require('prohub.git')
local log = require('prohub.log')
local validate = require('prohub.validate')

---What a review needs to know about the changes it shows.
---@class prohub.ScopeResult
---@field scope prohub.Scope The scope of the changes the review shows, which
---may differ from the one that was asked for.
---@field base string? The revision the review shows the changes since. It is
---missing exactly when the scope is `uncommitted`.

---The refs of a worktree that the unpushed scope reads. `%(HEAD)` marks the
---branch the worktree has checked out and `%(upstream)` names its upstream, so
---one command answers every question about the unpushed changes, and a
---missing upstream is an empty field instead of a failing command.
---@type string[]
local refs_command = {
    'for-each-ref',
    '--format=%(HEAD)%09%(refname)%09%(upstream)',
    'refs/heads',
    'refs/remotes/origin',
}

---The refs of a worktree, as far as the unpushed changes are concerned.
---@class prohub.scope.Refs
---@field branch string? Name of the branch the worktree has checked out,
---missing when HEAD is detached.
---@field upstream string? Full name of the upstream of that branch.
---@field present table<string, true> Full names of the refs that exist.

---Check the arguments both forms share, then the worktree path.
---@param path any
---@param name any
---@return true|nil ok
---@return string? err
local function check_inputs(path, name)
    local ok, err = validate.check({ scope = { name, 'string' } })
    if not ok then
        return nil, err
    end
    if not config.scopes[name] then
        return nil, ('prohub: unknown scope: %s'):format(name)
    end
    return git.check_path(path)
end

---@param text string
---@return prohub.scope.Refs
local function parse_refs(text)
    local refs = { present = {} }
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
        local marker, ref, upstream = line:match('^(.)\t([^\t]+)\t(.*)$')
        if ref then
            refs.present[ref] = true
            local branch = ref:match('^refs/heads/(.+)$')
            if branch and marker == '*' then
                refs.branch = branch
                if upstream ~= '' then
                    refs.upstream = upstream
                end
            end
        end
    end
    return refs
end

---The ref whose last shared commit with `HEAD` is where the unpushed changes
---start: the configured upstream first, then `origin/<branch>`. An upstream
---whose ref is gone is skipped, so a deleted remote branch falls back the way
---a branch that was never pushed does.
---@param refs prohub.scope.Refs
---@return string? ref
local function remote_ref(refs)
    if refs.upstream and refs.present[refs.upstream] then
        return refs.upstream
    end
    if refs.branch and refs.present['refs/remotes/origin/' .. refs.branch] then
        return 'origin/' .. refs.branch
    end
end

---@param ref string
---@return string[]
local function merge_base_command(ref)
    return { 'merge-base', 'HEAD', ref }
end

---Why the unpushed changes have no revision. Every part that was missing is
---named, so the user can tell which one to fix.
---@param refs prohub.scope.Refs
---@param base_reason string? Why the base of the worktree is missing.
---@return string
local function unpushed_reason(refs, base_reason)
    local missing = {}
    if refs.branch then
        table.insert(missing, 'no upstream')
        table.insert(missing, 'no origin/' .. refs.branch)
    else
        table.insert(missing, 'a detached HEAD')
    end
    if base_reason then
        table.insert(missing, 'no base')
        table.insert(missing, base_reason)
    end
    return table.concat(missing, ', ')
end

---Tell the user which changes are shown instead, naming the scope that was
---asked for, the worktree and the reason, in one line.
---@param name prohub.Scope
---@param path string
---@param reason string
local function report_fallback(name, path, reason)
    log.debug('the %s scope of %s: %s', name, path, reason)
    vim.notify(
        (
            'prohub: no base for the %s scope in %s (%s), showing uncommitted '
            .. 'changes'
        ):format(name, path, reason),
        vim.log.levels.WARN
    )
end

---Deliver a result on the main loop, where the caller can use the API.
---@param callback fun(result: prohub.ScopeResult?, err: string?)
---@param result prohub.ScopeResult?
---@param err string?
local function deliver(callback, result, err)
    vim.schedule(function()
        callback(result, err)
    end)
end

---Deliver the uncommitted scope, after telling the user why the requested one
---is not shown.
---@param callback fun(result: prohub.ScopeResult?, err: string?)
---@param name prohub.Scope The scope that was asked for.
---@param path string
---@param reason string
local function deliver_fallback(callback, name, path, reason)
    report_fallback(name, path, reason)
    deliver(callback, { scope = 'uncommitted' })
end

---Resolve the branch scope without blocking the editor.
---@param path string
---@param callback fun(result: prohub.ScopeResult?, err: string?)
---@return true|nil ok
---@return string? err
local function resolve_branch(path, callback)
    local started, err = base.resolve(path, function(result, base_err)
        if not result then
            return deliver(callback, nil, base_err)
        end
        if not result.base then
            return deliver_fallback(
                callback,
                'branch',
                path,
                result.reason or 'no base'
            )
        end
        deliver(callback, { scope = 'branch', base = result.base })
    end)
    if not started then
        return nil, err
    end
    return true
end

---Resolve the unpushed scope without blocking the editor.
---@param path string
---@param callback fun(result: prohub.ScopeResult?, err: string?)
---@return true|nil ok
---@return string? err
local function resolve_unpushed(path, callback)
    local started, err = git.run(path, refs_command, function(out, refs_err)
        if not out then
            return deliver(callback, nil, refs_err)
        end

        local refs = parse_refs(out)
        local ref = remote_ref(refs)
        if ref then
            local began, begin_err = git.run(
                path,
                merge_base_command(ref),
                function(commit, merge_err)
                    if not commit then
                        return deliver(callback, nil, merge_err)
                    end
                    deliver(callback, {
                        scope = 'unpushed',
                        base = vim.trim(commit),
                    })
                end
            )
            if not began then
                deliver(callback, nil, begin_err)
            end
            return
        end

        -- A branch with no remote counterpart has the same unpushed changes as
        -- session changes, so the base is the revision itself.
        local began, begin_err = base.resolve(path, function(result, base_err)
            if not result then
                return deliver(callback, nil, base_err)
            end
            if result.base then
                return deliver(callback, {
                    scope = 'unpushed',
                    base = result.base,
                })
            end
            deliver_fallback(
                callback,
                'unpushed',
                path,
                unpushed_reason(refs, result.reason)
            )
        end)
        if not began then
            deliver(callback, nil, begin_err)
        end
    end)
    if not started then
        return nil, err
    end
    return true
end

---Turn a scope into the revision a review needs without blocking the editor.
---
---Return `nil` and an error for invalid arguments, an invalid path, an unknown
---scope or a git command that cannot be started, without calling the callback.
---Otherwise the callback receives the result, or `nil` and an error, later on
---the main loop. A scope that cannot be resolved is not an error: the result
---then names the uncommitted scope, which has no revision, and the user is
---told why.
---@param path string Absolute path of the worktree.
---@param name prohub.Scope Which changes the review shows.
---@param callback fun(result: prohub.ScopeResult?, err: string?)
---@return true|nil ok
---@return string? err
function M.resolve(path, name, callback)
    local ok, err = validate.check({ callback = { callback, 'function' } })
    if not ok then
        return nil, err
    end
    ok, err = check_inputs(path, name)
    if not ok then
        return nil, err
    end

    if name == 'uncommitted' then
        deliver(callback, { scope = 'uncommitted' })
        return true
    end
    if name == 'branch' then
        return resolve_branch(path, callback)
    end
    return resolve_unpushed(path, callback)
end

---Resolve the branch scope and wait for git. Prefer `resolve` anywhere the
---editor should stay responsive.
---@param path string
---@return prohub.ScopeResult? result
---@return string? err
local function resolve_branch_sync(path)
    local result, err = base.resolve_sync(path)
    if not result then
        return nil, err
    end
    if not result.base then
        report_fallback('branch', path, result.reason or 'no base')
        return { scope = 'uncommitted' }
    end
    return { scope = 'branch', base = result.base }
end

---Resolve the unpushed scope and wait for git.
---@param path string
---@return prohub.ScopeResult? result
---@return string? err
local function resolve_unpushed_sync(path)
    local out, err = git.run_sync(path, refs_command)
    if not out then
        return nil, err
    end

    local refs = parse_refs(out)
    local ref = remote_ref(refs)
    if ref then
        local commit, merge_err = git.run_sync(path, merge_base_command(ref))
        if not commit then
            return nil, merge_err
        end
        return { scope = 'unpushed', base = vim.trim(commit) }
    end

    local result, base_err = base.resolve_sync(path)
    if not result then
        return nil, base_err
    end
    if result.base then
        return { scope = 'unpushed', base = result.base }
    end

    report_fallback('unpushed', path, unpushed_reason(refs, result.reason))
    return { scope = 'uncommitted' }
end

---Turn a scope into the revision a review needs and wait for git. Prefer
---`resolve` anywhere the editor should stay responsive, such as a timer or an
---autocommand.
---@param path string Absolute path of the worktree.
---@param name prohub.Scope Which changes the review shows.
---@return prohub.ScopeResult? result
---@return string? err
function M.resolve_sync(path, name)
    local ok, err = check_inputs(path, name)
    if not ok then
        return nil, err
    end

    if name == 'uncommitted' then
        return { scope = 'uncommitted' }
    end
    if name == 'branch' then
        return resolve_branch_sync(path)
    end
    return resolve_unpushed_sync(path)
end

return M
