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
---   which is the configured upstream on whichever remote it lives, else
---   `origin/<branch>`. A branch with no counterpart, or with one that shares
---   no history with `HEAD`, uses the base instead.
--- - `uncommitted` needs no revision.
---
---The rule for the remote counterpart of a branch has one home, in
---`prohub.refs`, and `prohub.status` runs `counterpart_flow` to count the
---commits the counterpart does not have.
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
local refs = require('prohub.refs')
local validate = require('prohub.validate')

---What a review needs to know about the changes it shows.
---@class prohub.ScopeResult
---@field scope prohub.Scope The scope of the changes the review shows, which
---may differ from the one that was asked for.
---@field base string? The revision the review shows the changes since. It is
---missing exactly when the scope is `uncommitted`.

---Check the arguments both forms share, then the worktree path.
---@param path any
---@param name any
---@return true|nil ok
---@return string? err
local function check_inputs(path, name)
    local ok, err = M.check(name)
    if not ok then
        return nil, err
    end
    return paths.check(path)
end

---@param ref string
---@return string[]
local function merge_base_command(ref)
    return { 'merge-base', 'HEAD', ref }
end

---Why the unpushed changes have no revision. Every part that was missing is
---named, so the user can tell which one to fix. A counterpart that the refs
---name is only passed over when it shares no history with `HEAD`.
---@param known prohub.Refs The refs of the worktree.
---@param base_reason string? Why the base of the worktree is missing.
---@return string
local function unpushed_reason(known, base_reason)
    local missing = {}
    if known.counterpart then
        table.insert(
            missing,
            refs.name(known.counterpart) .. ' shares no history with HEAD'
        )
    elseif known.branch then
        table.insert(missing, 'no upstream')
        table.insert(missing, 'no origin/' .. known.branch)
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
---remote counterpart, else the base of the worktree, else the fallback. A
---counterpart that shares no history with `HEAD` counts as none.
---@param path string
---@param options prohub.Config
---@return prohub.chain.Flow
local function unpushed_flow(path, options)
    local resolve_base = base.flow(path, options)
    return function(run, done)
        refs.flow(run, function(known, err)
            if not known then
                return done(nil, err)
            end

            -- A branch with no remote counterpart has the same unpushed changes
            -- as session changes, so the base is the revision itself.
            local function from_base()
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
                            unpushed_reason(known, result.reason)
                        )
                    )
                end)
            end

            if not known.counterpart then
                return from_base()
            end

            run(
                merge_base_command(known.counterpart),
                function(commit, merge_err, code)
                    if commit then
                        return done({
                            scope = 'unpushed',
                            base = vim.trim(commit),
                        })
                    end
                    if code == 1 then
                        -- A counterpart that shares no history with HEAD makes
                        -- merge-base exit with status 1, and every commit of
                        -- HEAD is then unpushed, as on a branch with no
                        -- counterpart.
                        return from_base()
                    end
                    done(nil, merge_err)
                end
            )
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

---The steps that name the full ref of the remote counterpart of the branch a
---worktree has checked out: the configured upstream, on whichever remote it
---lives, when its ref exists, else `origin/<branch>`. A branch with no
---counterpart, and a detached HEAD, end with nothing. `prohub.status` runs
---this flow to count the unpushed commits, so the rule has one home.
---@param path string Absolute path of the worktree.
---@return prohub.chain.Flow
function M.counterpart_flow(path)
    return function(run, done)
        refs.flow(run, function(known, err)
            if not known then
                return done(nil, err)
            end
            log.debug(
                'the remote counterpart of %s: %s',
                path,
                known.counterpart and refs.name(known.counterpart) or 'none'
            )
            done(known.counterpart)
        end)
    end
end

---The scopes a review can show, in a stable order, which is the order an error
---message lists them in.
---@return prohub.Scope[]
function M.names()
    local names = vim.tbl_keys(config.scopes)
    table.sort(names)
    return names
end

---Check that a value names a scope. A name that is not one returns an error
---that lists the valid ones.
---@param name any
---@return true|nil ok
---@return string? err
function M.check(name)
    local ok, err = validate.check({ scope = { name, 'string' } })
    if not ok then
        return nil, err
    end
    if not config.scopes[name] then
        return nil,
            ('prohub: unknown scope: %s (valid scopes: %s)'):format(
                name,
                table.concat(M.names(), ', ')
            )
    end
    return true
end

return M
