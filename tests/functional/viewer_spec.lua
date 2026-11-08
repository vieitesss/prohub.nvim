local git = require('helpers.git')

describe('prohub.viewer', function()
    local config, viewer, project, adapter

    -- The modules under test keep no state, but the options of `setup` live in
    -- the configuration module, so every case starts from modules that were
    -- never set up.
    local function reload()
        vim.g.prohub = nil
        package.loaded['prohub.config'] = nil
        package.loaded['prohub.viewer'] = nil
        config = require('prohub.config')
        viewer = require('prohub.viewer')
    end

    before_each(function()
        adapter = package.loaded['prohub.viewers.minifugit']
        reload()
        project = git.project()
    end)

    after_each(function()
        package.loaded['prohub.viewers.minifugit'] = adapter
        vim.g.prohub = nil
        git.cleanup()
    end)

    ---A context for a review of the session changes of the project.
    ---@param overrides? table
    ---@return prohub.ViewerContext
    local function context(overrides)
        local ctx = {
            path = project.path,
            scope = 'branch',
            base = 'abc123',
        }
        return vim.tbl_extend('force', ctx, overrides or {})
    end

    it(
        'opens a review with a viewer function and gives it the context',
        function()
            local received
            local ctx = context()
            assert.is_true(config.setup({
                diff_viewer = function(given)
                    received = given
                    return true
                end,
            }))

            assert.is_true(viewer.open(ctx))
            assert.are.equal(ctx, received)
        end
    )

    it('opens a review with a table viewer and gives it the context', function()
        local received
        local ctx = context()
        assert.is_true(config.setup({
            diff_viewer = {
                open = function(given)
                    received = given
                    return true
                end,
            },
        }))

        assert.is_true(viewer.open(ctx))
        assert.are.equal(ctx, received)
    end)

    it('opens the uncommitted changes without a base', function()
        local received
        local ctx = { path = project.path, scope = 'uncommitted' }
        assert.is_true(config.setup({
            diff_viewer = function(given)
                received = given
                return true
            end,
        }))

        assert.is_true(viewer.open(ctx))
        assert.are.equal(ctx, received)
        assert.is_nil(received.base)
    end)

    it('resolves a built-in viewer name to a callable viewer', function()
        local resolved, err = viewer.resolve('minifugit')

        assert.is_nil(err)
        assert.is_function(resolved)
    end)

    it('passes the error of a viewer through', function()
        assert.is_true(config.setup({
            diff_viewer = function()
                return nil, 'minifugit: not inside a git repository'
            end,
        }))

        local ok, err = viewer.open(context())

        assert.is_nil(ok)
        assert.equals('minifugit: not inside a git repository', err)
    end)

    it('turns a viewer that throws into an error', function()
        assert.is_true(config.setup({
            diff_viewer = function()
                error('the viewer exploded')
            end,
        }))

        local ok, err = viewer.open(context())

        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_truthy(err:find('the viewer exploded', 1, true))
    end)

    it('reports a viewer that returns something else as an error', function()
        local viewers = {
            function()
                return false
            end,
            function()
                return 'yes'
            end,
            function()
                return {}
            end,
            function()
                return nil
            end,
            function()
                return nil, nil
            end,
            function()
                return nil, 3
            end,
        }

        for _, spec in ipairs(viewers) do
            assert.is_true(config.setup({ diff_viewer = spec }))

            local ok, err = viewer.open(context())

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(err:find('diff viewer', 1, true))
        end
    end)

    it('returns an error for a viewer name it does not know', function()
        local resolved, err = viewer.resolve('nosuchviewer')

        assert.is_nil(resolved)
        assert.is_string(err)
        assert.is_truthy(err:find('nosuchviewer', 1, true))
    end)

    it('returns an error for a table viewer without open', function()
        local cases = { {}, { open = 'yes' } }

        for _, spec in ipairs(cases) do
            local resolved, err = viewer.resolve(spec)

            assert.is_nil(resolved)
            assert.is_string(err)
            assert.is_truthy(err:find('open', 1, true))
        end
    end)

    it('returns an error for a viewer of another type', function()
        local resolved, err = viewer.resolve(3)

        assert.is_nil(resolved)
        assert.is_string(err)
        assert.is_truthy(err:find('diff viewer', 1, true))
    end)

    it('returns an error for a context it cannot use', function()
        local called = false
        assert.is_true(config.setup({
            diff_viewer = function()
                called = true
                return true
            end,
        }))

        local without_base = context()
        without_base.base = nil

        local cases = {
            { nil, 'ctx' },
            { 'a path', 'ctx' },
            { context({ path = 'relative/path' }), 'absolute' },
            {
                context({ path = '/nonexistent/prohub-worktree' }),
                'does not exist',
            },
            { context({ scope = 'everything' }), 'everything' },
            { without_base, 'base' },
            { context({ scope = 'uncommitted' }), 'base' },
            { context({ scope = 'unpushed', base = '' }), 'base' },
            { context({ on_close = true }), 'on_close' },
        }

        for _, case in ipairs(cases) do
            local ok, err = viewer.open(case[1])

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(
                err:find(case[2], 1, true),
                ('%s does not name %s'):format(err, case[2])
            )
        end

        assert.is_false(called)
    end)

    it('never throws for an option that resolves to no viewer', function()
        assert.is_true(config.setup({ diff_viewer = 'nosuchviewer' }))

        local ok, err = viewer.open(context())

        assert.is_nil(ok)
        assert.is_string(err)
    end)

    describe('check', function()
        it('accepts a viewer function and a table viewer', function()
            assert.is_true(viewer.check(function()
                return true
            end))
            assert.is_true(viewer.check({
                open = function()
                    return true
                end,
            }))
        end)

        it('returns the error of a name it does not know', function()
            local ok, err = viewer.check('nosuchviewer')

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(err:find('nosuchviewer', 1, true))
        end)

        it('accepts a built-in viewer without a check of its own', function()
            package.loaded['prohub.viewers.minifugit'] = {
                open = function()
                    return true
                end,
            }

            assert.is_true(viewer.check('minifugit'))
        end)

        it('passes on what a built-in viewer reports', function()
            package.loaded['prohub.viewers.minifugit'] = {
                open = function()
                    return true
                end,
                check = function()
                    return nil, 'prohub: the viewer is broken', 'Fix it.'
                end,
            }

            local ok, err, advice = viewer.check('minifugit')

            assert.is_nil(ok)
            assert.are.equal('prohub: the viewer is broken', err)
            assert.are.equal('Fix it.', advice)
        end)

        it('turns a built-in check that throws into an error', function()
            package.loaded['prohub.viewers.minifugit'] = {
                open = function()
                    return true
                end,
                check = function()
                    error('the check exploded')
                end,
            }

            local ok, err = viewer.check('minifugit')

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(err:find('the check exploded', 1, true))
        end)

        it('returns no advice when the failure has none', function()
            local ok, err, advice = viewer.check('nosuchviewer')

            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_nil(advice)
        end)
    end)
end)
