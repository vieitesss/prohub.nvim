---Counts the processes a step of a spec starts, and returns the commands it
---used. prohub and the fixtures under `tests/helpers` start every process
---through `vim.system`, so replacing it for the duration of the step sees them
---all. A step that must be cheap asserts on the commands it did not start:
---
---    local spawns = require('helpers.spawns')
---
---    assert.equals(0, #spawns.commands(function()
---        git.project()
---    end))
---@class helpers.spawns
local M = {}

---Run `fn` and return the command of every process it started, in order. The
---processes themselves run as usual. Raises what `fn` raised, after restoring
---`vim.system`.
---@param fn fun()
---@return string[][] commands
function M.commands(fn)
    local original = vim.system
    local commands = {}
    vim.system = function(cmd, ...)
        if type(cmd) == 'table' then
            commands[#commands + 1] = vim.deepcopy(cmd)
        else
            commands[#commands + 1] = { cmd }
        end
        return original(cmd, ...)
    end

    local ok, err = pcall(fn)
    vim.system = original
    if not ok then
        error(err, 0)
    end

    return commands
end

return M
