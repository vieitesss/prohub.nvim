local source = debug.getinfo(1, 'S').source:sub(2)
local tests_dir = vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))
local project_root = vim.fs.dirname(tests_dir)

vim.opt.runtimepath:prepend(project_root)
vim.opt.runtimepath:prepend(project_root .. '/plenary.nvim')
package.path = project_root
    .. '/tests/?.lua;'
    .. project_root
    .. '/lua/?.lua;'
    .. project_root
    .. '/lua/?/init.lua;'
    .. package.path
