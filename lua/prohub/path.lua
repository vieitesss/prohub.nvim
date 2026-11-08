---The rules a worktree path obeys: what an absolute path is on this host, how
---a path is normalized, and what makes a path a directory prohub can work in.
---Every module that runs git or reads a workset shares them, so a path is
---judged the same way before it is handed to git and before it becomes a
---workset entry.
---
---`normalize` takes the directory a relative path is resolved against, so it
---never reads the current directory of the editor.
---
---    local path = require('prohub.path')
---
---    local ok, err = path.check(dir)
---@class prohub.path
local M = {}

local validate = require('prohub.validate')

---Whether a path is absolute on this host. On Windows that is a drive prefix
---or a UNC prefix; elsewhere only a leading slash, so a drive-prefixed path
---stays relative.
---@param value string
---@return boolean
local function is_absolute(value)
    if vim.fn.has('win32') == 1 then
        return value:match('^%a:[/\\]') ~= nil
            or value:match('^[/\\][/\\]') ~= nil
    end
    return value:match('^/') ~= nil
end

---Expand `~`, make a path absolute, resolve the symbolic links it may contain
---and drop a trailing slash. Both arguments are strings; the callers check
---them. The file system is only read for a path that exists, so a path that is
---about to be reported can still be normalized.
---@param value string
---@param base string Absolute directory a relative path is resolved against.
---@return string
function M.normalize(value, base)
    local result = vim.fs.normalize(value)
    if not is_absolute(result) then
        result = vim.fs.normalize(vim.fs.joinpath(base, result))
    end
    return vim.uv.fs_realpath(result) or result
end

---Check that a path is an absolute directory, the rule every command applies
---to the worktree it runs in and every workset entry applies to the worktree
---it points at.
---@param value string
---@return true|nil ok
---@return string? err
function M.check(value)
    local ok, err = validate.check({ path = { value, 'string' } })
    if not ok then
        return nil, err
    end

    if not is_absolute(value) then
        return nil, ('prohub: the path must be absolute: %s'):format(value)
    end

    local stat = vim.uv.fs_stat(value)
    if not stat then
        return nil, ('prohub: the path does not exist: %s'):format(value)
    end
    if stat.type ~= 'directory' then
        return nil, ('prohub: the path is not a directory: %s'):format(value)
    end
    return true
end

return M
