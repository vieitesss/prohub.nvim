local git = require('helpers.git')
local log = require('prohub.log')

---The module under test.
local scope = require('prohub.scope')

describe('prohub.scope', function()
    local logs, notified

    before_each(function()
        vim.g.prohub = nil
        logs = vim.fn.tempname()
        assert(log.configure({ file = logs .. '/prohub.log' }))
        notified = vim.notify
    end)

    after_each(function()
        vim.notify = notified
        vim.g.prohub = nil
        git.cleanup()
        vim.fn.delete(logs, 'rf')
    end)

    ---Replace `vim.notify` for the case and collect what it receives.
    ---@return table[] calls
    local function capture()
        local calls = {}
        vim.notify = function(message, level)
            table.insert(calls, { message = message, level = level })
        end
        return calls
    end

    ---A project on `main` and a linked worktree on `feature` with one commit on
    ---top of the initial commit, which is the tip of `main`.
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
    ---@param name prohub.Scope
    ---@return table|nil result
    ---@return string? err
    local function resolve_async(path, name)
        local done, result, err
        local ok, start_err = scope.resolve(
            path,
            name,
            function(value, callback_err)
                assert.is_false(vim.in_fast_event())
                result, err, done = value, callback_err, true
            end
        )
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
        sync = function(path, name)
            return scope.resolve_sync(path, name)
        end,
        async = resolve_async,
    }

    for name, resolve in pairs(forms) do
        describe(name, function()
            it('resolves the branch scope to the base', function()
                local project, feature = feature_project()
                local calls = capture()

                local result, err = resolve(feature.path, 'branch')

                assert.is_nil(err)
                assert.are.same({
                    scope = 'branch',
                    base = project:git('rev-parse', 'main'),
                }, result)
                assert.are.same({}, calls)
            end)

            it(
                'falls back to uncommitted when the branch has no base',
                function()
                    local project = git.project()
                    local calls = capture()

                    local result, err = resolve(project.path, 'branch')

                    assert.is_nil(err)
                    assert.are.same({ scope = 'uncommitted' }, result)
                    assert.are.equal(1, #calls)
                    assert.are.equal(vim.log.levels.WARN, calls[1].level)
                    assert.are.equal(
                        (
                            'prohub: no base for the branch scope in %s '
                            .. '(on the default branch), showing uncommitted '
                            .. 'changes'
                        ):format(project.path),
                        calls[1].message
                    )
                end
            )

            it('uses the configured upstream for the unpushed scope', function()
                local project = git.project()
                local feature = project:worktree('feature')
                project:push()
                feature:commit('a.txt', 'a', 'a change on the feature')
                feature:push()
                feature:commit('b.txt', 'b', 'another change')
                feature:git('branch', '--set-upstream-to', 'origin/main')
                local calls = capture()

                local result, err = resolve(feature.path, 'unpushed')

                assert.is_nil(err)
                assert.are.same({
                    scope = 'unpushed',
                    base = project:git('rev-parse', 'origin/main'),
                }, result)
                assert.are.same({}, calls)
            end)

            it('uses origin/<branch> when there is no upstream', function()
                local project = git.project()
                local feature = project:worktree('feature')
                feature:commit('a.txt', 'a', 'a change on the feature')
                feature:push()
                feature:commit('b.txt', 'b', 'another change')
                feature:git('branch', '--unset-upstream')
                local calls = capture()

                local result, err = resolve(feature.path, 'unpushed')

                assert.is_nil(err)
                assert.are.same({
                    scope = 'unpushed',
                    base = feature:git('rev-parse', 'origin/feature'),
                }, result)
                assert.are.same({}, calls)
            end)

            it('uses the base when there is no remote ref', function()
                local project, feature = feature_project()
                local calls = capture()

                local result, err = resolve(feature.path, 'unpushed')

                assert.is_nil(err)
                assert.are.same({
                    scope = 'unpushed',
                    base = project:git('rev-parse', 'main'),
                }, result)
                assert.are.same({}, calls)
            end)

            it(
                'falls back to uncommitted when unpushed has no revision',
                function()
                    local project = git.project()
                    local calls = capture()

                    local result, err = resolve(project.path, 'unpushed')

                    assert.is_nil(err)
                    assert.are.same({ scope = 'uncommitted' }, result)
                    assert.are.equal(1, #calls)
                    assert.are.equal(vim.log.levels.WARN, calls[1].level)
                    assert.is_truthy(
                        calls[1].message:find(project.path, 1, true)
                    )
                    assert.is_truthy(calls[1].message:find('unpushed', 1, true))
                    assert.is_truthy(
                        calls[1].message:find('no upstream', 1, true)
                    )
                    assert.is_nil(calls[1].message:find('\n', 1, true))
                end
            )

            it('falls back when a detached HEAD has no base', function()
                local project = git.project()
                project:git('branch', '--move', 'main', 'trunk')
                project:detach()
                local calls = capture()

                local result, err = resolve(project.path, 'unpushed')

                assert.is_nil(err)
                assert.are.same({ scope = 'uncommitted' }, result)
                assert.are.equal(1, #calls)
                assert.is_truthy(
                    calls[1].message:find('detached HEAD', 1, true)
                )
            end)

            it('resolves the uncommitted scope to no base', function()
                local project = git.project()
                local calls = capture()

                local result, err = resolve(project.path, 'uncommitted')

                assert.is_nil(err)
                assert.are.same({ scope = 'uncommitted' }, result)
                assert.are.same({}, calls)
            end)

            it('returns an error for an unknown scope', function()
                local project = git.project()

                local result, err = resolve(project.path, 'session')

                assert.is_nil(result)
                assert.is_truthy(err:find('unknown scope', 1, true))
            end)

            it('returns an error for a missing path', function()
                local missing = vim.fn.tempname() .. '/missing'
                local calls = capture()

                local result, err = resolve(missing, 'uncommitted')

                assert.is_nil(result)
                assert.is_truthy(err:find('does not exist', 1, true))
                assert.are.same({}, calls)
            end)

            it('returns an error for a path that is a file', function()
                local file = vim.fn.tempname()
                vim.fn.writefile({ 'prohub' }, file)

                local result, err = resolve(file, 'branch')
                vim.fn.delete(file)

                assert.is_nil(result)
                assert.is_truthy(err:find('is not a directory', 1, true))
            end)
        end)
    end

    describe('resolve', function()
        it('returns an error when there is no callback', function()
            local project = git.project()

            local ok, err = scope.resolve(project.path, 'branch', nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)

        it('returns an error for a path that is not a string', function()
            local ok, err = scope.resolve(nil, 'branch', function() end)

            assert.is_nil(ok)
            assert.is_truthy(err:find('path', 1, true))
        end)

        it('returns an error for a scope that is not a string', function()
            local project = git.project()

            local ok, err = scope.resolve(project.path, nil, function() end)

            assert.is_nil(ok)
            assert.is_truthy(err:find('scope', 1, true))
        end)
    end)

    describe('resolve_sync', function()
        it('returns an error for a path that is not a string', function()
            local result, err = scope.resolve_sync(nil, 'branch')

            assert.is_nil(result)
            assert.is_truthy(err:find('path', 1, true))
        end)

        it('returns an error outside a git project', function()
            local plain = vim.fn.tempname()
            vim.fn.mkdir(plain, 'p')

            local result, err = scope.resolve_sync(plain, 'unpushed')
            vim.fn.delete(plain, 'rf')

            assert.is_nil(result)
            assert.is_truthy(err:find('not a git repository', 1, true))
        end)
    end)
end)
