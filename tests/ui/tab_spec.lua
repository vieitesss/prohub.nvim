local tab = require('prohub.tab')

describe('prohub.tab', function()
    ---Go back to the first tabpage and close the others.
    local function one_tabpage()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
    end

    ---Open a tabpage and return it.
    ---@return integer
    local function new_tabpage()
        vim.cmd('tabnew')
        return vim.api.nvim_get_current_tabpage()
    end

    before_each(one_tabpage)
    after_each(one_tabpage)

    it('marks a tabpage as the hub and finds it again', function()
        local first = vim.api.nvim_get_current_tabpage()
        local second = new_tabpage()

        tab.mark_hub(second)

        assert.equals(second, tab.hub())
        assert.is_true(vim.t[second].prohub_hub)
        assert.is_nil(vim.t[first].prohub_hub)
    end)

    it('finds no hub when no tabpage carries the mark', function()
        new_tabpage()

        assert.is_nil(tab.hub())
    end)

    it('drops the mark of a tabpage', function()
        local hub_tabpage = vim.api.nvim_get_current_tabpage()
        tab.mark_hub(hub_tabpage)

        tab.clear_hub(hub_tabpage)

        assert.is_nil(tab.hub())
        assert.is_nil(vim.t[hub_tabpage].prohub_hub)
    end)

    it('ignores a tabpage that is gone when the mark is dropped', function()
        local hub_tabpage = new_tabpage()
        tab.mark_hub(hub_tabpage)
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(
            vim.cmd,
            'tabclose ' .. vim.api.nvim_tabpage_get_number(hub_tabpage)
        )
        assert.is_false(vim.api.nvim_tabpage_is_valid(hub_tabpage))

        assert.is_true(pcall(tab.clear_hub, hub_tabpage))
    end)

    it('closes a tabpage when another one is open', function()
        local first = vim.api.nvim_get_current_tabpage()
        local second = new_tabpage()

        assert.is_true(tab.close(second))

        assert.is_false(vim.api.nvim_tabpage_is_valid(second))
        assert.equals(first, vim.api.nvim_get_current_tabpage())
    end)

    it('does not close the last tabpage of the editor', function()
        local only = vim.api.nvim_get_current_tabpage()

        assert.is_false(tab.close(only))

        assert.is_true(vim.api.nvim_tabpage_is_valid(only))
        assert.equals(only, vim.api.nvim_get_current_tabpage())
    end)

    it('does not close a tabpage that is gone', function()
        assert.is_false(tab.close(9999))
    end)
end)
