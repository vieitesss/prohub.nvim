local git = require('helpers.git')
local spawns = require('helpers.spawns')

describe('helpers.git', function()
    after_each(git.cleanup)

    it('builds a repository with one commit on main', function()
        local project = git.project()

        assert.equals('main', project:git('branch', '--show-current'))
        assert.equals('1', project:git('rev-list', '--count', 'HEAD'))
        assert.equals('', project:git('status', '--porcelain'))
        assert.equals(project.path, vim.uv.fs_realpath(project.path))
    end)

    it('copies a project without starting a process', function()
        git.project()
        local project

        local commands = spawns.commands(function()
            project = git.project()
        end)

        assert.equals(0, #commands)
        assert.equals(
            'prohub',
            project:git('cat-file', 'blob', 'main:README.md')
        )
    end)

    it('gives every project its own copy of the template', function()
        local first, second

        spawns.commands(function()
            first = git.project()
            second = git.project()
        end)
        first:commit('a.txt', 'a', 'add a')

        assert.equals('', first:git('fsck', '--strict'))
        assert.equals('', second:git('fsck', '--strict'))
        assert.equals('2', first:git('rev-list', '--count', 'HEAD'))
        assert.equals('1', second:git('rev-list', '--count', 'HEAD'))
    end)

    it('adds linked worktrees with their own branches', function()
        local project = git.project()
        local feature = project:worktree('feature/login')
        local fix = project:worktree('fix')

        assert.equals('feature/login', feature:git('branch', '--show-current'))
        assert.equals('fix', fix:git('branch', '--show-current'))

        local list = project:git('worktree', 'list', '--porcelain')
        assert.is_truthy(list:find('worktree ' .. project.path, 1, true))
        assert.is_truthy(list:find('worktree ' .. feature.path, 1, true))
        assert.is_truthy(list:find('worktree ' .. fix.path, 1, true))
    end)

    it('adds a linked worktree without starting a process', function()
        git.project():worktree('warm-up')
        local project = git.project()
        local feature

        local commands = spawns.commands(function()
            feature = project:worktree('feature/login')
        end)

        assert.equals(0, #commands)
        assert.equals('feature/login', feature:git('branch', '--show-current'))
        assert.equals('', feature:git('status', '--porcelain'))
        assert.equals('', project:git('fsck', '--strict'))
        assert.is_truthy(
            project
                :git('worktree', 'list', '--porcelain')
                :find('worktree ' .. feature.path, 1, true)
        )
    end)

    it('gives the worktree its own branch and its own HEAD', function()
        local project = git.project()
        local feature = project:worktree('feature')

        feature:commit('a.txt', 'a', 'a change on the feature')

        assert.equals('2', feature:git('rev-list', '--count', 'HEAD'))
        assert.equals('1', project:git('rev-list', '--count', 'HEAD'))
        assert.equals('a', feature:git('cat-file', 'blob', 'HEAD:a.txt'))
    end)

    it('asks git for a worktree when HEAD has moved', function()
        local project = git.project()
        project:commit('a.txt', 'a', 'add a')
        local fix

        local commands = spawns.commands(function()
            fix = project:worktree('fix')
        end)

        assert.equals(1, #commands)
        assert.equals('a', fix:git('cat-file', 'blob', 'HEAD:a.txt'))
    end)

    it('makes commits', function()
        local project = git.project()

        project:commit('a.txt', 'a', 'add a')

        assert.equals('2', project:git('rev-list', '--count', 'HEAD'))
        assert.equals('add a', project:git('log', '-1', '--format=%s'))
    end)

    it('runs git without the git project paths of the editor', function()
        local project = git.project()
        local saved = {}
        for _, name in ipairs({ 'GIT_DIR', 'GIT_WORK_TREE', 'GIT_INDEX_FILE' }) do
            saved[name] = vim.env[name]
            vim.env[name] = '/nonexistent'
        end

        local ok, err = pcall(function()
            project:commit('a.txt', 'a')
        end)

        for name, value in pairs(saved) do
            vim.env[name] = value
        end

        assert.is_true(ok, err)
        assert.equals('2', project:git('rev-list', '--count', 'HEAD'))
    end)

    it('leaves staged, unstaged and untracked changes', function()
        local project = git.project()

        project:stage('staged.txt')
        project:modify('README.md', 'changed')
        project:create('untracked.txt')

        assert.equals(
            ' M README.md\nA  staged.txt\n?? untracked.txt',
            project:git('status', '--porcelain')
        )
    end)

    it('refuses to modify a file that git does not know', function()
        local project = git.project()

        assert.has_error(function()
            project:modify('unknown.txt', 'x')
        end)
    end)

    it('sets up a remote with an upstream and unpushed commits', function()
        local project = git.project()
        local feature = project:worktree('feature')

        project:push()
        feature:push()
        feature:commit('a.txt', 'a')

        assert.equals(
            'origin/main',
            project:git('rev-parse', '--abbrev-ref', '@{upstream}')
        )
        assert.equals(
            'origin/feature',
            feature:git('rev-parse', '--abbrev-ref', '@{upstream}')
        )
        assert.equals(
            '1',
            feature:git('rev-list', '--count', '@{upstream}..HEAD')
        )
    end)

    it('leaves a detached HEAD', function()
        local project = git.project()

        project:detach()

        assert.equals('', project:git('branch', '--show-current'))
    end)

    it('leaves a worktree prunable when its directory is deleted', function()
        local project = git.project()
        local feature = project:worktree('feature')

        feature:delete_dir()

        assert.is_nil(vim.uv.fs_stat(feature.path))
        assert.is_truthy(
            project
                :git('worktree', 'list', '--porcelain')
                :find('prunable', 1, true)
        )
    end)

    it('copies the remote of a project without starting a process', function()
        git.project():push()
        local project = git.project()

        local commands = spawns.commands(function()
            project:push()
        end)

        assert.equals(2, #commands)
        assert.equals(
            'origin/main',
            project:git('rev-parse', '--abbrev-ref', '@{upstream}')
        )
        assert.equals(
            project:git('rev-parse', 'main'),
            project
                :git('ls-remote', project:remote(), 'refs/heads/main')
                :match('^(%x+)')
        )
    end)

    it('copies a bare layout without starting a process', function()
        git.bare()
        local bare, main

        local commands = spawns.commands(function()
            bare, main = git.bare()
        end)

        assert.equals(0, #commands)
        assert.equals('', bare:git('fsck', '--strict'))
        assert.equals('main', main:git('branch', '--show-current'))
        assert.equals('', main:git('status', '--porcelain'))
    end)

    it('builds a bare layout with linked worktrees', function()
        local bare, main = git.bare()
        git.bare():worktree('warm-up')
        local feature

        local commands = spawns.commands(function()
            feature = bare:worktree('feature')
        end)

        assert.equals(0, #commands)

        assert.equals('true', bare:git('rev-parse', '--is-bare-repository'))
        assert.equals('main', main:git('branch', '--show-current'))
        assert.equals('feature', feature:git('branch', '--show-current'))

        local list = bare:git('worktree', 'list', '--porcelain')
        assert.is_truthy(list:find('worktree ' .. bare.path, 1, true))
        assert.is_truthy(list:find('worktree ' .. main.path, 1, true))
        assert.is_truthy(list:find('worktree ' .. feature.path, 1, true))
    end)

    it('removes everything it created on cleanup', function()
        local project = git.project()
        local bare = git.bare()

        git.cleanup()

        assert.is_nil(vim.uv.fs_stat(project.container))
        assert.is_nil(vim.uv.fs_stat(bare.container))
    end)
end)
