---The refs of a worktree: the local branches, the remote-tracking refs of the
---remotes, the branch the worktree has checked out and its remote counterpart.
---One `for-each-ref` answers every question about them, so a module that needs
---a ref does not run a second command for the branch and does not restate how a
---ref is named.
---
---Every ref this module answers with is a full ref, such as `refs/heads/main`
---or `refs/remotes/origin/main`, so a tag or a ref of another kind with the
---same name never stands in for it. A caller never builds `refs/heads/...`
---itself. `ref` answers the one question that is about a name: which ref of
---this project stands for that branch, the one of `origin` when it exists and
---the local one otherwise. The remote counterpart of the checked-out branch is
---a fact of the read, in `counterpart`, because it needs the refs the read
---already has.
---
---The read covers `refs/heads` and `refs/remotes` only: those hold every
---candidate for a default branch and for a counterpart.
---
---    local refs = require('prohub.refs')
---
---    chain.run_sync(path, refs.flow)
---    local ref = refs.ref(known, 'main')
---@class prohub.refs
local M = {}

---The refs of a worktree.
---@class prohub.Refs
---@field branch string? Name of the branch the worktree has checked out,
---missing when HEAD is detached.
---@field heads table<string, true> Names of the local branches.
---@field origin table<string, true> Names of the branches `origin` has,
---without its `HEAD`.
---@field origin_head string? Name of the branch `origin/HEAD` points at.
---@field counterpart string? Full ref of the remote counterpart of `branch`:
---its configured upstream, on whichever remote it lives, when that ref exists,
---else `refs/remotes/origin/<branch>`. It is missing when the branch has
---none, and when HEAD is detached.

---One command answers every question about the refs. `%(HEAD)` marks the branch
---the worktree has checked out, and `%(symref)` names the branch `origin/HEAD`
---points at, so the current branch needs no command of its own. The upstream
---is the full ref the branch is configured to follow, whether or not that ref
---exists, and the read of `refs/remotes` is what tells the two apart.
---@type string[]
local command = {
    'for-each-ref',
    '--format=%(HEAD)%09%(refname)%09%(symref)%09%(upstream)',
    'refs/heads',
    'refs/remotes',
}

---Read the branch a line names, and remember the refs the counterpart rule
---needs. The upstream is kept aside because whether it still exists is only
---known once every line is read.
---@param known prohub.Refs
---@param present table<string, true> Full names of the refs that exist.
---@param line string
---@return string? upstream Full name of the upstream of the checked-out branch.
local function read_line(known, present, line)
    local marker, ref, symref, upstream =
        line:match('^(.)\t([^\t]+)\t([^\t]*)\t(.*)$')
    if not ref then
        return nil
    end
    present[ref] = true

    local head = ref:match('^refs/heads/(.+)$')
    if head then
        known.heads[head] = true
        if marker == '*' then
            known.branch = head
            return upstream ~= '' and upstream or nil
        end
        return nil
    end

    local remote = ref:match('^refs/remotes/origin/(.+)$')
    if not remote then
        return nil
    end
    if remote == 'HEAD' then
        known.origin_head = symref:match('^refs/remotes/origin/(.+)$')
        return nil
    end
    known.origin[remote] = true
    return nil
end

---Turn the output of `command` into the refs of the worktree.
---@param text string
---@return prohub.Refs
local function parse(text)
    local known = { heads = {}, origin = {} }
    local present = {}
    local upstream

    for _, line in ipairs(vim.split(text, '\n', { plain = true })) do
        local line_upstream = read_line(known, present, line)
        if line_upstream then
            upstream = line_upstream
        end
    end

    if upstream and present[upstream] then
        known.counterpart = upstream
    elseif known.branch and known.origin[known.branch] then
        known.counterpart = 'refs/remotes/origin/' .. known.branch
    end
    return known
end

---The read of the refs of a worktree: run the command and parse its output.
---The read is a flow, so a chain of any kind runs it.
---@type prohub.chain.Flow
function M.flow(run, done)
    run(command, function(out, err)
        if not out then
            return done(nil, err)
        end
        done(parse(out))
    end)
end

---The ref of a branch: the ref of `origin` when it exists, because the remote
---ref is what the rest of the project shares, and the local ref otherwise.
---@param known prohub.Refs The refs of the worktree.
---@param name string Name of the branch, without a remote prefix.
---@return string? ref Full ref of the branch.
function M.ref(known, name)
    if known.origin[name] then
        return 'refs/remotes/origin/' .. name
    end
    if known.heads[name] then
        return 'refs/heads/' .. name
    end
end

---The name of a ref, without the directory it is stored in, which is what a
---message shows.
---@param ref string
---@return string
function M.name(ref)
    return (ref:gsub('^refs/remotes/', ''):gsub('^refs/heads/', ''))
end

return M
