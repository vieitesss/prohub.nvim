---The worktrees of a project, read from `git worktree list --porcelain`.
---
---`parse` is pure: it turns the output of git into records, so a spec can
---cover every layout with a literal string. It expects the NUL terminated form
---of the command, `--porcelain -z`, because git then prints every path exactly
---as it is instead of quoting the unusual ones. `list` and `list_sync` run the
---command in a worktree and feed its output to `parse`, and every asynchronous
---callback prohub delivers runs later on the main loop, never inline with the
---call that started the work.
---
---Bare repositories are not worktrees the hub can show or review, so `parse`
---leaves them out. A worktree git reports as prunable is kept, marked as
---`missing`, so the hub can show it dimmed and refuse to review it.
---
---    local worktree = require('prohub.worktree')
---
---    local worktrees, err = worktree.list_sync(path)
---
---@class prohub.worktree
local M = {}

local chain = require('prohub.chain')
local log = require('prohub.log')
local paths = require('prohub.path')
local validate = require('prohub.validate')

---The command whose output `parse` understands.
---@type string[]
local command = { 'worktree', 'list', '--porcelain', '-z' }

---One worktree of a project.
---@class prohub.Worktree
---@field path string Absolute path of the working directory.
---@field head string Commit its HEAD points at.
---@field branch string? Name of its branch, without `refs/heads/`, or `nil`
---when HEAD is detached.
---@field detached string? Short commit when HEAD is detached, otherwise `nil`.
---@field missing boolean `true` when git reports the worktree prunable,
---which means its directory is gone.

---Split the output of git into one list of tokens per worktree. The output
---ends each field with a NUL and each worktree with a second one.
---@param text string
---@return string[][] blocks
local function split_blocks(text)
    local blocks = {}
    local block = {}
    for _, token in ipairs(vim.split(text, '\0', { plain = true })) do
        if token == '' then
            if #block > 0 then
                table.insert(blocks, block)
                block = {}
            end
        else
            table.insert(block, token)
        end
    end
    if #block > 0 then
        table.insert(blocks, block)
    end
    return blocks
end

---@param text string
---@return prohub.Worktree[]|nil worktrees
---@return string? err
function M.parse(text)
    local ok, err = validate.check({ text = { text, 'string' } })
    if not ok then
        return nil, err
    end

    local worktrees = {}
    for _, block in ipairs(split_blocks(text)) do
        local record = { missing = false }
        local detached, bare = false, false
        for _, token in ipairs(block) do
            local key, value = token:match('^(%S+) (.*)$')
            if key == 'worktree' then
                record.path = value
            elseif key == 'HEAD' then
                record.head = value
            elseif key == 'branch' then
                record.branch = (value:gsub('^refs/heads/', ''))
            elseif token == 'detached' then
                detached = true
            elseif token == 'bare' then
                bare = true
            elseif key == 'prunable' then
                record.missing = true
            end
        end
        if detached and record.head then
            -- The porcelain output only carries the full commit, so the short
            -- form is the prefix git abbreviates to by default.
            record.detached = record.head:sub(1, 7)
        end
        if not bare then
            table.insert(worktrees, record)
        end
    end

    return worktrees
end

---The steps of a listing: run the command and parse its output.
---@param path string
---@return prohub.chain.Flow
local function flow(path)
    return function(run, done)
        run(command, function(out, err)
            if not out then
                log.debug('could not list the worktrees of %s: %s', path, err)
                return done(nil, err)
            end
            done(M.parse(out))
        end)
    end
end

---List the worktrees of a project without blocking the editor, in the order
---git reports them, which puts the main checkout first unless the project has
---a bare layout and its main entry is hidden.
---
---Return `nil` and an error for invalid arguments or an invalid path, without
---calling the callback. Otherwise the callback receives the worktrees, or `nil`
---and an error, later on the main loop.
---@param path string Absolute path of any worktree or bare repository of the
---project, usually the main checkout.
---@param callback fun(worktrees: prohub.Worktree[]?, err: string?)
---@return true|nil ok
---@return string? err
function M.list(path, callback)
    local ok, err = validate.check({ callback = { callback, 'function' } })
    if not ok then
        return nil, err
    end

    ok, err = paths.check(path)
    if not ok then
        return nil, err
    end

    return chain.run(path, flow(path), callback)
end

---List the worktrees of a project and wait for git. Prefer `list` anywhere the
---editor should stay responsive.
---@param path string Absolute path of any worktree or bare repository of the
---project, usually the main checkout.
---@return prohub.Worktree[]|nil worktrees
---@return string? err
function M.list_sync(path)
    local ok, err = paths.check(path)
    if not ok then
        return nil, err
    end

    return chain.run_sync(path, flow(path))
end

return M
