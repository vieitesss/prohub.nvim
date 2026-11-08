---Run a chain of git commands that is written once, either without blocking
---the editor or synchronously.
---
---A chain is written as a flow: a function of `run` and `done`. `run` runs one
---git command and calls back with its output, or `nil`, an error and the exit
---status of a command that ran. `done` ends the chain with its result, or
---`nil` and an error. Every asynchronous callback prohub delivers runs later on
---the main loop, never inline with the call that started the work.
---
---The two adapters over that seam are `run`, which drives the flow with
---`prohub.git.run`, and `run_sync`, which drives it with
---`prohub.git.run_sync`. A module writes its chain once and gains both forms,
---and a module that needs the chain of another one runs its flow instead of
---restating it.
---
---    local chain = require('prohub.chain')
---
---    local flow = function(run, done)
---        run({ 'rev-parse', 'HEAD' }, function(out, err)
---            done(out and vim.trim(out) or nil, err)
---        end)
---    end
---
---    chain.run(path, flow, function(commit, err) end)
---    local commit, err = chain.run_sync(path, flow)
---@class prohub.chain
local M = {}

local git = require('prohub.git')
local validate = require('prohub.validate')

---Run one command of a flow and call back with its outcome. `out` is the
---output of a command that succeeded, `err` says why it failed, and `code` is
---the exit status of a command that ran.
---@alias prohub.chain.Run fun(args: string[], next: fun(out: string?, err: string?, code: integer?))

---End a flow with its result, or `nil` and an error.
---@alias prohub.chain.Done fun(result: any, err: string?)

---The steps of a chain, written once and driven by either adapter.
---@alias prohub.chain.Flow fun(run: prohub.chain.Run, done: prohub.chain.Done)

---Run the flow without blocking the editor and call `callback` with its
---result, or `nil` and an error, later on the main loop.
---@param path string Absolute path of the worktree the commands run in.
---@param flow prohub.chain.Flow
---@param callback fun(result: any, err: string?)
---@return true|nil ok
---@return string? err
function M.run(path, flow, callback)
    local ok, err = validate.check({
        path = { path, 'string' },
        flow = { flow, 'function' },
        callback = { callback, 'function' },
    })
    if not ok then
        return nil, err
    end

    flow(function(args, next)
        local started, start_err = git.run(path, args, next)
        if not started then
            next(nil, start_err)
        end
    end, function(result, failure)
        vim.schedule(function()
            callback(result, failure)
        end)
    end)
    return true
end

---Run the flow and wait for every command. Prefer `run` anywhere the editor
---should stay responsive, such as a timer or an autocommand.
---@param path string Absolute path of the worktree the commands run in.
---@param flow prohub.chain.Flow
---@return any result
---@return string? err
function M.run_sync(path, flow)
    local ok, err = validate.check({
        path = { path, 'string' },
        flow = { flow, 'function' },
    })
    if not ok then
        return nil, err
    end

    local result, failure
    flow(function(args, next)
        next(git.run_sync(path, args))
    end, function(value, flow_err)
        result, failure = value, flow_err
    end)
    return result, failure
end

return M
