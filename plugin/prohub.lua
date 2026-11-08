if vim.g.loaded_prohub then
    return
end
vim.g.loaded_prohub = true

-- Both commands only load `prohub.command` when the user runs them, and it is
-- the command module that reports a failure the user can act on.
vim.api.nvim_create_user_command('Prohub', function(command)
    require('prohub.command').prohub(command.fargs)
end, {
    desc = 'Open the prohub worktree hub',
    force = true,
})

vim.api.nvim_create_user_command('ProhubReview', function(command)
    require('prohub.command').review(command.fargs)
end, {
    nargs = '*',
    complete = function(arglead, cmdline, cursorpos)
        return require('prohub.command').complete_review(
            arglead,
            cmdline,
            cursorpos
        )
    end,
    desc = 'Open a prohub review of a worktree',
    force = true,
})
