local git = require('helpers.git')
local log = require('prohub.log')

---The module under test. Each case loads it again, so a configured workset
---cannot leak from one case to the next.
local workset

describe('prohub.workset', function()
    local dirs

    before_each(function()
        dirs = {}
        vim.g.prohub = nil
        package.loaded['prohub'] = nil
        package.loaded['prohub.config'] = nil
        package.loaded['prohub.workset'] = nil
        workset = require('prohub.workset')
    end)

    after_each(function()
        for _, dir in ipairs(dirs) do
            vim.fn.delete(dir, 'rf')
        end
        vim.g.prohub = nil
        git.cleanup()
    end)

    ---Create a directory that is not a git project, optionally inside another
    ---one.
    ---@param name? string
    ---@param parent? string
    ---@return string path
    local function dir(name, parent)
        local path = (parent or vim.fn.tempname()) .. '/' .. (name or 'dir')
        vim.fn.mkdir(path, 'p')
        table.insert(dirs, path)
        return assert(vim.uv.fs_realpath(path))
    end

    ---The paths of a list of worktrees.
    ---@param worktrees prohub.Worktree[]
    ---@return string[]
    local function paths(worktrees)
        return vim.tbl_map(function(record)
            return record.path
        end, worktrees)
    end

    describe('match', function()
        it('matches the key equal to the directory', function()
            local project = git.project()
            local key = dir()

            local match = workset.match(key, { [key] = { project.path } })

            assert.are.equal(key, match.key)
            assert.are.same({ project.path }, match.entries)
        end)

        it('matches the nearest ancestor of the directory', function()
            local project = git.project()
            local outer = dir()
            local inner = dir('inner', outer)
            local deep = dir('deep', inner)

            local match = workset.match(deep, {
                [outer] = { project.path },
                [inner] = { project.path },
            })

            assert.are.equal(inner, match.key)
            assert.are.same({ project.path }, match.entries)
        end)

        it('returns no key when no workset contains the directory', function()
            local project = git.project()
            local root = vim.fn.tempname()
            local key = dir('hub', root)
            local sibling = dir('hub-mate', root)

            local match, err = workset.match(sibling, {
                [key] = { project.path },
            })

            assert.is_nil(match)
            assert.is_nil(err)
        end)

        it('expands globs in the order of the workset', function()
            local project = git.project()
            local feature = project:worktree('feature')
            local fix = project:worktree('fix')
            local key = dir()

            local match = workset.match(key, {
                [key] = {
                    project.container .. '/*',
                    project.path,
                },
            })

            assert.are.same(
                { feature.path, fix.path, project.path },
                match.entries
            )
        end)

        it('takes the paths a function returns', function()
            local project = git.project()
            local feature = project:worktree('feature')
            local key = dir()

            local match = workset.match(key, {
                [key] = function()
                    return { feature.path, project.path }
                end,
            })

            assert.are.same({ feature.path, project.path }, match.entries)
        end)

        it('only calls the function of the nearest workset', function()
            local project = git.project()
            local outer = dir()
            local inner = dir('inner', outer)
            local deep = dir('deep', inner)

            local match = workset.match(deep, {
                [outer] = function()
                    error('the wrong function was called')
                end,
                [inner] = { project.path },
            })

            assert.are.same({ project.path }, match.entries)
        end)

        it('names the workset of a function that fails', function()
            local key = dir()

            local match, err = workset.match(key, {
                [key] = function()
                    error('no list for you')
                end,
            })

            assert.is_nil(match)
            assert.is_truthy(err:find('worksets.' .. key, 1, true))
            assert.is_truthy(err:find('no list for you', 1, true))
        end)

        it('names the workset of a function that returns no list', function()
            local key = dir()

            local match, err = workset.match(key, {
                [key] = function()
                    return 'not a list'
                end,
            })

            assert.is_nil(match)
            assert.is_truthy(err:find('worksets.' .. key, 1, true))
        end)

        it('returns an error for invalid arguments', function()
            local key = dir()

            local calls = {
                function()
                    return workset.match(nil, {})
                end,
                function()
                    return workset.match(key, 'not a table')
                end,
                function()
                    return workset.match(key, { [1] = {} })
                end,
            }

            for _, call in ipairs(calls) do
                local called, matched, err = pcall(call)
                assert.is_true(called)
                assert.is_nil(matched)
                assert.is_truthy(err:find('prohub:', 1, true))
            end
        end)

        it('normalizes the key and the directory', function()
            local project = git.project()
            local root = dir()
            local deep = dir('deep', root)

            local match = workset.match(deep .. '/', {
                [root .. '/'] = { project.path },
            })

            assert.are.equal(root .. '/', match.key)
            assert.are.same({ project.path }, match.entries)
        end)
    end)

    describe('list', function()
        local logs, notified

        before_each(function()
            logs = vim.fn.tempname()
            assert(log.configure({
                level = vim.log.levels.WARN,
                file = logs .. '/prohub.log',
            }))
            notified = vim.notify
        end)

        after_each(function()
            vim.notify = notified
            vim.fn.delete(logs, 'rf')
        end)

        ---Run `list` and wait for its callback.
        ---@param dir string
        ---@return prohub.Worktree[]|nil worktrees
        ---@return string? err
        local function list(dir)
            local done, fast, worktrees, err
            local ok, start_err = workset.list(dir, function(w, e)
                fast, worktrees, err, done = vim.in_fast_event(), w, e, true
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
            assert.is_false(fast, 'the callback ran outside the main loop')
            return worktrees, err
        end

        ---The text of the log, or an empty string when nothing was logged.
        ---@return string
        local function logged()
            local file = logs .. '/prohub.log'
            if vim.uv.fs_stat(file) == nil then
                return ''
            end
            return table.concat(vim.fn.readfile(file), '\n')
        end

        it('delivers its worktrees later on the main loop', function()
            local project = git.project()
            local calls = {}

            local ok = workset.list(project.path, function(worktrees)
                table.insert(calls, {
                    count = #worktrees,
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
            assert.are.same({ { count = 1, fast = false } }, calls)
        end)

        it('shows the project that holds the directory', function()
            local project = git.project()
            local feature = project:worktree('feature')

            local worktrees, err = list(project.path)

            assert.is_nil(err)
            assert.are.same({ project.path, feature.path }, paths(worktrees))
        end)

        it('shows the project of a bare repository directory', function()
            local bare, main = git.bare()
            local feature = bare:worktree('feature')

            local worktrees, err = list(bare.path)

            assert.is_nil(err)
            assert.are.same({ feature.path, main.path }, paths(worktrees))
        end)

        it('shows one worktree per entry of the workset', function()
            local first = git.project()
            local second = git.project()
            local linked = first:worktree('feature')
            local key = dir()

            vim.g.prohub = {
                worksets = { [key] = { second.path, linked.path, first.path } },
            }

            local worktrees, err = list(key)

            assert.is_nil(err)
            assert.are.same(
                { second.path, linked.path, first.path },
                paths(worktrees)
            )
        end)

        it('shows the worktrees a glob of the workset matches', function()
            local project = git.project()
            local feature = project:worktree('feature')
            local fix = project:worktree('fix')
            local key = dir()

            vim.g.prohub = {
                worksets = { [key] = { project.container .. '/*' } },
            }

            local worktrees, err = list(key)

            assert.is_nil(err)
            assert.are.same(
                { feature.path, fix.path, project.path },
                paths(worktrees)
            )
        end)

        it('shows the worktrees the function of a workset returns', function()
            local project = git.project()
            local feature = project:worktree('feature')
            local key = dir()

            assert(require('prohub.config').setup({
                worksets = {
                    [key] = function()
                        return { feature.path }
                    end,
                },
            }))

            local worktrees, err = list(key)

            assert.is_nil(err)
            assert.are.same({ feature.path }, paths(worktrees))
        end)

        it('skips a path that is not a git worktree', function()
            local project = git.project()
            local key = dir()
            local plain = dir('plain')
            local missing = key .. '/missing'

            vim.g.prohub = {
                worksets = { [key] = { plain, missing, project.path } },
            }

            local worktrees, err = list(key)

            assert.is_nil(err)
            assert.are.same({ project.path }, paths(worktrees))
            local text = logged()
            assert.is_truthy(text:find(plain, 1, true))
            assert.is_truthy(text:find(missing, 1, true))
        end)

        it('shows the project even when a workset holds it', function()
            local project = git.project()
            local feature = project:worktree('feature')
            local nested = dir('nested', project.path)
            local other = git.project()

            vim.g.prohub = { worksets = { [project.path] = { other.path } } }

            local worktrees, err = list(nested)

            assert.is_nil(err)
            assert.are.same({ project.path, feature.path }, paths(worktrees))
        end)

        it('shows the nearest workset of the directory', function()
            local outer_project = git.project()
            local inner_project = git.project()
            local outer = dir()
            local inner = dir('inner', outer)
            local deep = dir('deep', inner)

            vim.g.prohub = {
                worksets = {
                    [outer] = { outer_project.path },
                    [inner] = { inner_project.path },
                },
            }

            local worktrees, err = list(deep)

            assert.is_nil(err)
            assert.are.same({ inner_project.path }, paths(worktrees))
        end)

        it('warns which directory matched no workset', function()
            local project = git.project()
            local key = dir()
            local outside = dir('outside')
            local calls = {}
            vim.notify = function(message, level)
                table.insert(calls, { message = message, level = level })
            end

            vim.g.prohub = { worksets = { [key] = { project.path } } }

            local worktrees, err = list(outside)

            assert.is_nil(err)
            assert.are.same({}, worktrees)
            assert.are.equal(1, #calls)
            assert.are.equal(vim.log.levels.WARN, calls[1].level)
            assert.is_truthy(calls[1].message:find(outside, 1, true))
        end)

        it(
            'returns an error without calling back for an invalid path',
            function()
                local file = vim.fn.tempname()
                vim.fn.writefile({ 'prohub' }, file)

                local cases = {
                    { vim.fn.tempname() .. '/missing', 'does not exist' },
                    { file, 'is not a directory' },
                }

                for _, case in ipairs(cases) do
                    local called
                    local ok, err = workset.list(case[1], function()
                        called = true
                    end)

                    assert.is_nil(ok)
                    assert.is_truthy(err:find(case[2], 1, true))
                    assert.is_false(vim.wait(100, function()
                        return called
                    end))
                end

                vim.fn.delete(file)
            end
        )

        it('returns an error when there is no callback', function()
            local key = dir()

            local ok, err = workset.list(key, nil)

            assert.is_nil(ok)
            assert.is_truthy(err:find('callback', 1, true))
        end)
    end)
end)
