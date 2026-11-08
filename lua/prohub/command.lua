---The commands of prohub: the argument parsing and the completion of
---`:Prohub` and `:ProhubReview`, and the call into the public API that they
---make.
---
---The plugin file defines the two commands and loads this module inside their
---callbacks, so starting the editor loads nothing of prohub. The rules of the
---arguments live here, away from the commands themselves, so they can be
---checked without the editor:
---
--- - `:Prohub` takes no argument.
--- - `:ProhubReview [path] [scope]` reviews the path, which defaults to the
---   current directory, with the scope, which defaults to the scope of
---   `prohub.review`. One argument that names a scope is the scope of the
---   current directory, unless a file or directory of that name exists.
---
---A failure that the user can act on is notified once, here: the API that
---prohub exposes returns it as `nil` and an error, and never notifies it
---itself. A failure that arrives after the API returned, such as a listing git
---could not read, is notified by the module that meets it, and never reaches
---this one.
---
---    local command = require('prohub.command')
---
---    command.review({ '/projects/one', 'unpushed' })
---@class prohub.command
local M = {}

local log = require('prohub.log')
local paths = require('prohub.path')
local prohub = require('prohub')
local scope = require('prohub.scope')
local validate = require('prohub.validate')
local worktree = require('prohub.worktree')

---The arguments of `:ProhubReview`, parsed.
---@class prohub.command.ReviewArgs
---@field path string Absolute path of the worktree to review.
---@field scope? prohub.Scope The scope to show, when the command named one.

---The absolute path a command argument names: `~` and `%` are expanded, and a
---relative path is resolved against the directory the command runs in.
---@param value string The argument, as the user typed it.
---@param cwd string Absolute path of the directory the command runs in.
---@return string
local function absolute(value, cwd)
    local expanded = vim.fn.expand(value)
    return paths.normalize(vim.fn.fnamemodify(expanded, ':p'), cwd)
end

---Whether a path names a file or a directory that exists, which decides
---whether a lone argument is a scope or a path.
---@param path string
---@return boolean
local function exists(path)
    return vim.uv.fs_stat(path) ~= nil
end

