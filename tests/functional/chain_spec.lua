local chain = require('prohub.chain')
local git = require('helpers.git')

describe('prohub.chain', function()
    after_each(git.cleanup)

    ---Run a flow asynchronously and wait for its callback.
    ---@param path string
    ---@param flow prohub.chain.Flow
    ---@return any result
    ---@return string? err
    local function run_async(path, flow)
        local done, result, err
        local ok, start_err = chain.run(path, flow, function(value, failure)
            result, err, done = value, failure, true
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

    ---The flow the same cases run with both adapters. It reads the branch and
    ---then the error and the exit status of a command that fails.
    ---@param run prohub.chain.Run
    ---@param done prohub.chain.Done
    local function read_branch(run, done)
        run({ 'branch', '--show-current' }, function(branch, err)
            if not branch then
                return done(nil, err)
            end
            run(
                { 'rev-parse', '--verify', 'missing' },
                function(out, failure, code)
                    done({
                        branch = vim.trim(branch),
                        out = out,
                        failure = failure,
                        code = code,
                    })
                end
            )
        end)
    end

    it('runs the steps of a flow with either adapter', function()
        local project = git.project()

        local sync_result, sync_err = chain.run_sync(project.path, read_branch)
        local async_result, async_err = run_async(project.path, read_branch)

        assert.is_nil(sync_err)
        assert.are.same(sync_result, async_result)
        assert.are.equal('main', async_result.branch)
    end)

    it('hands an error and the exit status to the flow', function()
        local project = git.project()

        local result = chain.run_sync(project.path, read_branch)

        assert.is_nil(result.out)
        assert.is_truthy(result.failure:find('fatal', 1, true))
        assert.are.equal(128, result.code)
    end)

    it('returns the result a flow ends with', function()
        local project = git.project()

        local result, err = chain.run_sync(project.path, function(_, done)
            done({ branch = 'main' })
        end)

        assert.are.same({ branch = 'main' }, result)
        assert.is_nil(err)
    end)

    it('returns the error a flow ends with', function()
        local project = git.project()
        local flow = function(_, done)
            done(nil, 'prohub: the base is missing')
        end

        local result, err = chain.run_sync(project.path, flow)

        assert.is_nil(result)
        assert.are.equal('prohub: the base is missing', err)
    end)

    it('delivers the result of a flow later on the main loop', function()
        local project = git.project()
        local calls = {}

        local ok = chain.run(project.path, read_branch, function(result)
            table.insert(calls, {
                branch = result.branch,
                fast = vim.in_fast_event(),
            })
        end)

        assert.is_true(ok)
        assert.are.same({}, calls)
        assert(
            vim.wait(5000, function()
                return #calls > 0
            end),
            'the callback was not called'
        )
        assert.are.same({ { branch = 'main', fast = false } }, calls)
    end)

    it('delivers the error a flow ends with', function()
        local project = git.project()
        local flow = function(_, done)
            done(nil, 'prohub: the base is missing')
        end

        local result, err = run_async(project.path, flow)

        assert.is_nil(result)
        assert.are.equal('prohub: the base is missing', err)
    end)

    it(
        'returns an error without running the flow for invalid arguments',
        function()
            local project = git.project()
            local ran

            local no_flow, no_flow_err = chain.run(
                project.path,
                nil,
                function() end
            )
            local no_callback, callback_err = chain.run(project.path, function()
                ran = true
            end, nil)
            local no_path, path_err = chain.run_sync(nil, function() end)

            assert.is_nil(no_flow)
            assert.is_truthy(no_flow_err:find('flow', 1, true))
            assert.is_nil(no_callback)
            assert.is_truthy(callback_err:find('callback', 1, true))
            assert.is_nil(no_path)
            assert.is_truthy(path_err:find('path', 1, true))
            assert.is_falsy(ran)
        end
    )
end)
