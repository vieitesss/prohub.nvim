if vim.g.loaded_prohub then
    return
end
vim.g.loaded_prohub = true

---@param err string?
local function report(err)
    if err then
        vim.notify(err, vim.log.levels.ERROR)
    end
end

vim.api.nvim_create_user_command('Prohub', function()
    local _, err = require('prohub').open()
    report(err)
end, {
    desc = 'Open the prohub worktree hub',
    force = true,
})

vim.api.nvim_create_user_command('ProhubReview', function(command)
    local path = command.fargs[1] or vim.fn.getcwd()
    local _, err = require('prohub').review(path, { scope = command.fargs[2] })
    report(err)
end, {
    nargs = '*',
    desc = 'Open a prohub review of a worktree',
    force = true,
})
