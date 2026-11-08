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
---The rule for the remote counterpart of a branch has one home, in
---`counterpart_flow`, and `prohub.status` runs that flow to count the commits
---the counterpart does not have.
---
---A scope that cannot be resolved falls back to the uncommitted changes, so a
---review always opens on something the user can act on. The fallback is a
---normal result, not an error: it names the scope that was used and it tells
---the user, once, through `vim.notify` why the requested scope was not shown.
---
---`resolve` and `resolve_sync` run the same flow with the two chains, and every
---asynchronous callback prohub delivers runs later on the main loop, never
---inline with the call that started the work.
---
---    local scope = require('prohub.scope')
---
---    scope.resolve(path, 'branch', function(result, err) end)
---    local result, err = scope.resolve_sync(path, 'branch')
---@class prohub.scope
local M = {}

local base = require('prohub.base')
local chain = require('prohub.chain')
local config = require('prohub.config')
local log = require('prohub.log')
local paths = require('prohub.path')
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
    return paths.check(path)
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

---The name of a ref without the directory it is stored in, the way
---`prohub.base` names the ref of the default branch.
---@param ref string
---@return string
local function short_ref(ref)
    return (ref:gsub('^refs/remotes/', ''):gsub('^refs/heads/', ''))
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

---The result of a scope that cannot be resolved: the uncommitted changes,
---after telling the user why the requested scope is not shown.
---@param name prohub.Scope The scope that was asked for.
---@param path string
---@param reason string
---@return prohub.ScopeResult
local function fallback(name, path, reason)
    log.debug('the %s scope of %s: %s', name, path, reason)
    vim.notify(
        (
            'prohub: no base for the %s scope in %s (%s), showing uncommitted '
            .. 'changes'
        ):format(name, path, reason),
        vim.log.levels.WARN
    )
    return { scope = 'uncommitted' }
end

---The steps of the branch scope: the base of the worktree, or the fallback.
---@param path string
---@param options prohub.Config
---@return prohub.chain.Flow
local function branch_flow(path, options)
    local resolve_base = base.flow(path, options)
    return function(run, done)
        resolve_base(run, function(result, err)
            if not result then
                return done(nil, err)
            end
            if not result.base then
                return done(
                    fallback('branch', path, result.reason or 'no base')
                )
            end
            done({ scope = 'branch', base = result.base })
        end)
    end
end

---The steps of the unpushed scope: the last commit `HEAD` shares with its
---remote counterpart, else the base of the worktree, else the fallback.
---@param path string
---@param options prohub.Config
---@return prohub.chain.Flow
local function unpushed_flow(path, options)
    local resolve_base = base.flow(path, options)
    return function(run, done)
        run(refs_command, function(out, err)
            if not out then
                return done(nil, err)
            end

            local refs = parse_refs(out)
            local ref = remote_ref(refs)
            if ref then
                run(merge_base_command(ref), function(commit, merge_err)
                    if not commit then
                        return done(nil, merge_err)
                    end
                    done({ scope = 'unpushed', base = vim.trim(commit) })
                end)
                return
            end

            -- A branch with no remote counterpart has the same unpushed changes
            -- as session changes, so the base is the revision itself.
            resolve_base(run, function(result, base_err)
                if not result then
                    return done(nil, base_err)
                end
                if result.base then
                    return done({ scope = 'unpushed', base = result.base })
                end
                done(
                    fallback(
                        'unpushed',
                        path,
                        unpushed_reason(refs, result.reason)
                    )
                )
            end)
        end)
    end
end

---The steps of one scope.
---@param path string
---@param name prohub.Scope
---@param options prohub.Config
---@return prohub.chain.Flow
local function flow(path, name, options)
    if name == 'uncommitted' then
        return function(_, done)
            done({ scope = 'uncommitted' })
        end
    end
    if name == 'branch' then
        return branch_flow(path, options)
    end
    return unpushed_flow(path, options)
end

---Turn a scope into the revision a review needs without blocking the editor.
---
---Return `nil` and an error for invalid arguments, an invalid path or an
---unknown scope, without calling the callback. Otherwise the callback receives
---the result, or `nil` and an error, later on the main loop. A scope that
---cannot be resolved is not an error: the result then names the uncommitted
---scope, which has no revision, and the user is told why.
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

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    return chain.run(path, flow(path, name, options), callback)
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

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    return chain.run_sync(path, flow(path, name, options))
end

---The steps that name the remote counterpart of the branch a worktree has
---checked out: the configured upstream when its ref exists, else
---`origin/<branch>`. A branch with no counterpart, and a detached HEAD, end
---with nothing. `prohub.status` runs this flow to count the unpushed commits,
---so the rule has one home.
---@param path string Absolute path of the worktree.
---@return prohub.chain.Flow
function M.counterpart_flow(path)
    return function(run, done)
        run(refs_command, function(out, err)
            if not out then
                return done(nil, err)
            end
            local ref = remote_ref(parse_refs(out))
            if ref then
                ref = short_ref(ref)
            end
            log.debug('the remote counterpart of %s: %s', path, ref or 'none')
            done(ref)
        end)
    end
end

return M
