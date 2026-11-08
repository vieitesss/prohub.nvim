local git = require('helpers.git')
local log = require('prohub.log')
local prohub_git = require('prohub.git')

---Run git asynchronously and return a startup error or wait for the callback.
---@param path any
---@param args any
---@return string? out
---@return string? err
local function run(path, args)
    local done, out, err
    local ok, start_err = prohub_git.run(path, args, function(o, e)
        out, err, done = o, e, true
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
    return out, err
end

---Each form of the helper, so the same cases run against both.
local forms = {
    sync = prohub_git.run_sync,
    async = run,
}

describe('prohub.git', function()
    local plain, logs

    before_each(function()
        plain = vim.fn.tempname()
        vim.fn.mkdir(plain, 'p')
        plain = assert(vim.uv.fs_realpath(plain))

        -- Keep the log of the specs out of the real log directory.
        logs = vim.fn.tempname()
        assert(log.configure({ file = logs .. '/prohub.log' }))
    end)

    after_each(function()
        git.cleanup()
        vim.fn.delete(plain, 'rf')
        vim.fn.delete(logs, 'rf')
    end)

    for name, run_git in pairs(forms) do
        describe(name, function()
            it('returns the output of git', function()
                local project = git.project()

                local out, err =
                    run_git(project.path, { 'branch', '--show-current' })

                assert.is_nil(err)
                assert.are.equal('main\n', out)
            end)

            it('runs in the worktree it is given', function()
                local project = git.project()
                local feature = project:worktree('feature')

                local top =
                    run_git(feature.path, { 'rev-parse', '--show-toplevel' })
                local branch =
                    run_git(feature.path, { 'branch', '--show-current' })

                assert.are.equal(feature.path .. '\n', top)
                assert.are.equal('feature\n', branch)
            end)

            it('does not use the current directory of the editor', function()
                local project = git.project()
                local feature = project:worktree('feature')
                local previous = vim.fn.getcwd()

                vim.fn.chdir(feature.path)
                local out =
                    run_git(project.path, { 'branch', '--show-current' })
                local cwd = vim.fn.getcwd()
                vim.fn.chdir(previous)

                assert.are.equal('main\n', out)
                assert.are.equal(feature.path, cwd)
            end)

            it('ignores inherited git project paths', function()
                local project = git.project()
                local other = git.project()
                local previous_dir = vim.env.GIT_DIR
                local previous_worktree = vim.env.GIT_WORK_TREE
                vim.env.GIT_DIR = other.path .. '/.git'
                vim.env.GIT_WORK_TREE = other.path

                local ok, out, err = pcall(
                    run_git,
                    project.path,
                    { 'rev-parse', '--show-toplevel' }
                )
                vim.env.GIT_DIR = previous_dir
                vim.env.GIT_WORK_TREE = previous_worktree

                assert(ok, out)
                assert.is_nil(err)
                assert.are.equal(project.path .. '\n', out)
            end)

            it('works in a bare layout', function()
                local bare, main = git.bare()
                local feature = bare:worktree('feature')

                local is_bare =
                    run_git(bare.path, { 'rev-parse', '--is-bare-repository' })
                local list =
                    run_git(main.path, { 'worktree', 'list', '--porcelain' })

                assert.are.equal('true\n', is_bare)
                assert.is_truthy(list:find('worktree ' .. main.path, 1, true))
                assert.is_truthy(
                    list:find('worktree ' .. feature.path, 1, true)
                )
            end)

            it('returns the output untouched', function()
                local project = git.project()

                local out = run_git(project.path, { 'ls-files', '-z' })

                assert.are.equal('README.md\0', out)
            end)

            it('returns CRLF blob bytes unchanged', function()
                local project = git.project()
                project:stage('crlf.txt', 'prohub\r\nuntouched\r')
                local blob = project:git('rev-parse', ':crlf.txt')

                local out, err =
                    run_git(project.path, { 'cat-file', 'blob', blob })

                assert.is_nil(err)
                assert.are.equal('prohub\r\nuntouched\r\n', out)
            end)

            it(
                'returns an error for a path that is not a repository',
                function()
                    local out, err =
                        run_git(plain, { 'rev-parse', '--show-toplevel' })

                    assert.is_nil(out)
                    assert.is_truthy(err:find('not a git repository', 1, true))
                    assert.is_truthy(err:find(plain, 1, true))
                end
            )

            it('returns an error for a path that does not exist', function()
                local missing = plain .. '/missing'

                local out, err = run_git(missing, { 'status' })

                assert.is_nil(out)
                assert.is_truthy(err:find('does not exist', 1, true))
                assert.is_truthy(err:find(missing, 1, true))
            end)

            it('returns an error for a path that is a file', function()
                local project = git.project()

                local out, err =
                    run_git(project.path .. '/README.md', { 'status' })

                assert.is_nil(out)
                assert.is_truthy(err:find('is not a directory', 1, true))
            end)

            it('returns an error for a relative path', function()
                local out, err = run_git('.', { 'status' })

                assert.is_nil(out)
                assert.is_truthy(err:find('must be absolute', 1, true))
            end)

            if vim.fn.has('win32') ~= 1 then
                it('rejects a drive-prefixed path on this host', function()
                    local out, err = run_git('C:/project', { 'status' })

                    assert.is_nil(out)
                    assert.is_truthy(err:find('must be absolute', 1, true))
                end)
            end

            it('returns an error when the git command fails', function()
                local project = git.project()

                local out, err = run_git(
                    project.path,
                    { 'rev-parse', '--verify', 'missing' }
                )

                assert.is_nil(out)
                assert.is_truthy(
                    err:find('git rev-parse --verify missing failed', 1, true)
                )
                assert.is_truthy(err:find(project.path, 1, true))
                assert.is_truthy(err:find('fatal', 1, true))
            end)

            it('returns an error for arguments of the wrong type', function()
                local project = git.project()

                local no_path, path_err = run_git(nil, { 'status' })
                local no_args, args_err = run_git(project.path, 'status')
                local bad_args, item_err = run_git(project.path, { 'log', 1 })

                assert.is_nil(no_path)
                assert.is_truthy(path_err:find('path', 1, true))
                assert.is_nil(no_args)
                assert.is_truthy(args_err:find('args', 1, true))
                assert.is_nil(bad_args)
                assert.is_truthy(item_err:find('args', 1, true))
            end)

            it('returns an error when git takes too long', function()
                local project = git.project()
                local timeout = prohub_git.timeout
                prohub_git.timeout = 200

                local out, err = run_git(
                    project.path,
                    { '-c', 'alias.slow=!exec sleep 5', 'slow' }
                )
                prohub_git.timeout = timeout

                assert.is_nil(out)
                assert.is_truthy(err:find('timed out after 200 ms', 1, true))
            end)
        end)
    end

    describe('check_path', function()
        it('accepts an absolute directory', function()
            local project = git.project()

            assert.is_true(prohub_git.check_path(project.path))
        end)

        it('returns an error for a path that cannot be a worktree', function()
            local project = git.project()
            local cases = {
                { nil, 'path' },
                { 'relative/dir', 'must be absolute' },
                { plain .. '/missing', 'does not exist' },
                { project.path .. '/README.md', 'is not a directory' },
            }

            for _, case in ipairs(cases) do
                local ok, err = prohub_git.check_path(case[1])

                assert.is_nil(ok)
                assert.is_truthy(err:find(case[2], 1, true))
            end
        end)
    end)

    describe('run', function()
        it('calls back on the main loop, after it returned', function()
            local project = git.project()
            local called, fast, buffer

            local ok = prohub_git.run(project.path, { 'status' }, function()
                called = true
                fast = vim.in_fast_event()
                buffer = vim.api.nvim_get_current_buf()
            end)

            assert.is_true(ok)
            assert.is_nil(called)
            assert(vim.wait(5000, function()
                return called
            end))
            assert.is_false(fast)
            assert.are.equal(vim.api.nvim_get_current_buf(), buffer)
        end)

        it('returns output after the caller changes arguments', function()
            local project = git.project()
            local args = { 'branch', '--show-current' }
            local done, out, err

            local ok = prohub_git.run(project.path, args, function(o, e)
                out, err, done = o, e, true
            end)
            args[1] = {}

            assert.is_true(ok)
            assert(
                vim.wait(5000, function()
                    return done
                end),
                'the callback was not called'
            )
            assert.is_nil(err)
            assert.are.equal('main\n', out)
        end)

        it(
            'returns an error without calling back for a missing path',
            function()
                local called

                local ok, err = prohub_git.run(
                    plain .. '/missing',
                    { 'status' },
                    function()
                        called = true
                    end
                )

                assert.is_nil(ok)
                assert.is_truthy(err:find('does not exist', 1, true))
                assert.is_false(vim.wait(100, function()
                    return called
                end))
                assert.is_nil(called)
            end
        )

        it(
            'returns an error without calling back when git cannot be started',
            function()
                local project = git.project()
                local path = vim.env.PATH
                local called
                vim.env.PATH = plain

                local returned, ok, err = pcall(
                    prohub_git.run,
                    project.path,
                    { 'status' },
                    function()
                        called = true
                    end
                )
                vim.env.PATH = path

                assert.is_true(returned)
                assert.is_nil(ok)
                assert.is_truthy(err:find('could not run git', 1, true))
                assert.is_false(vim.wait(100, function()
                    return called
                end))
                assert.is_nil(called)
            end
        )

        it('returns an error when validation raises a table', function()
            local validator = vim.validate
            vim.validate = function()
                error({ message = 'invalid argument' })
            end

            local returned, ok, err = pcall(prohub_git.run, plain, {}, nil)
            vim.validate = validator

            assert.is_true(returned)
            assert.is_nil(ok)
            assert.is_string(err)
            assert.is_truthy(err:find('prohub: ', 1, true))
        end)

        it('returns an error when there is no callback', function()
            local project = git.project()

            local ok, err = prohub_git.run(project.path, { 'status' }, nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)
    end)

    describe('run_sync', function()
        it('returns an error when git cannot be started', function()
            local project = git.project()
            local path = vim.env.PATH
            vim.env.PATH = plain

            local out, err = prohub_git.run_sync(project.path, { 'status' })
            vim.env.PATH = path

            assert.is_nil(out)
            assert.is_truthy(err:find('could not run git', 1, true))
        end)
    end)
end)
