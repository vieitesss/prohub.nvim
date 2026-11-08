local git = require('helpers.git')
local log = require('prohub.log')

---The modules under test.
local chain = require('prohub.chain')
local refs = require('prohub.refs')

describe('prohub.refs', function()
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

    ---Run the flow and wait for git.
    ---@param path string
    ---@return prohub.Refs? known
    ---@return string? err
    local function read(path)
        return chain.run_sync(path, refs.flow(path))
    end

    describe('flow', function()
        it('reads the branch of the worktree and the refs of origin', function()
            local project = git.project()
            local feature = project:worktree('feature')
            project:push()
            feature:push()

            local known, err = read(feature.path)

            assert.is_nil(err)
            assert.are.equal('feature', known.branch)

            for _, name in ipairs({ 'feature', 'main' }) do
                assert.are.equal(true, known.heads[name])
                assert.are.equal(true, known.origin[name])
            end
        end)

        it('names the branch origin/HEAD points at', function()
            local project = git.project()
            project:push()
            project:git('remote', 'set-head', 'origin', '--auto')

            local known, err = read(project.path)

            assert.is_nil(err)
            assert.are.equal('main', known.origin_head)
        end)

        it('names the configured upstream as the counterpart', function()
            local project = git.project()
            local feature = project:worktree('feature')
            project:push()
            feature:push()
            feature:git('branch', '--set-upstream-to', 'origin/main')

            local known, err = read(feature.path)

            assert.is_nil(err)
            assert.are.equal('refs/remotes/origin/main', known.counterpart)
        end)

        it('names an upstream on another remote as the counterpart', function()
            local project = git.project()
            local feature = project:worktree('feature')
            project:push()
            feature:push()
            feature:remote('upstream')
            feature:git('push', '--quiet', '--set-upstream', 'upstream', 'HEAD')

            local known, err = read(feature.path)

            assert.is_nil(err)
            assert.are.equal('refs/remotes/upstream/feature', known.counterpart)
        end)

        it('falls back to origin/<branch> without an upstream', function()
            local project = git.project()
            local feature = project:worktree('feature')
            feature:push()
            feature:git('branch', '--unset-upstream')

            local known, err = read(feature.path)

            assert.is_nil(err)
            assert.are.equal('refs/remotes/origin/feature', known.counterpart)
        end)

        it('names no counterpart for a branch that was never pushed', function()
            local project = git.project()

            local known, err = read(project.path)

            assert.is_nil(err)
            assert.are.equal('main', known.branch)
            assert.is_nil(known.counterpart)
        end)

        it('names no counterpart for a detached HEAD', function()
            local project = git.project()
            project:push()
            project:detach()

            local known, err = read(project.path)

            assert.is_nil(err)
            assert.is_nil(known.branch)
            assert.is_nil(known.counterpart)
        end)

        it('reads a worktree of a bare layout', function()
            local bare = git.bare()
            local feature = bare:worktree('feature')
            feature:commit('a.txt', 'a', 'a change on the feature')

            local known, err = read(feature.path)

            assert.is_nil(err)
            assert.are.equal('feature', known.branch)
            assert.are.equal(true, known.heads.main)
            assert.is_nil(known.counterpart)
        end)

        it('returns an error outside a git project', function()
            local plain = vim.fn.tempname()
            vim.fn.mkdir(plain, 'p')

            local known, err = read(plain)
            vim.fn.delete(plain, 'rf')

            assert.is_nil(known)
            assert.is_truthy(err:find('not a git repository', 1, true))
        end)
    end)

    describe('ref', function()
        it('prefers the origin ref over the local one', function()
            local project = git.project()
            project:push()

            local known = assert(read(project.path))

            assert.are.equal(
                'refs/remotes/origin/main',
                refs.ref(known, 'main')
            )
        end)

        it(
            'returns the local ref when origin does not have the branch',
            function()
                local project = git.project()
                project:git('branch', 'develop')
                project:push()

                local known = assert(read(project.path))

                assert.are.equal(
                    'refs/heads/develop',
                    refs.ref(known, 'develop')
                )
            end
        )

        it('returns the origin ref of a branch that is not local', function()
            local project = git.project()
            project:git('branch', 'develop')
            project:push()
            project:git('push', '--quiet', 'origin', 'develop')
            project:git('branch', '-D', 'develop')

            local known = assert(read(project.path))

            assert.are.equal(
                'refs/remotes/origin/develop',
                refs.ref(known, 'develop')
            )
        end)

        it('returns nothing for a branch the project does not have', function()
            local project = git.project()
            project:push()

            local known = assert(read(project.path))

            assert.is_nil(refs.ref(known, 'missing'))
        end)
    end)
end)
