---The status of one worktree: the branch it has checked out, the counts of the
---changes git sees, and how far it is from the default branch and from its
---remote counterpart. It is what the hub shows in one row, so a collection
---reads git a handful of times and the result is cached per worktree path
---until a refresh invalidates it.
---
---A collection runs this order:
---
--- 1. `git status`, which alone answers the branch, the commit, the upstream,
---    the staged, unstaged and untracked entries, and the commits the upstream
---    does not have.
--- 2. The base of the worktree, through `prohub.base.flow`, which also names the
---    ref of the default branch.
--- 3. The commits ahead of and behind that ref.
--- 4. The files that differ between the base and the worktree, with the
---    untracked files added, which is what session changes means.
--- 5. The commits the remote counterpart does not have, when git status did not
---    already count them.
---
---A worktree on a branch with an upstream takes five commands, the main
---checkout on the default branch fewer. A branch without an upstream asks
---`prohub.scope` for its remote counterpart first, which costs two more
---commands, and the rule itself is stated only in `prohub.refs`.
---
---The cache is why `collect` is cheap to call from a timer: a cached result is
---delivered later on the main loop without running git, and two calls for the
---same path while one collection is in flight share it, so every callback is
---called exactly once. `invalidate` is what a refresh calls before collecting
---again; a collection that is still in flight for an invalidated path calls
---back but does not write its possibly stale result into the cache. Only a
---successful collection is cached: an error leaves the path as it was.
---
---`collect` is the only form of the module. Nothing needs a synchronous one
---yet, so there is none, and every callback runs later on the main loop.
---
---    local status = require('prohub.status')
---
---    status.collect(path, function(result, err) end)
---    status.invalidate(path)
---@class prohub.status
local M = {}

local base = require('prohub.base')
local chain = require('prohub.chain')
local config = require('prohub.config')
local log = require('prohub.log')
local paths = require('prohub.path')
local scope = require('prohub.scope')
local validate = require('prohub.validate')

---What the hub shows in one row.
---
---`branch` is missing when HEAD is detached, and `head` is missing before the
---first commit. `ahead` and `behind` are missing when the project has no
---default branch. `changed` and `reason` never appear together: the first is
---how many files differ between the base and the worktree, and the second says
---why there is no base. `unpushed` is missing when no remote counterpart
---exists; it never falls back to the base.
---@class prohub.Status
---@field path string Absolute path of the worktree.
---@field branch string? Name of the branch checked out, missing when HEAD is
---detached.
---@field head string? The short commit id of HEAD, missing before the first
---commit.
---@field staged integer Number of files whose changes are staged.
---@field unstaged integer Number of files with unstaged changes.
---@field untracked integer Number of files git does not track yet.
---@field ahead integer? Commits on HEAD that the default branch does not have.
---@field behind integer? Commits on the default branch that HEAD does not
---have.
---@field changed integer? Files that differ between the base and the worktree,
---counting the files git does not track yet.
---@field reason string? Why there is no base, taken from `prohub.Base`.
---@field unpushed integer? Commits on HEAD that the remote counterpart does
---not have.

---Characters of the commit id a row shows. Git's own abbreviation can be
---longer in a large project, and the row only needs enough to tell one commit
---from another.
---@type integer
local short_length = 7

---One command answers the branch, its upstream and every entry of the
---worktree. `--untracked-files=all` counts files instead of the directories
---that hold them.
---@type string[]
local status_command = {
    'status',
    '--porcelain=v2',
    '-z',
    '--branch',
    '--untracked-files=all',
}

---What `status_command` said, before the base is known.
---@class prohub.status.Snapshot
---@field branch string? Name of the branch checked out, missing when HEAD is
---detached.
---@field oid string? Full commit id of HEAD, missing before the first commit.
---@field unpushed integer? Commits HEAD has that the upstream does not, as
---git status already counted them.
---@field staged integer
---@field unstaged integer
---@field untracked string[] Paths of the files git does not track yet.

