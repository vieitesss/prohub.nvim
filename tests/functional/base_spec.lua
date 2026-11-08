local git = require('helpers.git')
local log = require('prohub.log')

---The modules under test.
local base = require('prohub.base')
local chain = require('prohub.chain')
local config = require('prohub.config')

describe('prohub.base', function()
    local logs

    before_each(function()
        vim.g.prohub = nil
        logs = vim.fn.tempname()
        assert(log.configure({ file = logs .. '/prohub.log' }))
    end)

    after_each(function()
        vim.g.prohub = nil
        git.cleanup()
        vim.fn.delete(logs, 'rf')
    end)

    ---A project on `main` and a linked worktree on `feature` with one commit on
    ---top of the initial commit of the project. The initial commit is still
    ---the tip of `main`.
    ---@return helpers.git.Tree project
    ---@return helpers.git.Tree feature
    local function feature_project()
        local project = git.project()
        local feature = project:worktree('feature')
        feature:commit('a.txt', 'a', 'a change on the feature')
        return project, feature
    end

    ---Run the command asynchronously and wait for its callback.
    ---@param path string
    ---@return prohub.Base|nil result
    ---@return string? err
    local function resolve_async(path)
        local done, result, err
        local ok, start_err = base.resolve(path, function(value, callback_err)
            assert.is_false(vim.in_fast_event())
            result, err, done = value, callback_err, true
        end)
        if not ok then
            return nil, start_err
        end
        assert(
            vim.wait(5000, function()
                return done
            end),
            'the callback was not called'
        )
        return result, err
    end

    ---The two forms of the command, so the same cases run against both.
    local forms = {
        sync = function(path)
            return base.resolve_sync(path)
        end,
        async = resolve_async,
    }

    for name, resolve in pairs(forms) do
        describe(name, function()
            it('resolves a local main', function()
                local project, feature = feature_project()

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'main',
                    ref = 'main',
                    base = project:git('rev-parse', 'main'),
                }, result)
            end)

            it('resolves a local master', function()
                local project = git.project()
                project:git('branch', '--move', 'main', 'master')
                local feature = project:worktree('feature')
                feature:commit('a.txt', 'a', 'a change on the feature')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'master',
                    ref = 'master',
                    base = project:git('rev-parse', 'master'),
                }, result)
            end)

            it('resolves origin/HEAD before a local main', function()
                local project = git.project()
                project:git('branch', 'trunk')
                local feature = project:worktree('feature')
                project:push()
                project:git('push', '--quiet', 'origin', 'trunk')
                project:git('remote', 'set-head', 'origin', 'trunk')
                feature:commit('a.txt', 'a', 'a change on the feature')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'trunk',
                    ref = 'origin/trunk',
                    base = project:git('rev-parse', 'trunk'),
                }, result)
            end)

            it('takes the default branch from the option', function()
                local project = git.project()
                project:git('branch', 'develop')
                local feature = project:worktree('feature')
                project:push()
                project:git('remote', 'set-head', 'origin', '--auto')
                vim.g.prohub = { default_branch = 'develop' }

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'develop',
                    ref = 'develop',
                    base = project:git('rev-parse', 'develop'),
                }, result)
            end)

            it('prefers the origin ref over the local one', function()
                local project = git.project()
                local feature = project:worktree('feature')
                project:push()
                project:commit('README.md', 'changed', 'advance main')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'main',
                    ref = 'origin/main',
                    base = project:git('rev-parse', 'origin/main'),
                }, result)
            end)

            it('reports no base when there is no default branch', function()
                local project = git.project()
                project:git('branch', '--move', 'main', 'trunk')
                local feature = project:worktree('feature')
                feature:commit('a.txt', 'a', 'a change on the feature')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({ reason = 'no default branch' }, result)
            end)

            it('reports no base on the default branch', function()
                local project = git.project()
                project:push()
                project:git('remote', 'set-head', 'origin', '--auto')

                local result, err = resolve(project.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'main',
                    ref = 'origin/main',
                    reason = 'on the default branch',
                }, result)
            end)

            it('reports no base for unrelated histories', function()
                local project = git.project()
                local feature = project:worktree('feature')
                feature:git('checkout', '--quiet', '--orphan', 'orphan')
                feature:commit('a.txt', 'a', 'an unrelated root commit')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'main',
                    ref = 'main',
                    reason = 'no common history',
                }, result)
            end)

            it('resolves a worktree of a bare layout', function()
                local bare, _ = git.bare()
                local feature = bare:worktree('feature')
                feature:commit('a.txt', 'a', 'a change on the feature')

                local result, err = resolve(feature.path)

                assert.is_nil(err)
                assert.are.same({
                    branch = 'main',
                    ref = 'main',
                    base = bare:git('rev-parse', 'main'),
                }, result)
            end)
        end)
    end

    describe('resolve', function()
        it(
            'returns an error without calling back for a missing path',
            function()
                local missing = vim.fn.tempname() .. '/missing'
                local called

                local ok, err = base.resolve(missing, function()
                    called = true
                end)

                assert.is_nil(ok)
                assert.is_truthy(err:find('does not exist', 1, true))
                assert.is_false(vim.wait(100, function()
                    return called
                end))
            end
        )

        it('returns an error when there is no callback', function()
            local project = git.project()

            local ok, err = base.resolve(project.path, nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)

        it('returns an error for a path that is not a string', function()
            local ok, err = base.resolve(nil, function() end)

            assert.is_nil(ok)
            assert.is_truthy(err:find('path', 1, true))
        end)
    end)

    describe('flow', function()
        it("hands the steps of a resolution to the caller's chain", function()
            local _, feature = feature_project()
            local options = assert(config.get())

            local result, err =
                chain.run_sync(feature.path, base.flow(feature.path, options))

            assert.are.same({ base.resolve_sync(feature.path) }, { result })
            assert.is_nil(err)
        end)
    end)

    describe('both forms', function()
        it(
            'report the same error when a command after the refs fails',
            function()
                local _, feature = feature_project()
                feature:git('symbolic-ref', 'HEAD', 'refs/heads/unborn')

                local sync_result, sync_err = base.resolve_sync(feature.path)
                local async_result, async_err = resolve_async(feature.path)

                assert.is_nil(sync_result)
                assert.is_truthy(sync_err:find('merge-base', 1, true))
                assert.is_nil(async_result)
                assert.are.equal(sync_err, async_err)
            end
        )
    end)

    describe('resolve_sync', function()
        it('returns an error for a path that is not a string', function()
            local result, err = base.resolve_sync(nil)

            assert.is_nil(result)
            assert.is_truthy(err:find('path', 1, true))
        end)

        it('returns an error outside a git project', function()
            local plain = vim.fn.tempname()
            vim.fn.mkdir(plain, 'p')

            local result, err = base.resolve_sync(plain)
            vim.fn.delete(plain, 'rf')

            assert.is_nil(result)
            assert.is_truthy(err:find('not a git repository', 1, true))
        end)
    end)
end)
