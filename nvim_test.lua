-- Development init file for prohub.nvim. Run it from anywhere with:
--
--   nvim -u /path/to/prohub.nvim/nvim_test.lua
local source = debug.getinfo(1, 'S').source:sub(2)
local project_root = vim.fs.dirname(vim.fn.fnamemodify(source, ':p'))

vim.opt.runtimepath:prepend(project_root)
