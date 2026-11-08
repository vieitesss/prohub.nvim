---The `:checkhealth prohub` command, run the way the editor runs it. The
---report itself is covered in `tests/functional/health_spec.lua`; this spec
---checks that the command draws it in a buffer and needs no window of its own.
describe('prohub health check UI', function()
    ---The health buffer the command created, if it is still open.
    ---@return integer?
    local function health_buffer()
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(buffer)
                and vim.api.nvim_buf_get_name(buffer):find('health://', 1, true)
            then
                return buffer
            end
        end
    end

    it('runs :checkhealth prohub in a buffer and closes it', function()
        local tabs = #vim.api.nvim_list_tabpages()
        local windows = #vim.api.nvim_list_wins()

        local ok, err = pcall(vim.cmd, 'checkhealth prohub')
        assert.is_true(ok, err)

        local buffer = health_buffer()
        assert.is_not_nil(buffer, 'the health check created no buffer')
        assert.equals(tabs, #vim.api.nvim_list_tabpages())
        assert.equals(windows, #vim.api.nvim_list_wins())

        -- The report is drawn once the command returns on some versions of
        -- Neovim, so the spec waits for it before it closes the buffer.
        vim.wait(2000, function()
            return #vim.api.nvim_buf_get_lines(buffer, 0, -1, false) > 1
        end, 20)

        vim.api.nvim_buf_delete(buffer, { force = true })
        assert.is_false(vim.api.nvim_buf_is_valid(buffer))
        assert.equals(tabs, #vim.api.nvim_list_tabpages())
    end)
end)
