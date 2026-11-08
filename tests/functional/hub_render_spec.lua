local render = require('prohub.hub.render')

describe('prohub.hub.render', function()
    ---A worktree of a project, at `path`, on the branch of the same name.
    ---@param path string
    ---@param fields? table
    ---@return prohub.Worktree
    local function worktree(path, fields)
        local record = {
            path = path,
            head = 'a1b2c3d4e5f6a7b8c9d0',
            branch = vim.fs.basename(path),
            missing = false,
        }
        for name, value in pairs(fields or {}) do
            record[name] = value
        end
        return record
    end

    ---A collected status of a clean worktree, with `fields` over it.
    ---@param fields? table
    ---@return prohub.Status
    local function status(fields)
        local collected = {
            staged = 0,
            unstaged = 0,
            untracked = 0,
            ahead = 0,
            behind = 0,
            changed = 0,
        }
        for name, value in pairs(fields or {}) do
            collected[name] = value
        end
        return collected
    end

    it('writes a header and one row per worktree', function()
        local worktrees = {
            worktree('/project/app', { branch = 'main' }),
            worktree('/project/feature', { branch = 'feature' }),
        }

        local rows = render.build(worktrees, {
            ['/project/app'] = {
                status = status({ reason = 'on the default branch' }),
            },
            ['/project/feature'] = {
                status = status({
                    staged = 1,
                    unstaged = 2,
                    untracked = 3,
                    ahead = 4,
                    behind = 5,
                    changed = 6,
                }),
            },
        })

        assert.are.same({
            'name     path     s u ?  a b  c  p',
            'main     app      0 0 0  0 0  0  on the default branch',
            'feature  feature  1 2 3  4 5  6',
        }, rows.lines)
        assert.are.same({}, rows.highlights)
    end)

    it('writes a dash for a count that does not apply', function()
        local rows = render.build({ worktree('/project/app') }, {
            ['/project/app'] = {
                status = {
                    staged = 0,
                    unstaged = 0,
                    untracked = 0,
                    reason = 'no default branch',
                },
            },
        })

        assert.are.equal(
            'app   app   0 0 0  - -  -  no default branch',
            rows.lines[2]
        )
    end)

    it('writes the unpushed count only when the status has one', function()
        local worktrees = {
            worktree('/project/app', { branch = 'main' }),
            worktree('/project/feature', { branch = 'feature' }),
        }

        local rows = render.build(worktrees, {
            ['/project/app'] = { status = status({ unpushed = 0 }) },
            ['/project/feature'] = { status = status({ unpushed = 3 }) },
        })

        assert.are.equal('name     path     s u ?  a b  c  p', rows.lines[1])
        assert.are.equal('main     app      0 0 0  0 0  0  0', rows.lines[2])
        assert.are.equal('feature  feature  0 0 0  0 0  0  3', rows.lines[3])
    end)

    it('dims a worktree git reports as missing', function()
        local worktrees = {
            worktree('/project/app', { branch = 'main' }),
            worktree('/project/gone', { branch = 'gone', missing = true }),
        }

        local rows = render.build(worktrees, {
            ['/project/app'] = { status = status() },
            ['/project/gone'] = { status = status() },
        })

        assert.are.equal('gone  gone  0 0 0  0 0  0  missing', rows.lines[3])
        assert.are.same({
            { line = 3, group = render.missing_group },
        }, rows.highlights)
        assert.are.same({ ['/project/gone'] = true }, rows.missing)
    end)

    it('writes the error of a collection on one line', function()
        local rows = render.build({ worktree('/project/app') }, {
            ['/project/app'] = { err = 'the status failed\nin app' },
        })

        assert.are.equal(
            'app   app   - - -  - -  -  error: the status failed in app',
            rows.lines[2]
        )
    end)

    it('names the directory of two worktrees that share a last part', function()
        local worktrees = {
            worktree('/project/one/app', { branch = 'one' }),
            worktree('/project/two/app', { branch = 'two' }),
        }

        local rows = render.build(worktrees, {
            ['/project/one/app'] = { status = status() },
            ['/project/two/app'] = { status = status() },
        })

        assert.are.equal('one   one/app  0 0 0  0 0  0', rows.lines[2])
        assert.are.equal('two   two/app  0 0 0  0 0  0', rows.lines[3])
    end)

    it('names a detached HEAD by its short commit', function()
        local worktrees = {
            {
                path = '/project/app',
                head = 'a1b2c3d4e5f6',
                detached = 'a1b2c3d',
                missing = false,
            },
        }

        local rows = render.build(worktrees, {
            ['/project/app'] = { status = status({ head = 'ffffff0' }) },
        })

        assert.are.equal('a1b2c3d  app   0 0 0  0 0  0', rows.lines[2])
    end)

    it(
        'names a worktree without a branch by the commit of its status',
        function()
            local worktrees = {
                {
                    path = '/project/app',
                    head = 'a1b2c3d4e5f6',
                    missing = false,
                },
            }

            local rows = render.build(worktrees, {
                ['/project/app'] = { status = status({ head = 'a1b2c3d' }) },
            })

            assert.are.equal('a1b2c3d  app   0 0 0  0 0  0', rows.lines[2])
        end
    )

    it('names a worktree without a branch or a status by a dash', function()
        local worktrees = {
            { path = '/project/app', head = 'a1b2c3d4e5f6', missing = false },
        }

        local rows = render.build(worktrees, {})

        assert.are.equal('-     app   - - -  - -  -', rows.lines[2])
    end)

    it('writes no line for a listing that holds no worktree', function()
        local rows = render.build({}, {})

        assert.are.same(
            { lines = {}, highlights = {}, paths = {}, missing = {} },
            rows
        )
    end)

    it('names the worktree of every row', function()
        local worktrees = {
            worktree('/project/app', { branch = 'main' }),
            worktree('/project/feature'),
        }

        local rows = render.build(worktrees, {
            ['/project/app'] = { status = status() },
            ['/project/feature'] = { status = status() },
        })

        assert.are.same({
            [2] = '/project/app',
            [3] = '/project/feature',
        }, rows.paths)
    end)
end)
