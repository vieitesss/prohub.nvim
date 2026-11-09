---The base of a worktree: the commit where the branch under review left the
---default branch of the project. prohub computes it from git every time it is
---needed and never stores it, so a default branch that moves produces a new
---base on the next refresh.
---
---The default branch is resolved in this order: the `default_branch` option,
---`origin/HEAD`, a local `main` and then a local `master`. Once a name is
---known, the `origin/<name>` ref is used when it exists and the local ref
---otherwise, because the remote ref is what the rest of the project shares.
---The result is a full ref, such as `refs/remotes/origin/main` or
---`refs/heads/main`, so a tag of the same name never stands in for the branch.
---An option that names no branch falls through to the rest of the order.
---
---The refs of the project and the branch the worktree has checked out come from
---one read of `prohub.refs`, so a resolution reads git once before the
---merge-base.
---
---The base itself is the merge-base between `HEAD` and that ref. The worktree
---has no base when the project has no default branch, when the worktree is on
---the default branch, or when the two have no common history: in those cases
---the caller falls back to the uncommitted scope. A missing base is a normal
---result. Only bad arguments and a git command that fails for another reason
---are errors. "On the default branch" means the current branch of the worktree
---carries the name of the default branch.
---
---`resolve` and `resolve_sync` run the same flow, and every asynchronous
---callback prohub delivers runs later on the main loop, never inline with the
---call that started the work. `flow` hands that flow to a caller that runs it
---with a chain of its own, which is how `prohub.scope` reuses the resolution.
---
---    local base = require('prohub.base')
---
---    base.resolve(path, function(result, err) end)
---    local result, err = base.resolve_sync(path)
---@class prohub.base
local M = {}

local chain = require('prohub.chain')
local config = require('prohub.config')
local log = require('prohub.log')
local paths = require('prohub.path')
local refs = require('prohub.refs')
local validate = require('prohub.validate')

---The result of a resolution. `base` and `reason` never appear together: the
---first says where the branch under review left the default branch, and the
---second says why no base exists. `branch` and `ref` are missing only when the
---project has no default branch.
---@class prohub.Base
---@field branch string? Name of the default branch, without a remote prefix.
---@field ref string? Full ref of the default branch that was used, such as
---`refs/remotes/origin/main` or `refs/heads/main`.
---@field base string? The base commit, missing when no base exists.
---@field reason string? Why no base exists: `no default branch`,
---`on the default branch` or `no common history`.

---The decision of the resolution before the merge-base is known.
---@class prohub.base.Decision
---@field branch string? Name of the default branch.
---@field ref string? Full ref of the default branch.
---@field reason string? Why no base can exist.

---The name and the ref of the default branch, in the order the option, then
---`origin/HEAD`, then a local `main`, then a local `master` define.
---@param option string? The `default_branch` option.
---@param known prohub.Refs The refs of the worktree.
---@return string? branch
---@return string? ref
local function default_branch(option, known)
    if option then
        local ref = refs.ref(known, option)
        if ref then
            return option, ref
        end
        log.warn(
            'the default_branch option names no branch of the project: %s',
            option
        )
    end

    if known.origin_head then
        local ref = refs.ref(known, known.origin_head)
        if ref then
            return known.origin_head, ref
        end
    end

    for _, name in ipairs({ 'main', 'master' }) do
        if known.heads[name] then
            return name, refs.ref(known, name)
        end
    end
end

---Decide whether a base can exist. The flow makes this decision, so both
---forms of the command agree on it.
---@param branch string? Name of the default branch, `nil` when none exists.
---@param ref string? Ref of the default branch.
---@param current string? Name of the branch the worktree has checked out,
---missing when HEAD is detached.
---@return prohub.base.Decision
local function decide(branch, ref, current)
    if not branch then
        return { reason = 'no default branch' }
    end
    if current == branch then
        return { branch = branch, ref = ref, reason = 'on the default branch' }
    end
    return { branch = branch, ref = ref }
end

---Turn a decision and the merge-base into the result of the module.
---@param decision prohub.base.Decision
---@param commit string? The merge-base, missing when there is none.
---@return prohub.Base
local function result_of(decision, commit)
    local result = {}
    if decision.branch then
        result.branch = decision.branch
        result.ref = decision.ref
    end
    if decision.reason then
        result.reason = decision.reason
    elseif commit and commit ~= '' then
        result.base = commit
    else
        result.reason = 'no common history'
    end
    return result
end

---@param ref string
---@return string[] command
local function merge_base_command(ref)
    return { 'merge-base', 'HEAD', ref }
end

---The log line of a base that does not exist, and the result it belongs to.
---@param path string
---@param decision prohub.base.Decision
---@return prohub.Base
local function missing_base(path, decision)
    log.debug(
        'base of %s: %s (%s)',
        path,
        decision.reason,
        decision.branch or 'no branch'
    )
    return result_of(decision)
end

---The steps of a resolution: read the refs, decide, read the current branch
---when the decision needs it, and find the merge-base. `resolve` and
---`resolve_sync` run them with the two chains, and so does `prohub.scope` when
---it falls back to the base of a worktree.
---@param path string Absolute path of the worktree.
---@param options prohub.Config The options in use.
---@return prohub.chain.Flow
function M.flow(path, options)
    return function(run, done)
        refs.flow(run, function(known, err)
            if not known then
                return done(nil, err)
            end

            local branch, ref = default_branch(options.default_branch, known)
            if not branch then
                return done(missing_base(path, decide(nil)))
            end

            local decision = decide(branch, ref, known.branch)
            if decision.reason then
                return done(missing_base(path, decision))
            end

            run(
                merge_base_command(decision.ref),
                function(commit, merge_err, code)
                    if commit then
                        return done(result_of(decision, vim.trim(commit)))
                    end
                    if code == 1 then
                        -- Histories that do not meet make merge-base exit with
                        -- status 1 and print nothing, which is a base that does
                        -- not exist and not a failure.
                        return done(result_of(decision))
                    end
                    log.debug('the merge-base failed: %s', merge_err)
                    done(nil, merge_err)
                end
            )
        end)
    end
end

---Resolve the base of a worktree without blocking the editor.
---
---Return `nil` and an error for invalid arguments or an invalid path, without
---calling the callback. Otherwise the callback receives the result, or `nil`
---and an error, later on the main loop. A result without a base is the normal
---answer for a worktree that has none.
---@param path string Absolute path of the worktree.
---@param callback fun(result: prohub.Base?, err: string?)
---@return true|nil ok
---@return string? err
function M.resolve(path, callback)
    local ok, err = validate.check({
        path = { path, 'string' },
        callback = { callback, 'function' },
    })
    if not ok then
        return nil, err
    end

    ok, err = paths.check(path)
    if not ok then
        return nil, err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    return chain.run(path, M.flow(path, options), callback)
end

---Resolve the base of a worktree and wait for git. Prefer `resolve` anywhere
---the editor should stay responsive, such as a timer or an autocommand.
---@param path string Absolute path of the worktree.
---@return prohub.Base? result
---@return string? err
function M.resolve_sync(path)
    local ok, err = validate.check({ path = { path, 'string' } })
    if not ok then
        return nil, err
    end

    ok, err = paths.check(path)
    if not ok then
        return nil, err
    end

    local options, options_err = config.get()
    if not options then
        return nil, options_err
    end

    return chain.run_sync(path, M.flow(path, options))
end

return M
