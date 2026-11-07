---Diagnostic log of prohub. It is for whoever debugs the plugin, never for the
---user: `vim.notify` is reserved for failures the user can act on.
---
---Messages go to a file, one line each, and only when they reach the
---configured level. The default level is `WARN`, so a normal session writes
---next to nothing. Logging never throws and never blocks on the editor: a
---message that cannot be written is dropped.
---
---    local log = require('prohub.log')
---    log.debug('running %s in %s', 'git status', path)
---@class prohub.log
local M = {}

local validate = require('prohub.validate')
local levels = vim.log.levels

---@type table<integer, string>
local names = {
    [levels.DEBUG] = 'DEBUG',
    [levels.INFO] = 'INFO',
    [levels.WARN] = 'WARN',
    [levels.ERROR] = 'ERROR',
}

---@type integer
local level = levels.WARN

---@type string?
local file

---Path of the log file.
---@return string
function M.path()
    return file or vim.fs.joinpath(vim.fn.stdpath('log'), 'prohub.log')
end

---Change the level or the file. Omitted fields keep their value. Invalid
---options return an error without changing either field. The file must be a
---non-empty string.
---@param opts { level?: number, file?: string } `level` is one of
---`vim.log.levels`; `vim.log.levels.OFF` silences the log.
---@return true|nil ok
---@return string? err
function M.configure(opts)
    local ok, err = validate.check({ opts = { opts, 'table' } })
    if not ok then
        return nil, err
    end
    ok, err = validate.check({
        level = { opts.level, 'number', true },
        file = {
            opts.file,
            function(value)
                return value == nil or (type(value) == 'string' and value ~= '')
            end,
            'a non-empty string',
        },
    })
    if not ok then
        return nil, err
    end

    if opts.level ~= nil then
        level = opts.level
    end
    if opts.file ~= nil then
        file = opts.file
    end
    return true
end

---@param line string
local function append(line)
    pcall(function()
        local path = M.path()
        vim.fn.mkdir(vim.fs.dirname(path), 'p')
        local handle = assert(io.open(path, 'a'))
        handle:write(line)
        handle:close()
    end)
end

---@param message_level integer
---@param format string
---@param ... any
local function write(message_level, format, ...)
    if message_level < level then
        return
    end

    local ok, message = pcall(string.format, format, ...)
    if not ok then
        message = tostring(format)
    end
    local line = ('%s %-5s %s\n'):format(
        os.date('%Y-%m-%d %H:%M:%S'),
        names[message_level],
        message
    )

    -- The editor API is off limits inside a fast event, such as the callback
    -- of `vim.system`.
    if vim.in_fast_event() then
        vim.schedule(function()
            append(line)
        end)
    else
        append(line)
    end
end

---@param format string A `string.format` template.
---@param ... any
function M.debug(format, ...)
    write(levels.DEBUG, format, ...)
end

---@param format string A `string.format` template.
---@param ... any
function M.info(format, ...)
    write(levels.INFO, format, ...)
end

---@param format string A `string.format` template.
---@param ... any
function M.warn(format, ...)
    write(levels.WARN, format, ...)
end

---@param format string A `string.format` template.
---@param ... any
function M.error(format, ...)
    write(levels.ERROR, format, ...)
end

return M
