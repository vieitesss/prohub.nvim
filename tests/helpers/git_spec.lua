local git = require('helpers.git')

describe('helpers.git', function()
    after_each(git.cleanup)

    it('builds a repository with one commit on main', function()
        local project = git.project()

        assert.equals('main', project:git('branch', '--show-current'))
        assert.equals('1', project:git('rev-list', '--count', 'HEAD'))
        assert.equals('', project:git('status', '--porcelain'))
        assert.equals(project.path, vim.uv.fs_realpath(project.path))
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

    it('makes commits', function()
        local project = git.project()

        local sha = project:commit('a.txt', 'a', 'add a')

        assert.equals(sha, project:git('rev-parse', 'HEAD'))
        assert.equals('add a', project:git('log', '-1', '--format=%s'))
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

    it('builds a bare layout with linked worktrees', function()
        local bare, main = git.bare()
        local feature = bare:worktree('feature')

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