---Read the output of `status_command`.
---
---The `-z` records are separated by a null byte, so a path that holds a
---newline stays one record. A rename or a copy names its original path in a
---field of its own, which is not a record. A conflicted file counts as
---unstaged, because it has no staged change yet.
---@param text string
---@return prohub.status.Snapshot
local function parse_status(text)
    local snapshot = { staged = 0, unstaged = 0, untracked = {} }

    local tokens = vim.split(text, '\0', { plain = true })
    local index = 1
    while index <= #tokens do
        local record = tokens[index]
        index = index + 1

        local kind = record:sub(1, 1)
        if kind == '#' then
            local oid = record:match('^# branch%.oid (%S+)$')
            local head = record:match('^# branch%.head (%S+)$')
            local unpushed = record:match('^# branch%.ab %+(%d+) %-%d+$')
            if oid and oid:match('^%x+$') then
                snapshot.oid = oid
            end
            if head and head:sub(1, 1) ~= '(' then
                snapshot.branch = head
            end
            if unpushed then
                snapshot.unpushed = tonumber(unpushed)
            end
        elseif kind == '1' or kind == '2' then
            local staged, unstaged = record:sub(3, 3), record:sub(4, 4)
            if staged ~= '.' then
                snapshot.staged = snapshot.staged + 1
            end
            if unstaged ~= '.' then
                snapshot.unstaged = snapshot.unstaged + 1
            end
            if kind == '2' then
                index = index + 1
            end
        elseif kind == 'u' then
            snapshot.unstaged = snapshot.unstaged + 1
        elseif kind == '?' then
            table.insert(snapshot.untracked, record:sub(3))
        end
    end

    return snapshot
end

---Count the files of a diff and the untracked files that it does not name.
---Untracked files never appear in a diff, so the two sets are joined by path:
---a file that was removed from the index is a deletion since the base and is
---untracked at the same time, and it counts once.
---@param text string The output of `git diff --name-only -z`.
---@param untracked string[]
---@return integer
local function count_files(text, untracked)
    local seen = {}
    local count = 0

    for _, name in ipairs(vim.split(text, '\0', { plain = true })) do
        if name ~= '' and not seen[name] then
            seen[name] = true
            count = count + 1
        end
    end
    for _, name in ipairs(untracked) do
        if not seen[name] then
            seen[name] = true
            count = count + 1
        end
    end

    return count
end

---Count the commits HEAD and the default branch do not share. Both counts are
---missing when the project has no default branch, which is the only case that
---runs no command.
---@param run prohub.chain.Run
---@param ref string? Ref of the default branch.
---@param callback fun(ahead: integer?, behind: integer?, err: string?)
local function count_ahead_behind(run, ref, callback)
    if not ref then
        return callback(nil, nil)
    end

    run(
        { 'rev-list', '--left-right', '--count', ref .. '...HEAD' },
        function(out, err)
            if not out then
                return callback(nil, nil, err)
            end
            local behind, ahead = out:match('^(%d+)%s+(%d+)')
            callback(tonumber(ahead), tonumber(behind))
        end
    )
end

---Count the files that differ between the base and the worktree, the files
---git does not track yet included. It is missing when there is no base, which
---is the only case that runs no command.
---@param run prohub.chain.Run
---@param commit string? The base.
---@param untracked string[] Paths of the files git does not track yet.
---@param callback fun(changed: integer?, err: string?)
local function count_changed(run, commit, untracked, callback)
    if not commit then
        return callback(nil)
    end

    run({ 'diff', '--name-only', '-z', commit }, function(out, err)
        if not out then
            return callback(nil, err)
        end
        callback(count_files(out, untracked))
    end)
end

---Count the commits HEAD has that its remote counterpart does not. Git status
---already counted them when the branch has an upstream, so the counterpart is
---only resolved when it has none, and a branch without a counterpart, or a
---detached HEAD, has no unpushed commits to count.
---@param run prohub.chain.Run
---@param path string Absolute path of the worktree.
---@param snapshot prohub.status.Snapshot
---@param callback fun(unpushed: integer?, err: string?)
local function count_unpushed(run, path, snapshot, callback)
    if snapshot.unpushed then
        return callback(snapshot.unpushed)
    end
    if not snapshot.branch then
        return callback(nil)
    end

    scope.counterpart_flow(path)(run, function(ref, err)
        if err then
            return callback(nil, err)
        end
        if not ref then
            return callback(nil)
        end

        run({ 'rev-list', '--count', ref .. '..HEAD' }, function(out, count_err)
            if not out then
                return callback(nil, count_err)
            end
            callback(tonumber(vim.trim(out)))
        end)
    end)
end

