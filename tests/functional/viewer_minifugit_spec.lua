local git = require('helpers.git')

describe('prohub.viewers.minifugit', function()
    local adapter, project, previous, version

    ---Replace minifugit with a stub, as a machine without it, or with another
    ---version of it, would be seen by the adapter.
    ---@param stub table?
    local function install(stub)
        package.loaded['minifugit'] = stub
    end

    ---Make the editor report a version, so a case covers minifugit's floor on
    ---every Neovim the suite runs on.
    ---@param text string
    local function pretend(text)
        local real = version
        vim.version = setmetatable({}, {
            __call = function()
                return real.parse(text)
            end,
            __index = real,
        })
    end

    before_each(function()
        package.loaded['prohub.viewer'] = nil
        package.loaded['prohub.viewers.minifugit'] = nil
        adapter = require('prohub.viewers.minifugit')
        previous = package.loaded['minifugit']
        version = vim.version
        project = git.project()
    end)

    after_each(function()
        package.loaded['minifugit'] = previous
        vim.version = version
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
            on_close = function() end,
        }
        return vim.tbl_extend('force', ctx, overrides or {})
    end

    it(
        'passes the worktree, the base and the close callback to minifugit',
        function()
            local received
            install({
                open = function(opts)
                    received = opts
                    return true
                end,
            })

            local ctx = context()
            assert.is_true(adapter.open(ctx))

            assert.equals(ctx.path, received.cwd)
            assert.equals(ctx.base, received.base)
            assert.is_false(received.open_in_tab)
            assert.are.equal(ctx.on_close, received.on_close)

            local names = vim.tbl_keys(received)
            table.sort(names)
            assert.same({ 'base', 'cwd', 'on_close', 'open_in_tab' }, names)
        end
    )

    it('passes no base for the uncommitted changes', function()
        local received
        install({
            open = function(opts)
                received = opts
                return true
            end,
        })

        local ctx = context({ scope = 'uncommitted' })
        ctx.base = nil
        assert.is_true(adapter.open(ctx))
        assert.is_nil(received.base)
    end)

    it('passes the error of minifugit through', function()
        install({
            open = function()
                return nil, 'Not inside a git repository: /tmp/x'
            end,
        })

        local ok, err = adapter.open(context())

        assert.is_nil(ok)
        assert.equals('Not inside a git repository: /tmp/x', err)
    end)

    it('turns a minifugit that throws into an error', function()
        install({
            open = function()
                error('opts.cwd must be a string')
            end,
        })

        local ok, err = adapter.open(context())

        assert.is_nil(ok)
        assert.is_string(err)
        assert.is_truthy(err:find('opts.cwd must be a string', 1, true))
    end)

    it('returns an error when minifugit is not installed', function()
        install(nil)
        assert.is_false(
            pcall(require, 'minifugit'),
            'minifugit must not be on the runtimepath of the suite'
        )

        local ok, err = adapter.open(context())

        assert.is_nil(ok)
        assert.equals('prohub: the minifugit diff viewer is not installed', err)
    end)

    it('returns an error when minifugit has no open', function()
        install({})

        local ok, err = adapter.open(context())

        assert.is_nil(ok)
        assert.equals('prohub: the minifugit diff viewer is not installed', err)
    end)

    it('is reached through the viewer interface', function()
        local received
        install({
            open = function(opts)
                received = opts
                return true
            end,
        })

        local viewer = require('prohub.viewer')
        assert.is_true(viewer.open(context()))

        assert.equals(project.path, received.cwd)
        assert.is_false(received.open_in_tab)
    end)

    describe('check', function()
        it('is OK on a development build of Neovim 0.11', function()
            pretend('0.11.0-dev+g1234')
            install({
                open = function()
                    return true
                end,
            })

            assert.is_true(adapter.check())
        end)

        it('returns an error and advice when minifugit is absent', function()
            pretend('0.13.0')
            install(nil)

            local ok, err, advice = adapter.check()

            assert.is_nil(ok)
            assert.equals(
                'prohub: the minifugit diff viewer is not installed',
                err
            )
            assert.is_string(advice)
        end)

        it('returns an error and advice when Neovim is below 0.11', function()
            pretend('0.10.0')
            install({
                open = function()
                    return true
                end,
            })

            local ok, err, advice = adapter.check()

            assert.is_nil(ok)
            assert.is_truthy(err:find('0.11', 1, true))
            assert.is_truthy(err:find('0.10.0', 1, true))
            assert.is_truthy(advice:find('Upgrade Neovim', 1, true))
            assert.is_truthy(advice:find('diff_viewer', 1, true))
        end)
    end)
end)
