local git = require('helpers.git')

describe('prohub', function()
    local prohub, config
    local origin_cwd = vim.fn.getcwd()

    ---Load the plugin again, so every case starts from the default options
    ---and from no tabpage of another one.
    local function reload()
        local names = {}
        for name in pairs(package.loaded) do
            if name == 'prohub' or name:match('^prohub%.') then
                table.insert(names, name)
            end
        end
        for _, name in ipairs(names) do
            package.loaded[name] = nil
        end

        vim.g.prohub = nil
        prohub = require('prohub')
        config = require('prohub.config')
    end

    ---Close every tab but one, so a case never sees the hub or a review of
    ---another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(buffer)
                and vim.api.nvim_buf_get_name(buffer):find('^prohub://', 1)
            then
                pcall(vim.api.nvim_buf_delete, buffer, { force = true })
            end
        end
    end

    ---The buffers of the hubs that exist.
    ---@return integer[]
    local function hub_buffers()
        local found = {}
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(buffer)
                and vim.api.nvim_buf_get_name(buffer):find('^prohub://', 1)
            then
                table.insert(found, buffer)
            end
        end
        return found
    end

    ---Wait for the hub to render, and return its buffer.
    ---@return integer buffer
    local function wait_for_hub()
        local rendered = vim.wait(5000, function()
            return #hub_buffers() > 0
        end)
        assert.is_true(rendered, 'the hub did not render')
        return hub_buffers()[1]
    end

    ---A diff viewer that records the context it is given.
    ---@return prohub.Viewer viewer
    ---@return table[] calls
    local function recording_viewer()
        local calls = {}
        return function(ctx)
            table.insert(calls, ctx)
            return true
        end,
            calls
    end

    before_each(function()
        reload()
        vim.cmd('cd ' .. vim.fn.fnameescape(origin_cwd))
    end)

    after_each(function()
        close_tabs()
        pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(origin_cwd))
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('exposes setup, open and review', function()
        assert.is_function(prohub.setup)
        assert.is_function(prohub.open)
        assert.is_function(prohub.review)
    end)

    it('changes the options with setup', function()
        local viewer = recording_viewer()

        local ok, err = prohub.setup({ diff_viewer = viewer })

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(viewer, config.get().diff_viewer)
    end)

    it('keeps the options when setup is given an invalid one', function()
        local viewer = recording_viewer()
        assert.is_true(prohub.setup({ diff_viewer = viewer }))

        local calls = {
            function()
                return prohub.setup({ diff_viewer = 42 })
            end,
            function()
                return prohub.setup('diff_viewer')
            end,
            function()
                return prohub.setup({ unknown = true })
            end,
        }

        for _, call in ipairs(calls) do
            local called, ok, err = pcall(call)
            assert.is_true(called)
            assert.is_nil(ok)
            assert.is_string(err)
            assert.equals(viewer, config.get().diff_viewer)
        end
    end)

    it('opens the hub of a project', function()
        local project = git.project()
        local before = #vim.api.nvim_list_tabpages()

        local ok, err = prohub.open({ cwd = project.path })

        assert.is_nil(err)
        assert.is_true(ok)
        assert.is_true(vim.api.nvim_buf_is_valid(wait_for_hub()))
        assert.equals(before + 1, #vim.api.nvim_list_tabpages())
    end)

    it('opens the hub of a bare layout', function()
        local bare = git.bare()
        local before = #vim.api.nvim_list_tabpages()

        local ok, err = prohub.open({ cwd = bare.path })

        assert.is_nil(err)
        assert.is_true(ok)
        local buffer = wait_for_hub()
        assert.is_true(vim.api.nvim_buf_is_valid(buffer))
        assert.equals(before + 1, #vim.api.nvim_list_tabpages())
        assert.equals(buffer, vim.api.nvim_get_current_buf())
    end)

    it('opens the review of a worktree with the branch scope', function()
        local viewer, calls = recording_viewer()
        assert.is_true(prohub.setup({ diff_viewer = viewer }))
        local project = git.project()
        local feature = project:worktree('feature')
        local before = #vim.api.nvim_list_tabpages()

        local ok, err = prohub.review(feature.path)

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(before + 1, #vim.api.nvim_list_tabpages())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].path)
        assert.equals('branch', calls[1].scope)
    end)

    it('uses the configured default scope of a review', function()
        local viewer, calls = recording_viewer()
        assert.is_true(prohub.setup({
            diff_viewer = viewer,
            default_scope = 'uncommitted',
        }))
        local project = git.project()
        local feature = project:worktree('feature')

        local ok, err = prohub.review(feature.path)

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(1, #calls)
        assert.equals('uncommitted', calls[1].scope)
    end)

    it('opens the review of a worktree of a bare layout', function()
        local viewer, calls = recording_viewer()
        assert.is_true(prohub.setup({ diff_viewer = viewer }))
        local _, main = git.bare()

        local ok, err = prohub.review(main.path, { scope = 'uncommitted' })

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(1, #calls)
        assert.equals(main.path, calls[1].path)
        assert.equals('uncommitted', calls[1].scope)
    end)

    it('returns an error instead of throwing on invalid arguments', function()
        local project = git.project()
        local file = project.path .. '/README.md'
        local before = #vim.api.nvim_list_tabpages()

        local calls = {
            function()
                return prohub.open(false)
            end,
            function()
                return prohub.open({ cwd = 42 })
            end,
            function()
                return prohub.open({ cwd = project.path .. '/missing' })
            end,
            function()
                return prohub.review(nil)
            end,
            function()
                return prohub.review(project.path, 'branch')
            end,
            function()
                return prohub.review(project.path, { scope = 42 })
            end,
            function()
                return prohub.review(project.path .. '/missing')
            end,
            function()
                return prohub.review(file)
            end,
            function()
                return prohub.review(project.path, { scope = 'everything' })
            end,
        }

        for _, call in ipairs(calls) do
            local called, ok, err = pcall(call)
            assert.is_true(called)
            assert.is_nil(ok)
            assert.is_string(err)
        end
        assert.equals(before, #vim.api.nvim_list_tabpages())
    end)

    it('names the valid scopes when the scope is unknown', function()
        local project = git.project()

        local ok, err = prohub.review(project.path, { scope = 'everything' })

        assert.is_nil(ok)
        assert.is_truthy(err:find('unknown scope: everything', 1, true))
        assert.is_truthy(err:find('branch', 1, true))
        assert.is_truthy(err:find('uncommitted', 1, true))
        assert.is_truthy(err:find('unpushed', 1, true))
    end)

    it('names the path when it is not a worktree', function()
        local plain = vim.fn.tempname()
        vim.fn.mkdir(plain, 'p')
        local before = #vim.api.nvim_list_tabpages()

        local ok, err = prohub.review(plain)
        vim.fn.delete(plain, 'rf')

        assert.is_nil(ok)
        assert.is_truthy(err:find('not a git repository', 1, true))
        assert.equals(before, #vim.api.nvim_list_tabpages())
    end)
end)
