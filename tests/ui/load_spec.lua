describe('prohub UI', function()
    it('creates no tab, window or buffer when it is loaded', function()
        local tabs = #vim.api.nvim_list_tabpages()
        local wins = #vim.api.nvim_list_wins()
        local bufs = #vim.api.nvim_list_bufs()

        require('prohub')

        assert.equals(tabs, #vim.api.nvim_list_tabpages())
        assert.equals(wins, #vim.api.nvim_list_wins())
        assert.equals(bufs, #vim.api.nvim_list_bufs())
    end)
end)
