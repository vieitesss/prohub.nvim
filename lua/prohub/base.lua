---The base of a worktree: the commit where the branch under review left the
---default branch of the project. prohub computes it from git every time it is
---needed and never stores it, so a default branch that moves produces a new
---base on the next refresh.
---
---The default branch is resolved in this order: the `default_branch` option,
---`origin/HEAD`, a local `main` and then a local `master`. Once a name is
---known, the `origin/<name>` ref is used when it exists and the local ref
---otherwise, because the remote ref is what the rest of the project shares. An
---option that names no branch falls through to the rest of the order.
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
local validate = require('prohub.validate')

---The result of a resolution. `base` and `reason` never appear together: the
---first says where the branch under review left the default branch, and the
---second says why no base exists. `branch` and `ref` are missing only when the
---project has no default branch.
---@class prohub.Base
---@field branch string? Name of the default branch, without a remote prefix.
---@field ref string? Ref of the default branch that was used, such as
---`origin/main` or `main`.
---@field base string? The base commit, missing when no base exists.
---@field reason string? Why no base exists: `no default branch`,
---`on the default branch` or `no common history`.

---The decision of the resolution before the merge-base is known.
---@class prohub.base.Decision
---@field branch string? Name of the default branch.
---@field ref string? Ref of the default branch.
---@field reason string? Why no base can exist.

---The refs that may hold the default branch. `refs/heads` and
---`refs/remotes/origin` cover every candidate, and `%(symref)` names the branch
---`origin/HEAD` points at. One command answers every question about the refs.
---@type string[]
local refs_command = {
    'for-each-ref',
    '--format=%(refname)%09%(symref)',
    'refs/heads',
    'refs/remotes/origin',
}

---The command that names the current branch. It prints `HEAD` when HEAD is
---detached, so it never fails for that reason.
---@type string[]
local current_command = { 'rev-parse', '--abbrev-ref', 'HEAD' }

---The refs of a project, as far as the default branch is concerned.
---@class prohub.base.Refs
---@field present table<string, true> Full names of the refs that exist.
---@field origin_head string? Full name of the ref `origin/HEAD` points at.

---Turn the output of `refs_command` into the refs a decision reads.
---@param text string
---@return prohub.base.Refs
local function parse_refs(text)
    local refs = { present = {} }
    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
        local name, symref = line:match('^([^\t]+)\t(.*)$')
        if name then
            refs.present[name] = true
            if name == 'refs/remotes/origin/HEAD' and symref ~= '' then
                refs.origin_head = symref
            end
        end
    end
    return refs
end

---The ref to use for a branch: the remote-tracking ref of `origin` when it
---exists, and the local ref otherwise.
---@param refs prohub.base.Refs
---@param name string Name of the branch, without a remote prefix.
---@return string? ref
local function ref_of(refs, name)
    if refs.present['refs/remotes/origin/' .. name] then
        return 'origin/' .. name
    end
    if refs.present['refs/heads/' .. name] then
        return name
    end
end

---The name and the ref of the default branch, in the order the option, then
---`origin/HEAD`, then a local `main`, then a local `master` define.
---@param option string? The `default_branch` option.
---@param refs prohub.base.Refs
---@return string? branch
---@return string? ref
local function default_branch(option, refs)
    if option then
        local ref = ref_of(refs, option)
        if ref then
            return option, ref
        end
        log.warn(
            'the default_branch option names no branch of the project: %s',
            option
        )
    end

    local origin_head = refs.origin_head
    if origin_head and refs.present[origin_head] then
        local name = origin_head:match('^refs/remotes/origin/(.+)$')
        if name then
            return name, ref_of(refs, name)
        end
    end

    for _, name in ipairs({ 'main', 'master' }) do
        if refs.present['refs/heads/' .. name] then
            return name, ref_of(refs, name)
        end
    end
end

---Decide whether a base can exist. The flow makes this decision, so both
---forms of the command agree on it.
---@param branch string? Name of the default branch, `nil` when none exists.
---@param ref string? Ref of the default branch.
---@param current string? Name of the current branch. It is only read when a
---default branch exists, so it is missing when there is none.
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
        run(refs_command, function(out, err)
            if not out then
                return done(nil, err)
            end

            local branch, ref =
                default_branch(options.default_branch, parse_refs(out))
            if not branch then
                return done(missing_base(path, decide(nil)))
            end

            run(current_command, function(current, current_err)
                if not current then
                    return done(nil, current_err)
                end

                local decision = decide(branch, ref, vim.trim(current))
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
                            -- Histories that do not meet make merge-base exit
                            -- with status 1 and print nothing, which is a base
                            -- that does not exist and not a failure.
                            return done(result_of(decision))
                        end
                        log.debug('the merge-base failed: %s', merge_err)
                        done(nil, merge_err)
                    end
                )
            end)
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
