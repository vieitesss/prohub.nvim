---The one place prohub runs git. Every function takes the path of the worktree
---explicitly, as an absolute path, and never reads the current directory of the
---editor.
---
---prohub returns `nil` and an error directly for invalid arguments, an invalid
---worktree path or a git command that cannot be started. Neither form throws.
---For a command that started, `run` delivers git's untouched standard output,
---or `nil`, an error and the exit status, through a callback later on the main
---loop. `run_sync` returns the same outcome directly.
---
---    local git = require('prohub.git')
---
---    -- Async: the callback runs on the main loop, so it can use the API.
---    git.run(path, { 'status', '--porcelain=v2' }, function(out, err)
---        if not out then
---            return
---        end
---    end)
---
---    -- Sync: only where the caller needs the value right away.
---    local top, err = git.run_sync(path, { 'rev-parse', '--show-toplevel' })
---@class prohub.git
local M = {}

local log = require('prohub.log')
local paths = require('prohub.path')
local validate = require('prohub.validate')

---The variables that point git at a project other than the worktree it is
---given. Every command runs without them, so an editor started from a git hook
---or from a script still reads the project of the worktree path.
---@type string[]
local git_environment = {
    'GIT_DIR',
    'GIT_WORK_TREE',
    'GIT_INDEX_FILE',
    'GIT_COMMON_DIR',
    'GIT_OBJECT_DIRECTORY',
    'GIT_ALTERNATE_OBJECT_DIRECTORIES',
    'GIT_NAMESPACE',
    'GIT_PREFIX',
}

---Milliseconds a git command may run before it is killed.
---@type integer
M.timeout = 10000

---Check the arguments and the path, so each mistake gets its own message
---instead of whatever git prints.
---@param worktree any
---@param args any
---@return true|nil ok
---@return string? err
local function check_inputs(worktree, args)
    local ok, err = validate.check({
        args = { args, validate.is_string_list, 'a list of strings' },
    })
    if not ok then
        return nil, err
    end

    return paths.check(worktree)
end

---Build the git command without changing the caller's arguments.
---
---A variable that is not set needs no removal, and the editor sets none of
---them in the usual case, so the command starts git directly and pays for one
---process. `env` costs a second process, which costs as much as git itself,
---and it is the only way to remove a variable of the editor: `vim.system`
---merges its environment over the editor's, and Neovim 0.10.0 ignores it
---entirely when `clear_env` is set.
---@param path string
---@param args string[]
---@return string[] cmd
local function build(path, args)
    -- `--no-optional-locks` keeps `git status` from taking the index lock, so a
    -- refresh in the background never makes the user's own git command fail.
    local cmd =
        vim.list_extend({ 'git', '--no-optional-locks', '-C', path }, args)

    local unset = {}
    for _, name in ipairs(git_environment) do
        if vim.env[name] ~= nil then
            table.insert(unset, '-u')
            table.insert(unset, name)
        end
    end
    if #unset == 0 or vim.fn.executable('env') ~= 1 then
        return cmd
    end
    return vim.list_extend(vim.list_extend({ 'env' }, unset), cmd)
end

---Turn what `vim.system` returned into the result of the helper.
---@param path string
---@param command string
---@param result vim.SystemCompleted
---@return string? out
---@return string? err
---@return integer code The exit status of a command that ran.
local function interpret(path, command, result)
    if result.code == 0 then
        log.debug('git %s: ok', command)
        return result.stdout or '', nil, 0
    end

    local err
    if result.code == 124 and result.signal ~= 0 then
        err = ('prohub: git %s timed out after %d ms in %s'):format(
            command,
            M.timeout,
            path
        )
    else
        local detail = vim.trim(result.stderr or '')
        if detail == '' then
            detail = ('exit code %d'):format(result.code)
        end
        err = ('prohub: git %s failed in %s: %s'):format(command, path, detail)
    end
    log.debug('%s', err)
    return nil, err, result.code
end

---Error for a git that could not be started at all, such as a missing binary.
---@param spawn_err any
---@return string
local function spawn_error(spawn_err)
    local err = ('prohub: could not run git: %s'):format(tostring(spawn_err))
    log.warn('%s', err)
    return err
end

---Run git in a worktree without blocking the editor. Return `nil` and an error
---for invalid arguments, an invalid path or a command that cannot be started,
---without calling the callback.
---
---Return `true` when the command starts. The callback receives the output, or
---`nil`, an error and the exit status of a command that ran, and always runs
---later on the main loop.
---@param path string Absolute path of the worktree.
---@param args string[] Arguments of git, after `git -C path`.
---@param callback fun(out: string?, err: string?, code: integer?)
---@return true|nil ok
---@return string? err
function M.run(path, args, callback)
    local ok, err = validate.check({ callback = { callback, 'function' } })
    if not ok then
        return nil, err
    end
    ok, err = check_inputs(path, args)
    if not ok then
        return nil, err
    end

    local cmd = build(path, args)
    local command = table.concat(args, ' ')
    local function finish(result)
        vim.schedule(function()
            callback(interpret(path, command, result))
        end)
    end

    ok, err = pcall(vim.system, cmd, { timeout = M.timeout }, finish)
    if not ok then
        return nil, spawn_error(err)
    end

    return true
end

---Run git in a worktree and wait for it. Prefer `run` anywhere the editor
---should stay responsive, such as a timer or an autocommand.
---@param path string Absolute path of the worktree.
---@param args string[] Arguments of git, after `git -C path`.
---@return string? out
---@return string? err
---@return integer? code The exit status of a command that ran.
function M.run_sync(path, args)
    local valid, err = check_inputs(path, args)
    if not valid then
        return nil, err
    end

    local cmd = build(path, args)
    local command = table.concat(args, ' ')
    -- `wait` must outlast the timeout of the command itself, which kills git
    -- and reports the timeout. With the same limit the two race, and `wait`
    -- gives up first with no result.
    local ok, result = pcall(function()
        local wait = M.timeout + 1000
        return vim.system(cmd, { timeout = M.timeout }):wait(wait)
    end)
    if not ok or not result then
        return nil, spawn_error(result or 'git gave no result')
    end

    return interpret(path, command, result)
end

return M
