describe('prohub.config', function()
    local config

    -- The module keeps the options of `setup`, so each case starts from a
    -- module that has never been set up, and from an unset `vim.g.prohub`.
    local function reload()
        vim.g.prohub = nil
        package.loaded['prohub'] = nil
        package.loaded['prohub.config'] = nil
        config = require('prohub.config')
    end

    before_each(reload)

    after_each(function()
        vim.g.prohub = nil
    end)

    it('returns the defaults when nothing is configured', function()
        local options, err = config.get()

        assert.is_nil(err)
        assert.same({
            default_scope = 'branch',
            default_branch = nil,
            diff_viewer = 'minifugit',
            refresh_interval = 5000,
            worksets = {},
            keymaps = {
                review = '<CR>',
                scope = 's',
                refresh = 'r',
                close = 'q',
                help = '?',
            },
        }, options)
    end)

    it('names the scopes a review can show', function()
        assert.same({
            branch = true,
            unpushed = true,
            uncommitted = true,
        }, config.scopes)
    end)

    it('lets vim.g.prohub override the defaults', function()
        vim.g.prohub = { refresh_interval = 1000 }

        local options = config.get()

        assert.equals(1000, options.refresh_interval)
        assert.equals('minifugit', options.diff_viewer)
        assert.equals('<CR>', options.keymaps.review)
    end)

    it('reads vim.g.prohub at call time', function()
        vim.g.prohub = { refresh_interval = 1000 }
        assert.equals(1000, config.get().refresh_interval)

        vim.g.prohub = { refresh_interval = 2000 }
        assert.equals(2000, config.get().refresh_interval)
    end)

    it('lets setup win over vim.g.prohub and win over the defaults', function()
        vim.g.prohub = { diff_viewer = 'global', default_scope = 'unpushed' }

        assert.is_true(config.setup({ diff_viewer = 'option' }))

        local options = config.get()
        assert.equals('option', options.diff_viewer)
        assert.equals('unpushed', options.default_scope)
        assert.equals(5000, options.refresh_interval)
    end)

    it('merges keymaps key by key', function()
        vim.g.prohub = { keymaps = { review = '<Leader>r', close = false } }

        assert.is_true(config.setup({ keymaps = { help = 'H' } }))

        assert.same({
            review = '<Leader>r',
            scope = 's',
            refresh = 'r',
            close = false,
            help = 'H',
        }, config.get().keymaps)
    end)

    it('is optional and accepts no options', function()
        assert.is_true(config.setup())
        assert.is_true(config.setup(nil))

        assert.equals('minifugit', config.get().diff_viewer)
    end)

    it('accepts the valid shape of every option', function()
        assert.is_true(config.setup({
            default_scope = 'uncommitted',
            default_branch = 'main',
            diff_viewer = 'minifugit',
            refresh_interval = 250,
            worksets = {
                ['/projects/one'] = { '/projects/one/a', '/projects/one/*' },
                ['/projects/two'] = function()
                    return { '/projects/two/a' }
                end,
            },
            keymaps = { review = false },
        }))

        local options = config.get()
        assert.equals('uncommitted', options.default_scope)
        assert.equals('main', options.default_branch)
        assert.equals(250, options.refresh_interval)
        assert.same({
            '/projects/one/a',
            '/projects/one/*',
        }, options.worksets['/projects/one'])
        assert.is_function(options.worksets['/projects/two'])
        assert.is_false(options.keymaps.review)
        assert.equals('s', options.keymaps.scope)
    end)

    it('rejects an invalid option and keeps the options it had', function()
        assert.is_true(config.setup({ refresh_interval = 1000 }))

        local ok, err = config.setup({ refresh_interval = 0 })

        assert.is_nil(ok)
        assert.is_truthy(err:find('refresh_interval', 1, true))
        assert.equals(1000, config.get().refresh_interval)
    end)

    it('names the option of every invalid value', function()
        local cases = {
            { 'default_scope', { default_scope = 'everything' } },
            { 'default_scope', { default_scope = true } },
            { 'default_branch', { default_branch = '' } },
            { 'diff_viewer', { diff_viewer = '' } },
            { 'refresh_interval', { refresh_interval = 0 } },
            { 'refresh_interval', { refresh_interval = '5000' } },
            { 'refresh_interval', { refresh_interval = 1.5 } },
            { 'keymaps.review', { keymaps = { review = 3 } } },
            { 'keymaps', { keymaps = 'review' } },
            {
                'worksets./projects/one',
                { worksets = { ['/projects/one'] = 3 } },
            },
            {
                'worksets./projects/one',
                { worksets = { ['/projects/one'] = { 'a', 2 } } },
            },
        }

        for _, case in ipairs(cases) do
            local ok, err = config.setup(case[2])

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(
                err:find(case[1], 1, true),
                ('%s does not name %s'):format(err, case[1])
            )
        end
    end)

    it('rejects an unknown option', function()
        local ok, err = config.setup({ keymap = { review = 'x' } })
        assert.is_nil(ok)
        assert.is_truthy(err:find('keymap', 1, true))

        ok, err = config.setup({ keymaps = { refesh = 'r' } })
        assert.is_nil(ok)
        assert.is_truthy(err:find('keymaps.refesh', 1, true))
    end)

    it('returns an error for options that are not a table', function()
        local ok, err = config.setup('diff_viewer = minifugit')

        assert.is_nil(ok)
        assert.is_string(err)
    end)

    it('names the option of an invalid vim.g.prohub', function()
        vim.g.prohub = { keymaps = { review = 3 } }

        local options, err = config.get()

        assert.is_nil(options)
        assert.is_truthy(err:find('keymaps.review', 1, true))
    end)

    it('returns an error when vim.g.prohub is not a table', function()
        vim.g.prohub = 'diff_viewer = minifugit'

        local options, err = config.get()

        assert.is_nil(options)
        assert.is_truthy(err:find('vim.g.prohub', 1, true))
    end)

    it('keeps the options of an earlier setup call', function()
        assert.is_true(config.setup({ diff_viewer = 'first' }))
        assert.is_true(config.setup({ refresh_interval = 100 }))

        local options = config.get()
        assert.equals('first', options.diff_viewer)
        assert.equals(100, options.refresh_interval)
    end)

    it('returns options that the caller can change', function()
        local options = config.get()
        options.keymaps.review = 'x'
        options.worksets['/projects/one'] = { 'a' }

        local again = config.get()
        assert.equals('<CR>', again.keymaps.review)
        assert.same({}, again.worksets)
    end)

    it('keeps its own copy of the options given to setup', function()
        local opts = { worksets = { ['/projects/one'] = { 'a' } } }

        assert.is_true(config.setup(opts))
        opts.worksets['/projects/one'][1] = 'b'

        assert.same({ 'a' }, config.get().worksets['/projects/one'])
    end)

    it('is reached through prohub.setup', function()
        local prohub = require('prohub')

        assert.is_true(prohub.setup({ diff_viewer = 'own' }))
        assert.equals('own', require('prohub.config').get().diff_viewer)

        local ok, err = prohub.setup({ refresh_interval = 0 })
        assert.is_nil(ok)
        assert.is_truthy(err:find('refresh_interval', 1, true))
    end)
end)
