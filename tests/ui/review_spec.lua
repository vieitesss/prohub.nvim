local git = require('helpers.git')

describe('prohub review tab lifecycle', function()
    local config, prohub, review, tab
    local project, feature, fix
    local notified

    ---Reload the modules under test. The review module remembers the reviews
    ---that are open, and every module that reads the options holds the
    ---configuration module it was loaded with, so the whole plugin is loaded
    ---again and starts from defaults.
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
        config = require('prohub.config')
        review = require('prohub.review')
        tab = require('prohub.tab')
        prohub = require('prohub')
    end

    ---Close every tab but one, so a case never sees a review of another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
    end

    ---The tab-local working directory of a tabpage.
    ---@param tabpage integer
    ---@return string
    local function tab_cwd(tabpage)
        return vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabpage))
    end

    ---The number of tabpages that are open.
    ---@return integer
    local function tabs()
        return #vim.api.nvim_list_tabpages()
    end

    ---The tabpage that is current.
    ---@return integer
    local function current()
        return vim.api.nvim_get_current_tabpage()
    end

    ---A diff viewer that records its context and opens a scratch buffer in the
    ---tab of the review, which exposes its `on_close` to the case.
    ---@return prohub.Viewer viewer
    ---@return table[] calls
    local function recording_viewer()
        local calls = {}
        local function viewer(ctx)
            local buffer = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, buffer)
            table.insert(calls, {
                buffer = buffer,
                ctx = ctx,
                tabpage = current(),
            })
            return true
        end
        return viewer, calls
    end

    before_each(function()
        reload()
        notified = vim.notify
        vim.notify = function() end
        project = git.project()
        feature = project:worktree('feature')
        fix = project:worktree('fix')
    end)

    after_each(function()
        vim.notify = notified
        close_tabs()
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('opens one review per worktree, each in its own tab', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local origin = current()

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        assert.is_true(review.open(fix.path, { scope = 'uncommitted' }))

        assert.equals(2, #calls)
        local first = calls[1].tabpage
        local second = calls[2].tabpage
        assert.equals(3, tabs())
        assert.is_false(first == second)
        assert.is_false(first == origin)
        assert.is_true(vim.api.nvim_tabpage_is_valid(first))
        assert.is_true(vim.api.nvim_tabpage_is_valid(second))
        assert.equals(second, current())
    end)

    it('sets the working directory of a review tab to its worktree', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        assert.is_true(review.open(fix.path, { scope = 'uncommitted' }))

        assert.equals(feature.path, tab_cwd(calls[1].tabpage))
        assert.equals(fix.path, tab_cwd(calls[2].tabpage))
    end)

    it('reuses the tab of a review that is already open', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local origin = current()

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        local tabpage = calls[1].tabpage
        vim.api.nvim_set_current_tabpage(origin)

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))

        assert.equals(1, #calls)
        assert.equals(2, tabs())
        assert.equals(tabpage, current())
    end)

    it('reuses the tab and calls the viewer again for another scope', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        local tabpage = calls[1].tabpage
        assert.is_true(review.open(feature.path, { scope = 'branch' }))

        assert.equals(2, #calls)
        assert.equals(2, tabs())
        assert.equals(tabpage, current())
        assert.equals(tabpage, calls[2].tabpage)
        assert.equals('branch', calls[2].ctx.scope)
        assert.is_string(calls[2].ctx.base)
        assert.is_nil(calls[1].ctx.base)
    end)

    it('reuses the review of the same path with a trailing slash', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        local tabpage = calls[1].tabpage

        assert.is_true(
            review.open(feature.path .. '/', { scope = 'uncommitted' })
        )

        assert.equals(1, #calls)
        assert.equals(2, tabs())
        assert.equals(tabpage, current())
    end)

    it(
        'reuses the review of the same worktree through a symbolic link',
        function()
            local viewer, calls = recording_viewer()
            assert.is_true(config.setup({ diff_viewer = viewer }))
            local link = project.container .. '/feature-link'
            assert(vim.uv.fs_symlink(feature.path, link))

            assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
            local tabpage = calls[1].tabpage

            assert.is_true(review.open(link, { scope = 'uncommitted' }))

            assert.equals(1, #calls)
            assert.equals(2, tabs())
            assert.equals(tabpage, current())
        end
    )

    it('returns to the tab a review was opened from when it closes', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local origin = current()

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        assert.equals(2, tabs())

        calls[1].ctx.on_close()

        assert.equals(1, tabs())
        assert.equals(origin, current())
    end)

    it(
        'returns to the tab a review was opened from when its tab closes',
        function()
            local viewer, calls = recording_viewer()
            assert.is_true(config.setup({ diff_viewer = viewer }))
            local origin = current()

            assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
            local tabpage = calls[1].tabpage

            -- A tab the user went to, so the close has somewhere else to go
            -- than the tab that happens to be next to the closed one.
            vim.cmd('tabnew')
            assert.is_false(current() == origin)
            vim.cmd(
                ('tabclose %d'):format(vim.api.nvim_tabpage_get_number(tabpage))
            )

            -- Some Neovim versions report `TabClosed` before the tabpage is
            -- removed, so prohub follows the reviews again on the next turn of
            -- the main loop.
            local returned = vim.wait(1000, function()
                return current() == origin
            end)

            assert.is_false(vim.api.nvim_tabpage_is_valid(tabpage))
            assert(
                returned,
                'the review did not return to the tab it was opened from'
            )
            assert.equals(2, tabs())
        end
    )

    it(
        'returns to the hub tab when the tab it was opened from is gone',
        function()
            local viewer, calls = recording_viewer()
            assert.is_true(config.setup({ diff_viewer = viewer }))

            vim.cmd('tabnew')
            local hub = current()
            tab.mark_hub(hub)

            vim.cmd('tabnew')
            local origin = current()
            assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
            vim.cmd(
                ('tabclose %d'):format(vim.api.nvim_tabpage_get_number(origin))
            )
            assert.is_false(vim.api.nvim_tabpage_is_valid(origin))

            calls[1].ctx.on_close()

            assert.equals(hub, current())
            assert.equals(2, tabs())
        end
    )

    it('refuses a missing worktree without creating a tab', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local origin = current()

        local ok, err = review.open('/nonexistent/prohub-worktree')

        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_truthy(err:find('does not exist', 1, true))
        assert.equals(1, tabs())
        assert.equals(origin, current())
        assert.equals(0, #calls)
    end)

    it('leaves no tab behind when the viewer fails', function()
        assert.is_true(config.setup({
            diff_viewer = function()
                return nil, 'the diff viewer failed'
            end,
        }))
        local origin = current()

        local ok, err = review.open(feature.path, { scope = 'uncommitted' })

        assert.is_nil(ok)
        assert.equals('the diff viewer failed', err)
        assert.equals(1, tabs())
        assert.equals(origin, current())
    end)

    it('ignores a late close of a viewer that was replaced', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        local tabpage = calls[1].tabpage
        assert.is_true(review.open(feature.path, { scope = 'branch' }))
        local replaced = calls[1].ctx.on_close

        replaced()

        assert.is_true(vim.api.nvim_tabpage_is_valid(tabpage))
        assert.equals(tabpage, current())
        assert.equals(2, tabs())
    end)

    it('opens reviews of the worktrees of a bare layout', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local bare, main = git.bare()
        local linked = bare:worktree('feature')

        assert.is_true(review.open(main.path, { scope = 'uncommitted' }))
        assert.is_true(review.open(linked.path, { scope = 'uncommitted' }))

        assert.equals(2, #calls)
        assert.equals(3, tabs())
        assert.equals(main.path, tab_cwd(calls[1].tabpage))
        assert.equals(linked.path, tab_cwd(calls[2].tabpage))
    end)

    it(
        'reaches the same flow through prohub.review and never throws',
        function()
            local viewer, calls = recording_viewer()
            assert.is_true(config.setup({ diff_viewer = viewer }))
            local origin = current()

            local calls_with_bad_arguments = {
                function()
                    return prohub.review(nil)
                end,
                function()
                    return prohub.review(feature.path, 'branch')
                end,
                function()
                    return prohub.review(feature.path, { scope = 'everything' })
                end,
                function()
                    return prohub.review('/nonexistent/prohub-worktree')
                end,
            }
            for _, call in ipairs(calls_with_bad_arguments) do
                local called, ok, err = pcall(call)

                assert.is_true(called)
                assert.is_nil(ok)
                assert.is_string(err)
            end
            assert.equals(1, tabs())
            assert.equals(origin, current())
            assert.equals(0, #calls)

            assert.is_true(
                prohub.review(feature.path, { scope = 'uncommitted' })
            )

            assert.equals(2, tabs())
            assert.equals(1, #calls)
            assert.equals(feature.path, tab_cwd(calls[1].tabpage))
        end
    )
end)
