describe('prohub', function()
    local prohub = require('prohub')
    local dir

    before_each(function()
        dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
    end)

    after_each(function()
        vim.fn.delete(dir, 'rf')
    end)

    it('exposes open and review', function()
        assert.is_function(prohub.open)
        assert.is_function(prohub.review)
    end)

    it('returns an error instead of throwing while unimplemented', function()
        local ok, err = prohub.open({ cwd = dir })
        assert.is_nil(ok)
        assert.is_string(err)

        ok, err = prohub.review(dir)
        assert.is_nil(ok)
        assert.is_string(err)
    end)

    it('returns an error instead of throwing on invalid arguments', function()
        local calls = {
            function()
                return prohub.open(false)
            end,
            function()
                return prohub.review(nil)
            end,
            function()
                return prohub.review(dir, 'branch')
            end,
        }

        for _, call in ipairs(calls) do
            local called, ok, err = pcall(call)
            assert.is_true(called)
            assert.is_nil(ok)
            assert.is_string(err)
        end
    end)
end)
