local git = require('helpers.git')
local log = require('prohub.log')
local worktree = require('prohub.worktree')

---The commit of the main checkout in the literal output below.
local main_commit = '5f2c1a0e9b8d7c6a5f4e3d2c1b0a9f8e7d6c5b4a'

---The commit of the linked worktrees in the literal output below.
local linked_commit = '1a2b3c4d5e6f7a8b9c0d1e2f3a4b5c6d7e8f9a0b'

---A record of the main checkout of a project.
local function main_checkout()
    return {
        path = '/project/app',
        head = main_commit,
        branch = 'main',
        missing = false,
    }
end

describe('prohub.worktree', function()
    describe('parse', function()
        it('parses the main checkout', function()
            local text = (
                'worktree /project/app\0HEAD %s\0'
                .. 'branch refs/heads/main\0\0'
            ):format(main_commit)

            local worktrees, err = worktree.parse(text)

            assert.is_nil(err)
            assert.are.same({ main_checkout() }, worktrees)
        end)

        it('keeps the order of git and names the branches', function()
            local text = (
                'worktree /project/app\0HEAD %s\0'
                .. 'branch refs/heads/main\0\0'
                .. 'worktree /project/feature/login\0HEAD %s\0'
                .. 'branch refs/heads/feature/login\0\0'
            ):format(main_commit, linked_commit)

            local worktrees = worktree.parse(text)

            assert.are.same({
                main_checkout(),
                {
                    path = '/project/feature/login',
                    head = linked_commit,
                    branch = 'feature/login',
                    missing = false,
                },
            }, worktrees)
        end)

        it('marks a detached HEAD with its short commit', function()
            local text = (
                'worktree /project/app\0HEAD %s\0'
                .. 'branch refs/heads/main\0\0'
                .. 'worktree /project/detached\0HEAD %s\0'
                .. 'detached\0\0'
            ):format(main_commit, linked_commit)

            local worktrees = worktree.parse(text)

            assert.are.same({
                main_checkout(),
                {
                    path = '/project/detached',
                    head = linked_commit,
                    detached = linked_commit:sub(1, 7),
                    missing = false,
                },
            }, worktrees)
        end)

        it('marks a prunable worktree as missing', function()
            local text = (
                'worktree /project/app\0HEAD %s\0'
                .. 'branch refs/heads/main\0\0'
                .. 'worktree /project/gone\0HEAD %s\0'
                .. 'branch refs/heads/gone\0'
                .. 'prunable gitdir file points to non-existent location\0\0'
            ):format(main_commit, linked_commit)

            local worktrees = worktree.parse(text)

            assert.are.same({
                main_checkout(),
                {
                    path = '/project/gone',
                    head = linked_commit,
                    branch = 'gone',
                    missing = true,
                },
            }, worktrees)
        end)

        it('hides the bare entry of a bare layout', function()
            local text = (
                'worktree /project/app.git\0HEAD %s\0bare\0\0'
                .. 'worktree /project/main\0HEAD %s\0'
                .. 'branch refs/heads/main\0\0'
            ):format(main_commit, linked_commit)

            local worktrees = worktree.parse(text)

            assert.are.same({
                {
                    path = '/project/main',
                    head = linked_commit,
                    branch = 'main',
                    missing = false,
                },
            }, worktrees)
        end)

        it('returns no worktree for empty output', function()
            assert.are.same({}, worktree.parse(''))
        end)

        it('returns an error for text that is not a string', function()
            local worktrees, err = worktree.parse(nil)

            assert.is_nil(worktrees)
            assert.is_truthy(err:find('text', 1, true))
        end)
    end)

    describe('list', function()
        local logs

        before_each(function()
            logs = vim.fn.tempname()
            assert(log.configure({ file = logs .. '/prohub.log' }))
        end)

        after_each(function()
            git.cleanup()
            vim.fn.delete(logs, 'rf')
        end)

        ---Run the command asynchronously and wait for its callback.
        ---@param path string
        ---@return prohub.Worktree[]|nil worktrees
        ---@return string? err
        local function list_async(path)
            local done, worktrees, err
            local ok, start_err = worktree.list(path, function(w, e)
                worktrees, err, done = w, e, true
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
            return worktrees, err
        end

        ---The two forms of the command, so the same cases run against both.
        local forms = {
            sync = function(path)
                return worktree.list_sync(path)
            end,
            async = list_async,
        }

        ---@param worktrees prohub.Worktree[]
        ---@param path string
        ---@return prohub.Worktree?
        local function find(worktrees, path)
            for _, record in ipairs(worktrees) do
                if record.path == path then
                    return record
                end
            end
        end

        for name, list in pairs(forms) do
            describe(name, function()
                it(
                    'lists the main checkout and the linked worktrees',
                    function()
                        local project = git.project()
                        local feature = project:worktree('feature')
                        project:worktree('fix')

                        local worktrees, err = list(project.path)

                        assert.is_nil(err)
                        assert.are.same(
                            {
                                project.path,
                                feature.path,
                                project.container .. '/fix',
                            },
                            vim.tbl_map(function(record)
                                return record.path
                            end, worktrees)
                        )
                        assert.are.equal(
                            project:git('rev-parse', 'HEAD'),
                            worktrees[1].head
                        )
                        assert.are.equal('main', worktrees[1].branch)
                        assert.is_false(worktrees[1].missing)
                    end
                )

                it('reports a detached HEAD with its short commit', function()
                    local project = git.project()
                    local feature = project:worktree('feature')
                    feature:detach()

                    local worktrees = list(project.path)

                    local record = find(worktrees, feature.path)
                    assert.is_nil(record.branch)
                    assert.are.equal(
                        feature:git('rev-parse', '--short=7', 'HEAD'),
                        record.detached
                    )
                end)

                it('marks a deleted worktree as missing', function()
                    local project = git.project()
                    local gone = project:worktree('gone')
                    gone:delete_dir()

                    local worktrees = list(project.path)

                    local record = find(worktrees, gone.path)
                    assert.is_true(record.missing)
                    assert.are.equal('gone', record.branch)
                end)

                it('hides the bare entry of a bare layout', function()
                    local bare, main = git.bare()
                    local feature = bare:worktree('feature')

                    local worktrees = list(bare.path)
                    local paths = vim.tbl_map(function(record)
                        return record.path
                    end, worktrees)

                    -- git sorts the linked worktrees of a bare repository by
                    -- path, and the bare entry comes first.
                    assert.are.same({ feature.path, main.path }, paths)
                    assert.are.equal('feature', worktrees[1].branch)
                    assert.are.equal('main', worktrees[2].branch)
                end)

                it('returns an error outside a git project', function()
                    local plain = vim.fn.tempname()
                    vim.fn.mkdir(plain, 'p')
                    plain = assert(vim.uv.fs_realpath(plain))

                    local worktrees, err = list(plain)
                    vim.fn.delete(plain, 'rf')

                    assert.is_nil(worktrees)
                    assert.is_truthy(err:find('not a git repository', 1, true))
                end)
            end)
        end

        it(
            'returns an error without calling back for a missing path',
            function()
                local missing = vim.fn.tempname() .. '/missing'
                local called

                local ok, err = worktree.list(missing, function()
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

            local ok, err = worktree.list(project.path, nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)
    end)
end)