---The number of the argument the cursor is on, counted from one. The lead is
---the text of that argument before the cursor, which Neovim passes on its own,
---so the arguments before it are what is left of the command line once the
---lead and the name of the command are removed.
---@param cmdline string The command line so far, without the leading `:`.
---@param cursorpos integer Position of the cursor in the command line.
---@param arglead string The argument the user is completing.
---@return integer index
local function argument_at(cmdline, cursorpos, arglead)
    local before = cmdline:sub(1, math.max(cursorpos - #arglead, 0))
    local body = before:gsub('^%s*%S*', '')

    local count = 0
    for _ in body:gmatch('%S+') do
        count = count + 1
    end
    if body == '' or body:find('%s$') then
        return count + 1
    end
    return count
end

---The worktree paths of the project of a directory, without the worktrees git
---reports as missing. A directory outside a project has none.
---@param cwd string Absolute path of the directory the command runs in.
---@return string[]
local function worktree_matches(cwd)
    local listed = worktree.list_sync(cwd)

    local matches = {}
    for _, record in ipairs(listed or {}) do
        if not record.missing then
            table.insert(matches, record.path)
        end
    end
    return matches
end

---The directories the user can enter from the current one, as the editor
---completes them.
---@param lead string The argument the user is completing.
---@return string[]
local function directory_matches(lead)
    local ok, matches = pcall(vim.fn.getcompletion, lead, 'dir')
    if not ok or type(matches) ~= 'table' then
        return {}
    end
    return matches
end

---The candidates of each group that start with the lead, once each and in the
---order of the groups.
---@param lead string The argument the user is completing.
---@param groups string[][] The candidates of each source, in the order they
---are offered.
---@return string[]
local function prefixed(lead, groups)
    local seen = {}
    local matches = {}
    for _, group in ipairs(groups) do
        for _, candidate in ipairs(group) do
            if not seen[candidate] and candidate:sub(1, #lead) == lead then
                seen[candidate] = true
                table.insert(matches, candidate)
            end
        end
    end
    return matches
end

---The completions of `:ProhubReview`, before any failure is caught.
---@param arglead string
---@param cmdline string
---@param cursorpos integer
---@return string[]
local function complete(arglead, cmdline, cursorpos)
    local names = scope.names()
    local index = argument_at(cmdline, cursorpos, arglead)
    if index == 2 then
        return prefixed(arglead, { names })
    end
    if index ~= 1 then
        return {}
    end

    return prefixed(arglead, {
        worktree_matches(vim.fn.getcwd()),
        directory_matches(arglead),
        names,
    })
end

---Report a failure the user can act on, once. Every module below either
---returns an error or notifies a failure itself, never both, so a failure
---reaches `vim.notify` exactly once.
---@param err string?
local function report(err)
    if err then
        vim.notify(err, vim.log.levels.ERROR)
    end
end

---Parse the arguments of `:ProhubReview`. A call without arguments reviews the
---current directory, a lone scope name reviews the current directory with that
---scope unless a file or directory of that name exists, and two arguments are
---the path and the scope. More than two arguments, a scope that is not one of
---the valid names, and arguments that are not a list of strings return `nil`
---and an error, and this function never throws.
---@param fargs any The arguments of the command, as Neovim passes them.
---@return prohub.command.ReviewArgs? args
---@return string? err
function M.parse_review(fargs)
    local ok, err = validate.check({
        fargs = { fargs, validate.is_string_list, 'a list of strings' },
    })
    if not ok then
        return nil, err
    end
    if #fargs > 2 then
        return nil,
            ('prohub: too many arguments: at most 2, got %d'):format(#fargs)
    end

    local cwd = vim.fn.getcwd()
    local here = paths.normalize(cwd, cwd)
    if #fargs == 0 then
        return { path = here }
    end

    local path = absolute(fargs[1], cwd)
    if #fargs == 1 and scope.check(fargs[1]) and not exists(path) then
        return { path = here, scope = fargs[1] }
    end

    local name = fargs[2]
    if name then
        local valid, scope_err = scope.check(name)
        if not valid then
            return nil, scope_err
        end
    end
    return { path = path, scope = name }
end

---Open the hub of the current directory, the way `:Prohub` does, and notify a
---failure. Arguments that are not a list of strings return `nil` and an error,
---and this function never throws.
---@param fargs any The arguments of the command, as Neovim passes them.
---@return true|nil ok
---@return string? err
function M.prohub(fargs)
    local ok, err = validate.check({
        fargs = { fargs, validate.is_string_list, 'a list of strings' },
    })
    if ok and #fargs > 0 then
        ok, err =
            nil, ('prohub: :Prohub takes no argument, got %d'):format(#fargs)
    end
    if not ok then
        report(err)
        return nil, err
    end

    local opened, open_err = prohub.open()
    report(open_err)
    return opened, open_err
end

---Open the review the command describes, the way `:ProhubReview` does, and
---notify a failure. The arguments are the ones of `parse_review`, and this
---function never throws.
---@param fargs any The arguments of the command, as Neovim passes them.
---@return true|nil ok
---@return string? err
function M.review(fargs)
    local args, err = M.parse_review(fargs)
    if not args then
        report(err)
        return nil, err
    end

    local opts = args.scope and { scope = args.scope } or nil
    local opened, open_err = prohub.review(args.path, opts)
    report(open_err)
    return opened, open_err
end

---Complete the arguments of `:ProhubReview`. The first argument completes the
---worktree paths of the project of the current directory, the directories that
---start with the lead and the scope names; the second one completes the scope
---names. Outside a git project only the directories and the scope names are
---completed, because a project has no worktree to list. A listing that fails
---offers no candidate instead of an error: completion never throws and never
---notifies.
---@param arglead string The argument the user is completing.
---@param cmdline string The command line so far, without the leading `:`.
---@param cursorpos integer Position of the cursor in the command line.
---@return string[] matches
function M.complete_review(arglead, cmdline, cursorpos)
    local ok, matches = pcall(complete, arglead, cmdline, cursorpos)
    if not ok then
        log.debug(
            'the arguments of :ProhubReview were not completed: %s',
            tostring(matches)
        )
        return {}
    end
    if not vim.islist(matches) then
        return {}
    end
    return matches
end

return M
