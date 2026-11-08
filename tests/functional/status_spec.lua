local git = require('helpers.git')
local log = require('prohub.log')
local spawns = require('helpers.spawns')

---The module under test.
local status = require('prohub.status')

describe('prohub.status', function()
    local logs

    before_each(function()
        vim.g.prohub = nil
        status.invalidate()
        logs = vim.fn.tempname()
        assert(log.configure({ file = logs .. '/prohub.log' }))
    end)

    after_each(function()
        status.invalidate()
        vim.g.prohub = nil
        git.cleanup()
        vim.fn.delete(logs, 'rf')
    end)

    ---Collect the status of a worktree and wait for the callback.
    ---@param path string
    ---@return prohub.Status|nil result
    ---@return string? err
    local function collect(path)
        local done, result, err
        local ok, start_err = status.collect(path, function(value, callback_err)
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

    ---Start a collection and hand back the state its callback fills in.
    ---@param path string
    ---@return { result: prohub.Status?, err: string?, await: fun(state): prohub.Status?, string? }
    local function in_flight(path)
        local state = { done = false }
        local ok, err = status.collect(path, function(result, callback_err)
            state.result, state.err, state.done = result, callback_err, true
        end)
        assert.is_true(ok, err)

        function state:await()
            assert(
                vim.wait(5000, function()
                    return self.done
                end),
                'the callback was not called'
            )
            return self.result, self.err
        end

        return state
    end

    ---A project on `main` and a linked worktree on `feature` with one commit on
    ---top of the initial commit, which is still the tip of `main`.
    ---@return helpers.git.Tree project
    ---@return helpers.git.Tree feature
    local function feature_project()
        local project = git.project()
        local feature = project:worktree('feature')
        feature:commit('a.txt', 'a', 'a change on the feature')
        return project, feature
    end

    describe('collect', function()
        it('reports the branch and the short commit', function()
            local _, feature = feature_project()

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(feature.path, result.path)
            assert.are.equal('feature', result.branch)
            assert.are.equal(
                feature:git('rev-parse', 'HEAD'):sub(1, 7),
                result.head
            )
        end)

        it('counts a staged change', function()
            local _, feature = feature_project()
            feature:stage('b.txt', 'b')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(1, result.staged)
            assert.are.equal(0, result.unstaged)
            assert.are.equal(0, result.untracked)
        end)

        it('counts an unstaged change', function()
            local _, feature = feature_project()
            feature:modify('a.txt', 'changed')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(0, result.staged)
            assert.are.equal(1, result.unstaged)
            assert.are.equal(0, result.untracked)
        end)

        it('counts every untracked file, even in a new directory', function()
            local _, feature = feature_project()
            feature:create('new/deep/one.txt')
            feature:create('new/two.txt')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(0, result.staged)
            assert.are.equal(0, result.unstaged)
            assert.are.equal(2, result.untracked)
        end)

        it('counts a staged rename once', function()
            local _, feature = feature_project()
            feature:git('mv', 'a.txt', 'renamed.txt')
            feature:stage('b.txt', 'b')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(2, result.staged)
            assert.are.equal(0, result.unstaged)
            assert.are.equal(0, result.untracked)
            assert.are.equal(2, result.changed)
        end)

        it('counts the commits ahead and behind the default branch', function()
            local project, feature = feature_project()
            project:commit('README.md', 'one', 'advance main')
            project:commit('README.md', 'two', 'advance main again')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(1, result.ahead)
            assert.are.equal(2, result.behind)
        end)

        it('counts the files changed since the base', function()
            local _, feature = feature_project()
            feature:create('b.txt')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal(2, result.changed)
            assert.is_nil(result.reason)
        end)

        it('reports no ahead or behind without a default branch', function()
            local project = git.project()
            project:git('branch', '--move', 'main', 'trunk')

            local result, err = collect(project.path)

            assert.is_nil(err)
            assert.is_nil(result.ahead)
            assert.is_nil(result.behind)
            assert.is_nil(result.changed)
            assert.are.equal('no default branch', result.reason)
        end)

        it('reports the main checkout on the default branch', function()
            local project = git.project()

            local result, err = collect(project.path)

            assert.is_nil(err)
            assert.are.equal('main', result.branch)
            assert.are.equal(0, result.ahead)
            assert.are.equal(0, result.behind)
            assert.is_nil(result.changed)
            assert.are.equal('on the default branch', result.reason)
            assert.is_nil(result.unpushed)
        end)

        it('reports a detached HEAD', function()
            local _, feature = feature_project()
            feature:detach()

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.is_nil(result.branch)
            assert.are.equal(
                feature:git('rev-parse', 'HEAD'):sub(1, 7),
                result.head
            )
            assert.are.equal(1, result.ahead)
            assert.are.equal(0, result.behind)
            assert.are.equal(1, result.changed)
            assert.is_nil(result.unpushed)
        end)

        it('counts the unpushed commits against the upstream', function()
            local project, feature = feature_project()
            project:push()
            feature:push()
            feature:commit('b.txt', 'b')
            feature:commit('c.txt', 'c')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.is_nil(result.reason)
            assert.are.equal(2, result.unpushed)
        end)

        it(
            'counts the unpushed commits against an upstream on another '
                .. 'remote',
            function()
                local project, feature = feature_project()
                project:push()
                feature:push()
                feature:remote('upstream')
                feature:git('push', '--quiet', 'upstream', 'HEAD')
                feature:git('branch', '--set-upstream-to', 'upstream/feature')
                feature:commit('b.txt', 'b')
                feature:commit('c.txt', 'c')

                local result, err = collect(feature.path)

                assert.is_nil(err)
                assert.is_nil(result.reason)
                assert.are.equal(2, result.unpushed)
            end
        )

        it('counts the unpushed commits against origin/<branch>', function()
            local _, feature = feature_project()
            feature:push()
            feature:git('branch', '--unset-upstream')
            feature:commit('b.txt', 'b')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal('feature', result.branch)
            assert.are.equal(1, result.unpushed)
        end)

        it(
            'reports no unpushed commits without a remote counterpart',
            function()
                local _, feature = feature_project()

                local result, err = collect(feature.path)

                assert.is_nil(err)
                assert.is_nil(result.unpushed)
            end
        )

        it('collects a worktree of a bare layout', function()
            local bare, _ = git.bare()
            local feature = bare:worktree('feature')
            feature:commit('b.txt', 'b', 'a change on the feature')

            local result, err = collect(feature.path)

            assert.is_nil(err)
            assert.are.equal('feature', result.branch)
            assert.are.equal(1, result.ahead)
            assert.are.equal(0, result.behind)
            assert.are.equal(1, result.changed)
        end)

        it('reads a pushed worktree in five git commands', function()
            local project, feature = feature_project()
            project:push()
            feature:push()
            feature:commit('b.txt', 'b')

            -- status, for-each-ref, merge-base, rev-list and diff.
            local commands = spawns.commands(function()
                collect(feature.path)
            end)

            assert.are.equal(5, #commands)
        end)

        it('returns an error for a missing path', function()
            local missing = vim.fn.tempname() .. '/missing'
            local called = false

            local ok, err = status.collect(missing, function()
                called = true
            end)

            assert.is_nil(ok)
            assert.is_truthy(err:find('does not exist', 1, true))
            assert.is_false(vim.wait(100, function()
                return called
            end))
        end)

        it('returns an error for a path that is a file', function()
            local file = vim.fn.tempname()
            vim.fn.writefile({ 'prohub' }, file)

            local ok, err = status.collect(file, function() end)
            vim.fn.delete(file)

            assert.is_nil(ok)
            assert.is_truthy(err:find('is not a directory', 1, true))
        end)

        it('returns an error when there is no callback', function()
            local project = git.project()

            local ok, err = status.collect(project.path, nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)

        it('returns an error for a path that is not a string', function()
            local ok, err = status.collect(nil, function() end)

            assert.is_nil(ok)
            assert.is_truthy(err:find('path', 1, true))
        end)

        it('returns an error outside a git project', function()
            local plain = vim.fn.tempname()
            vim.fn.mkdir(plain, 'p')

            local result, err = collect(plain)
            vim.fn.delete(plain, 'rf')

            assert.is_nil(result)
            assert.is_truthy(err:find('not a git repository', 1, true))
        end)
    end)

    describe('cache', function()
        it('serves the cached status without running git', function()
            local _, feature = feature_project()
            local first = collect(feature.path)

            local cached, commands
            commands = spawns.commands(function()
                cached = collect(feature.path)
            end)

            assert.are.equal(0, #commands)
            assert.are.equal(first, cached)
        end)

        it('delivers a cached status later on the main loop', function()
            local _, feature = feature_project()
            collect(feature.path)

            local called = false
            assert.is_true(status.collect(feature.path, function()
                assert.is_false(vim.in_fast_event())
                called = true
            end))
            assert.is_false(called)
            assert.is_true(vim.wait(1000, function()
                return called
            end))
        end)

        it('reads git again after an invalidate of one path', function()
            local project, feature = feature_project()
            local other = project:worktree('other')
            collect(feature.path)
            collect(other.path)

            status.invalidate(feature.path)

            local changed
            changed = spawns.commands(function()
                collect(feature.path)
            end)
            assert.is_true(#changed > 0)

            local kept
            kept = spawns.commands(function()
                collect(other.path)
            end)
            assert.are.equal(0, #kept)
        end)

        it('reads git again after an invalidate of every path', function()
            local project, feature = feature_project()
            local other = project:worktree('other')
            collect(feature.path)
            collect(other.path)

            assert.is_true(status.invalidate())

            local first, second
            first = spawns.commands(function()
                collect(feature.path)
            end)
            second = spawns.commands(function()
                collect(other.path)
            end)
            assert.is_true(#first > 0)
            assert.is_true(#second > 0)
        end)

        it('shares one collection among concurrent calls', function()
            local _, feature = feature_project()

            local cold
            cold = spawns.commands(function()
                collect(feature.path)
            end)
            status.invalidate()

            local first, second, shared
            shared = spawns.commands(function()
                first = in_flight(feature.path)
                second = in_flight(feature.path)
                first:await()
                second:await()
            end)

            assert.are.equal(#cold, #shared)
            assert.is_nil(first.err)
            assert.is_nil(second.err)
            assert.are.equal(first.result, second.result)
        end)

        it('drops a collection that an invalidate cut short', function()
            local _, feature = feature_project()
            local stale = in_flight(feature.path)

            status.invalidate(feature.path)

            local result, err = stale:await()
            assert.is_nil(err)
            assert.are.equal(1, result.changed)

            local commands
            commands = spawns.commands(function()
                collect(feature.path)
            end)
            assert.is_true(#commands > 0)
        end)
    end)

    describe('invalidate', function()
        it('returns an error for a path that is not a string', function()
            local ok, err = status.invalidate(42)

            assert.is_nil(ok)
            assert.is_truthy(err:find('path', 1, true))
        end)
    end)
end)
