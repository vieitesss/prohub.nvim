local git = require('helpers.git')

describe('prohub hub', function()
    local config, hub, prohub, review, tab
    local notified, messages
    local origin_cwd = vim.fn.getcwd()

    ---Reload the modules under test. The hub remembers the tabpage and the
    ---buffer of every hub it opened, and the status module caches what it
    ---collected, so the whole plugin is loaded again and starts from defaults.
    local function reload()
        local names = {}
        for name in pairs(package.loaded) do
            if name == 'prohub' or name:match('^prohub%.') then
                table.insert(names, name)
            end
        end
        for _, name in ipairs(names) do
            package.loaded[name] = nil
        end

        vim.g.prohub = nil
        config = require('prohub.config')
        hub = require('prohub.hub')
        review = require('prohub.review')
        tab = require('prohub.tab')
        prohub = require('prohub')
    end

    ---The number of tabpages that are open.
    ---@return integer
    local function tabs()
        return #vim.api.nvim_list_tabpages()
    end

    ---The tabpage that is current.
    ---@return integer
    local function current()
        return vim.api.nvim_get_current_tabpage()
    end

    ---The tab-local working directory of a tabpage.
    ---@param tabpage integer
    ---@return string
    local function tab_cwd(tabpage)
        return vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(tabpage))
    end

    ---Close every tab but one, so a case never sees the hub of another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
    end

    ---The buffers of the hubs that exist.
    ---@return integer[]
    local function hub_buffers()
        local found = {}
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if vim.api.nvim_buf_is_valid(buffer) then
                local name = vim.api.nvim_buf_get_name(buffer)
                if name:find('^prohub://', 1) then
                    table.insert(found, buffer)
                end
            end
        end
        return found
    end

    ---Remove the buffers of the hubs, so a case never finds one of another.
    local function wipe_hub_buffers()
        for _, buffer in ipairs(hub_buffers()) do
            pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        end
    end

    ---The buffer of the hub that shows `key`, if it exists.
    ---@param key string
    ---@return integer?
    local function buffer_of(key)
        local name = 'prohub://' .. key
        for _, buffer in ipairs(hub_buffers()) do
            if vim.api.nvim_buf_get_name(buffer) == name then
                return buffer
            end
        end
    end

    ---The buffer of the hub that shows `key`, waiting for the render.
    ---@param key string
    ---@return integer buffer
    local function wait_for_buffer(key)
        local buffer = buffer_of(key)
        local rendered = vim.wait(5000, function()
            buffer = buffer_of(key)
            return buffer ~= nil
        end)
        assert.is_true(rendered, ('the hub of %s did not render'):format(key))
        return buffer
    end

    ---The lines of a buffer.
    ---@param buffer integer
    ---@return string[]
    local function lines_of(buffer)
        return vim.api.nvim_buf_get_lines(buffer, 0, -1, false)
    end

    ---Wait for a condition, because a render runs later on the main loop.
    ---@param condition fun(): boolean
    ---@param message string
    local function wait_for(condition, message)
        assert.is_true(vim.wait(5000, condition), message)
    end

    ---The row of a worktree, found by the name the row starts with.
    ---@param lines string[]
    ---@param name string
    ---@return integer? line
    ---@return string? text
    local function row_of(lines, name)
        for line, text in ipairs(lines) do
            if text:match('^(%S+)') == name then
                return line, text
            end
        end
    end

    ---Open the hub of a directory and wait for its rows.
    ---@param dir string Directory the hub is opened from.
    ---@param key string Identity of the hub, which is not always `dir`.
    ---@return integer buffer
    local function open(dir, key)
        assert.is_true(hub.open({ cwd = dir }))
        return wait_for_buffer(key)
    end

    ---A diff viewer that records its context and shows a scratch buffer in the
    ---tabpage of the review, which exposes its `on_close` to the case.
    ---@return prohub.Viewer viewer
    ---@return table[] calls
    local function recording_viewer()
        local calls = {}
        local function viewer(ctx)
            local buffer = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_win_set_buf(0, buffer)
            table.insert(calls, { ctx = ctx, tabpage = current() })
            return true
        end
        return viewer, calls
    end

    before_each(function()
        reload()
        notified = vim.notify
        messages = {}
        vim.notify = function(message, level)
            table.insert(messages, { message = message, level = level })
        end
    end)

    after_each(function()
        vim.notify = notified
        close_tabs()
        wipe_hub_buffers()
        pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(origin_cwd))
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('shows one row per worktree in git order with its counts', function()
        local project = git.project()
        local zeta = project:worktree('zeta')
        local alpha = project:worktree('alpha')

        project:commit('main.txt', 'main', 'main moves')
        alpha:commit('one.txt', 'one', 'add one')
        alpha:stage('staged.txt', 'staged')
        alpha:modify('README.md', 'changed')
        alpha:create('untracked.txt', 'untracked')

        local lines = lines_of(open(project.path, project.path))

        assert.equals('name   path     s u ?  a b  c  p', lines[1])
        assert.equals(4, #lines)
        assert.equals(
            'main   project  0 0 0  0 0  -  on the default branch',
            lines[2]
        )
        assert.equals('alpha  alpha    1 1 1  1 1  4', lines[3])
        assert.equals('zeta   zeta     0 0 0  0 1  0', lines[4])
    end)

    it(
        'shows the unpushed commits when the branch has a counterpart',
        function()
            local project = git.project()
            local feature = project:worktree('feature')
            project:push()
            feature:push()
            feature:commit('one.txt', 'one', 'add one')

            local lines = lines_of(open(project.path, project.path))

            assert.equals(3, #lines)
            assert.is_truthy(lines[1]:match('%sp$'))
            assert.equals(
                'main     project  0 0 0  0 0  -  0  on the default branch',
                lines[2]
            )
            assert.equals('feature  feature  0 0 0  1 0  1  1', lines[3])
        end
    )

    it('shows the short commit of a detached HEAD', function()
        local project = git.project()
        local detached = project:worktree('detached')
        local commit = detached:git('rev-parse', 'HEAD'):sub(1, 7)
        detached:detach()

        local lines = lines_of(open(project.path, project.path))
        local line, text = row_of(lines, commit)

        assert.is_not_nil(line, 'no row starts with the short commit')
        assert.is_truthy(text:match('^%x%x%x%x%x%x%x%s'))
        assert.is_truthy(text:match('%sdetached%s'))
        assert.equals(commit, text:match('^(%S+)'))
    end)

    it('shows a missing worktree as a dim row', function()
        local project = git.project()
        local zeta = project:worktree('zeta')
        project:worktree('alpha')
        zeta:delete_dir()

        local buffer = open(project.path, project.path)
        local lines = lines_of(buffer)
        local line, text = row_of(lines, 'zeta')

        assert.is_not_nil(line, 'no row starts with the branch of the worktree')
        assert.is_truthy(text:match('%smissing$'))
        assert.is_truthy(text:match('%s%- %- %-%s'))

        local namespace = vim.api.nvim_get_namespaces().prohub_hub
        local marks = vim.api.nvim_buf_get_extmarks(
            buffer,
            namespace,
            0,
            -1,
            { details = true }
        )
        assert.equals(1, #marks)
        assert.equals(line - 1, marks[1][2])
        assert.equals('ProhubMissing', marks[1][4].hl_group)
        assert.equals(
            'Comment',
            vim.api.nvim_get_hl(0, { name = 'ProhubMissing', link = true }).link
        )
    end)

    it(
        'marks its tab and reuses it for another worktree of the project',
        function()
            local project = git.project()
            local zeta = project:worktree('zeta')
            local alpha = project:worktree('alpha')

            local buffer = open(project.path, project.path)
            local hub_tabpage = current()

            assert.equals(2, tabs())
            assert.equals(hub_tabpage, tab.hub())
            assert.equals(project.path, tab_cwd(hub_tabpage))

            vim.cmd('tabnew')
            assert.equals(3, tabs())

            assert.is_true(hub.open({ cwd = alpha.path }))
            wait_for(function()
                return current() == hub_tabpage
            end, 'the hub did not go back to its tabpage')

            assert.equals(hub_tabpage, current())
            assert.equals(3, tabs())
            assert.equals(buffer, vim.api.nvim_get_current_buf())
            assert.equals(4, #lines_of(buffer))
            assert.equals(hub_tabpage, tab.hub())
            assert.equals(project.path, tab_cwd(hub_tabpage))

            assert.equals('nofile', vim.bo[buffer].buftype)
            assert.equals('hide', vim.bo[buffer].bufhidden)
            assert.is_false(vim.bo[buffer].swapfile)
            assert.is_false(vim.bo[buffer].buflisted)
            assert.is_false(vim.bo[buffer].modifiable)
            assert.equals('prohub', vim.bo[buffer].filetype)
        end
    )

    it(
        'keeps the cursor on its worktree when a row appears before it',
        function()
            local project = git.project()
            local zeta = project:worktree('zeta')
            project:worktree('alpha')

            local buffer = open(project.path, project.path)
            local hub_tabpage = current()
            local window = vim.api.nvim_get_current_win()
            local line = row_of(lines_of(buffer), 'zeta')
            vim.api.nvim_win_set_cursor(window, { line, 0 })

            vim.cmd('tabnew')
            project:worktree('aaa')
            assert.is_true(hub.open({ cwd = project.path }))
            wait_for(function()
                return current() == hub_tabpage and #lines_of(buffer) == 5
            end, 'the hub did not render the new worktree')

            local lines = lines_of(buffer)
            local cursor = vim.api.nvim_win_get_cursor(window)[1]

            assert.equals(hub_tabpage, current())
            assert.equals(5, #lines)
            assert.equals('aaa', lines[3]:match('^(%S+)'))
            assert.is_truthy(lines[cursor]:match('^zeta%s'))
        end
    )

    it('falls back to the first row when its worktree is gone', function()
        local project = git.project()
        local zeta = project:worktree('zeta')
        project:worktree('alpha')

        local buffer = open(project.path, project.path)
        local window = vim.api.nvim_get_current_win()
        local line = row_of(lines_of(buffer), 'zeta')
        vim.api.nvim_win_set_cursor(window, { line, 0 })

        project:git('worktree', 'remove', zeta.path)
        assert.is_true(hub.open({ cwd = project.path }))
        wait_for(function()
            return #lines_of(buffer) == 3
        end, 'the hub did not remove the row of the worktree')

        local lines = lines_of(buffer)
        local cursor = vim.api.nvim_win_get_cursor(window)[1]

        assert.equals(3, #lines)
        assert.is_nil(row_of(lines, 'zeta'))
        assert.equals(2, cursor)
        assert.equals('main', lines[cursor]:match('^(%S+)'))
    end)

    it(
        'shows the worktrees of a workset in the order of the workset',
        function()
            local project = git.project()
            local feature = project:worktree('feature')
            local fix = project:worktree('fix')
            local key = vim.fn.tempname()
            vim.fn.mkdir(key, 'p')
            key = assert(vim.uv.fs_realpath(key))
            assert.is_true(config.setup({
                worksets = { [key] = { fix.path, feature.path } },
            }))

            local buffer = open(key, key)
            local lines = lines_of(buffer)

            assert.equals('name     path     s u ?  a b  c  p', lines[1])
            assert.equals(3, #lines)
            assert.equals('fix      fix      0 0 0  0 0  0', lines[2])
            assert.equals('feature  feature  0 0 0  0 0  0', lines[3])
            assert.equals(key, tab_cwd(current()))
        end
    )

    it('shows the worktrees of a bare layout under one hub', function()
        local bare, main = git.bare()
        local feature = bare:worktree('feature')

        local buffer = open(main.path, feature.path)
        local lines = lines_of(buffer)
        local hub_tabpage = current()

        assert.equals('name     path     s u ?  a b  c  p', lines[1])
        assert.equals(3, #lines)
        assert.equals('feature  feature  0 0 0  0 0  0', lines[2])
        assert.equals(
            'main     main     0 0 0  0 0  -  on the default branch',
            lines[3]
        )
        assert.equals(feature.path, tab_cwd(hub_tabpage))

        vim.cmd('tabnew')
        assert.is_true(hub.open({ cwd = bare.path }))
        wait_for(function()
            return current() == hub_tabpage
        end, 'the hub did not go back to its tabpage')

        assert.equals(hub_tabpage, current())
        assert.equals(3, tabs())
        assert.equals(buffer, vim.api.nvim_get_current_buf())
    end)

    it('shows a status error in its row without failing the hub', function()
        local project = git.project()
        local zeta = project:worktree('zeta')
        local status = require('prohub.status')
        local collect = status.collect
        status.collect = function(path, callback)
            if path == zeta.path then
                vim.schedule(function()
                    callback(nil, 'the status failed')
                end)
                return true
            end
            return collect(path, callback)
        end

        local lines = lines_of(open(project.path, project.path))
        local line, text = row_of(lines, 'zeta')

        assert.is_not_nil(line, 'the hub did not render the failing worktree')
        assert.is_truthy(text:match('%serror: the status failed$'))
        assert.is_truthy(lines[2]:match('^main%s'))
    end)

    it('opens no tab outside every project and workset', function()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        local before = tabs()

        assert.is_true(hub.open({ cwd = dir }))

        assert.is_true(vim.wait(5000, function()
            return #messages > 0
        end))

        -- The hub receives the empty listing right after the warning, so a
        -- moment without a tab proves that it opened none.
        assert.is_false(vim.wait(200, function()
            return tabs() > before
        end))

        assert.equals(before, tabs())
        assert.equals(0, #hub_buffers())
        assert.equals(vim.log.levels.WARN, messages[1].level)
    end)

    it('notifies an error of the worktree list and opens no tab', function()
        local key = vim.fn.tempname()
        vim.fn.mkdir(key, 'p')
        assert.is_true(config.setup({
            worksets = {
                [key] = function()
                    error('the workset failed')
                end,
            },
        }))
        local before = tabs()

        assert.is_true(hub.open({ cwd = key }))

        assert.is_true(vim.wait(5000, function()
            return #messages > 0
        end))
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.is_truthy(
            messages[1].message:find('the workset failed', 1, true)
        )
        assert.equals(before, tabs())
    end)

    it('reaches the same flow through prohub.open and never throws', function()
        local project = git.project()
        project:worktree('feature')
        local before = tabs()

        local calls = {
            function()
                return prohub.open({ cwd = false })
            end,
            function()
                return prohub.open({ cwd = 42 })
            end,
            function()
                return prohub.open({ cwd = '/nonexistent/prohub-dir' })
            end,
        }
        for _, call in ipairs(calls) do
            local called, ok, err = pcall(call)

            assert.is_true(called)
            assert.is_nil(ok)
            assert.is_string(err)
        end
        assert.equals(before, tabs())

        assert.is_true(prohub.open({ cwd = project.path }))
        local lines = lines_of(wait_for_buffer(project.path))

        assert.equals(3, #lines)
        assert.equals('main', lines[2]:match('^(%S+)'))
        assert.equals('feature', lines[3]:match('^(%S+)'))
    end)

    it('returns from a review to the hub when its tab is gone', function()
        local project = git.project()
        local feature = project:worktree('feature')

        open(project.path, project.path)
        local hub_tabpage = current()
        assert.equals(hub_tabpage, tab.hub())

        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        vim.cmd('tabnew')
        local origin = current()
        assert.is_true(review.open(feature.path, { scope = 'uncommitted' }))
        assert.equals(4, tabs())

        vim.cmd(('tabclose %d'):format(vim.api.nvim_tabpage_get_number(origin)))
        assert.is_false(vim.api.nvim_tabpage_is_valid(origin))

        calls[1].ctx.on_close()

        assert.equals(hub_tabpage, current())
        assert.equals(2, tabs())
    end)
end)
