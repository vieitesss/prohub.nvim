local git = require('helpers.git')

describe('prohub commands', function()
    local config, notified, messages
    local origin_cwd = vim.fn.getcwd()

    ---Load the plugin again, so every case starts from the default options and
    ---from the commands as the editor defines them.
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
        vim.g.loaded_prohub = nil
        local plugin = vim.api.nvim_get_runtime_file('plugin/prohub.lua', false)
        vim.cmd.source(plugin[1])
        config = require('prohub.config')
    end

    ---Run a command, the way the editor runs it.
    ---@param cmdline string
    local function run(cmdline)
        vim.cmd(cmdline)
    end

    ---Enter a directory, the way a user does before running a command.
    ---@param dir string
    local function enter(dir)
        vim.cmd('cd ' .. vim.fn.fnameescape(dir))
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

    ---The buffers of the hubs that exist.
    ---@return integer[]
    local function hub_buffers()
        local found = {}
        for _, buffer in ipairs(vim.api.nvim_list_bufs()) do
            if
                vim.api.nvim_buf_is_valid(buffer)
                and vim.api.nvim_buf_get_name(buffer):find('^prohub://', 1)
            then
                table.insert(found, buffer)
            end
        end
        return found
    end

    ---Close every tab but one, so a case never sees a hub or a review of
    ---another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
        for _, buffer in ipairs(hub_buffers()) do
            pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        end
    end

    ---A diff viewer that records the context it is given.
    ---@return prohub.Viewer viewer
    ---@return table[] calls
    local function recording_viewer()
        local calls = {}
        return function(ctx)
            table.insert(calls, ctx)
            return true
        end,
            calls
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
        pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(origin_cwd))
        git.cleanup()
        vim.g.prohub = nil
        vim.g.loaded_prohub = nil
    end)

    it('defines the commands without loading prohub', function()
        assert.equals(2, vim.fn.exists(':Prohub'))
        assert.equals(2, vim.fn.exists(':ProhubReview'))
        assert.is_nil(package.loaded['prohub'])
        assert.is_nil(package.loaded['prohub.command'])
    end)

    it('shows the hub in a new tabpage', function()
        local project = git.project()
        enter(project.path)
        local before = tabs()

        run('Prohub')

        local rendered = vim.wait(5000, function()
            return #hub_buffers() > 0
        end)
        assert.is_true(rendered, 'the hub did not render')
        assert.equals(before + 1, tabs())
        assert.is_truthy(
            vim.api
                .nvim_buf_get_name(vim.api.nvim_get_current_buf())
                :find('^prohub://', 1)
        )
        assert.equals(0, #messages)
    end)

    it('opens the review of the path the command names', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local project = git.project()
        local feature = project:worktree('feature')
        local before = tabs()

        run('ProhubReview ' .. vim.fn.fnameescape(feature.path))

        assert.equals(before + 1, tabs())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].path)
        assert.equals('branch', calls[1].scope)
        assert.equals(0, #messages)
        assert.equals(
            feature.path,
            vim.fn.getcwd(-1, vim.api.nvim_tabpage_get_number(current()))
        )
    end)

    it('reviews the current directory with the scope it names', function()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local project = git.project()
        enter(project.path)
        local before = tabs()

        run('ProhubReview uncommitted')

        assert.equals(before + 1, tabs())
        assert.equals(1, #calls)
        assert.equals(project.path, calls[1].path)
        assert.equals('uncommitted', calls[1].scope)
        assert.equals(0, #messages)
    end)

    it('notifies once and opens no tab when the review fails', function()
        local project = git.project()
        enter(project.path)
        local before = tabs()

        run('ProhubReview /nonexistent/prohub-worktree')

        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.is_truthy(messages[1].message:find('does not exist', 1, true))
        assert.equals(before, tabs())
    end)

    it('notifies once and opens no tab when the scope is unknown', function()
        local project = git.project()
        enter(project.path)
        local before = tabs()

        run('ProhubReview ' .. vim.fn.fnameescape(project.path) .. ' all')

        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.is_truthy(messages[1].message:find('unknown scope', 1, true))
        assert.is_truthy(messages[1].message:find('branch', 1, true))
        assert.equals(before, tabs())
    end)

    it('notifies once when the hub cannot be opened', function()
        local project = git.project()
        enter(project.path)
        vim.g.prohub = { diff_viewer = 42 }
        local before = tabs()

        run('Prohub')

        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals(before, tabs())
        assert.equals(0, #hub_buffers())
    end)
end)