---The steps of one collection.
---@param path string Absolute path of the worktree.
---@param options prohub.Config The options in use.
---@return prohub.chain.Flow
local function flow(path, options)
    local resolve_base = base.flow(path, options)
    return function(run, done)
        run(status_command, function(out, err)
            if not out then
                return done(nil, err)
            end

            local snapshot = parse_status(out)
            local result = {
                path = path,
                branch = snapshot.branch,
                head = snapshot.oid and snapshot.oid:sub(1, short_length),
                staged = snapshot.staged,
                unstaged = snapshot.unstaged,
                untracked = #snapshot.untracked,
            }

            resolve_base(run, function(base_result, base_err)
                if not base_result then
                    return done(nil, base_err)
                end
                result.reason = base_result.reason

                count_ahead_behind(
                    run,
                    base_result.ref,
                    function(ahead, behind, count_err)
                        if count_err then
                            return done(nil, count_err)
                        end
                        result.ahead, result.behind = ahead, behind

                        count_changed(
                            run,
                            base_result.base,
                            snapshot.untracked,
                            function(changed, changed_err)
                                if changed_err then
                                    return done(nil, changed_err)
                                end
                                result.changed = changed

                                count_unpushed(
                                    run,
                                    path,
                                    snapshot,
                                    function(unpushed, unpushed_err)
                                        if unpushed_err then
                                            return done(nil, unpushed_err)
                                        end
                                        result.unpushed = unpushed
                                        done(result)
                                    end
                                )
                            end
                        )
                    end
                )
            end)
        end)
    end
end

---The result of the last collection of each worktree path.
---@type table<string, prohub.Status>
local cache = {}

---A collection that is in flight. Every caller that arrives while it runs
---leaves its callback here, so one collection answers all of them.
---@class prohub.status.Collection
---@field callbacks fun(result: prohub.Status?, err: string?)[]
---@field stale boolean Whether an invalidation dropped the collection while it
---was still running.
---@type table<string, prohub.status.Collection>
local pending = {}

---Deliver the result of one collection to every callback that waits for it,
---and cache it unless an invalidation dropped the collection while it ran.
---@param path string
---@param collection prohub.status.Collection
---@param result prohub.Status?
---@param err string?
local function finish(path, collection, result, err)
    if pending[path] == collection then
        pending[path] = nil
    end
    if result and not collection.stale then
        cache[path] = result
    end
    for _, callback in ipairs(collection.callbacks) do
        callback(result, err)
    end
end

---Collect the status of one worktree without blocking the editor.
---
---Return `nil` and an error for invalid arguments, an invalid path or invalid
---options, without calling the callback. Otherwise the callback receives the
---status, or `nil` and an error, later on the main loop. A cached result, and
---the result of a collection that is already in flight for the same path, is
---delivered without running git; a call that joins a collection shares its
---result with every other caller of that collection. Every caller of one
---collection receives the same table, which prohub treats as read-only.
---@param path string Absolute path of the worktree.
---@param callback fun(result: prohub.Status?, err: string?)
---@return true|nil ok
---@return string? err
function M.collect(path, callback)
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

    local cached = cache[path]
    if cached then
        vim.schedule(function()
            callback(cached)
        end)
        return true
    end

    local collection = pending[path]
    if collection then
        table.insert(collection.callbacks, callback)
        return true
    end

    collection = { callbacks = { callback }, stale = false }
    pending[path] = collection

    local started, start_err = chain.run(
        path,
        flow(path, options),
        function(result, collect_err)
            finish(path, collection, result, collect_err)
        end
    )
    if not started then
        pending[path] = nil
        return nil, start_err
    end

    return true
end

---Drop the collected status of one worktree path, or of every path when no
---path is given, so that the next `collect` reads git again.
---
---A collection that is still in flight for a dropped path still calls back,
---but its result is not cached, because it may already be out of date. A call
---that arrives after the invalidation starts a new collection instead of
---joining the one it dropped.
---@param path? string Absolute path of the worktree.
---@return true|nil ok
---@return string? err
function M.invalidate(path)
    local ok, err = validate.check({ path = { path, 'string', true } })
    if not ok then
        return nil, err
    end

    if path ~= nil then
        cache[path] = nil
        local collection = pending[path]
        if collection then
            collection.stale = true
            pending[path] = nil
            log.debug('dropped the status of %s while it was collected', path)
        end
        return true
    end

    cache = {}
    for name, collection in pairs(pending) do
        collection.stale = true
        pending[name] = nil
        log.debug('dropped the status of %s while it was collected', name)
    end
    return true
end

return M
