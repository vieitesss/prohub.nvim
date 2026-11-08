local git = require('helpers.git')

describe('prohub.review', function()
    local config, review
    local notified
    local calls

    ---Reload the modules under test, so every case starts from defaults and
    ---from no review at all. Every module that reads the options holds the
    ---configuration module it was loaded with, so the whole plugin is loaded
    ---again.
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
    end

    ---Close every tab but one, so a case never sees a review of another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
    end

    before_each(function()
        reload()
        notified = vim.notify
        calls = {}
        assert.is_true(config.setup({
            diff_viewer = function(ctx)
                table.insert(calls, ctx)
                return true
            end,
        }))
    end)

    after_each(function()
        vim.notify = notified
        close_tabs()
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('gives the viewer the resolved scope and its base', function()
        local project = git.project()
        local feature = project:worktree('feature')
        feature:commit('a.txt', 'a', 'a change on the feature')

        assert.is_true(review.open(feature.path, { scope = 'branch' }))

        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].path)
        assert.equals('branch', calls[1].scope)
        assert.equals(40, #calls[1].base)
    end)

    it('gives the viewer no base for the uncommitted changes', function()
        local project = git.project()

        assert.is_true(review.open(project.path, { scope = 'uncommitted' }))

        assert.equals(1, #calls)
        assert.equals('uncommitted', calls[1].scope)
        assert.is_nil(calls[1].base)
    end)

    it('gives the viewer the scope a resolution falls back to', function()
        local project = git.project()
        local messages = {}
        vim.notify = function(message)
            table.insert(messages, message)
        end

        -- The project is on its default branch, so the session changes have no
        -- base and the review shows the uncommitted ones instead.
        assert.is_true(review.open(project.path, { scope = 'branch' }))

        assert.equals(1, #calls)
        assert.equals('uncommitted', calls[1].scope)
        assert.is_nil(calls[1].base)
        assert.equals(1, #messages)
    end)

    it('uses the default scope when the options name none', function()
        local project = git.project()
        assert.is_true(config.setup({ default_scope = 'uncommitted' }))

        assert.is_true(review.open(project.path))

        assert.equals(1, #calls)
        assert.equals('uncommitted', calls[1].scope)
    end)

    it('returns an error for a directory that is not a git project', function()
        local directory = vim.fn.tempname()
        vim.fn.mkdir(directory, 'p')

        local ok, err = review.open(directory)

        vim.fn.delete(directory, 'rf')
        assert.is_nil(ok)
        assert.is_string(err)
        assert.equals(0, #calls)
    end)
end)
