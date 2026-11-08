local git = require('helpers.git')
local spawns = require('helpers.spawns')

describe('prohub hub refresh', function()
    local config, hub, tab
    local notified, messages
    local origin_cwd = vim.fn.getcwd()

    ---The events the hub follows to know whether it is shown and focused.
    ---@type string[]
    local events = {
        'BufEnter',
        'BufHidden',
        'BufWipeout',
        'FocusGained',
        'FocusLost',
        'TabClosed',
        'TabEnter',
        'TabLeave',
        'WinClosed',
        'WinEnter',
        'WinLeave',
    }

    ---Reload the modules under test. The hub remembers the buffer, the timer
    ---and the autocommands of every hub it opened, and the status module caches
    ---what it collected, so the whole plugin is loaded again and starts from
    ---defaults.
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
        tab = require('prohub.tab')
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
    ---A wiped buffer stops the timer and clears the autocommands of its hub.
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
        assert.is_true(vim.wait(5000, condition, 10), message)
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

    ---Whether the row of `name` shows the untracked count `count`.
    ---@param buffer integer
    ---@param name string
    ---@param count integer
    ---@return boolean
    local function row_counts(buffer, name, count)
        local _, text = row_of(lines_of(buffer), name)
        return text ~= nil and text:find('%s0 0 ' .. count .. '%s') ~= nil
    end

    ---Open the hub of a project and wait for its rows.
    ---@param project helpers.git.Tree
    ---@return integer buffer
    local function open(project)
        assert.is_true(hub.open({ cwd = project.path }))
        local buffer = buffer_of(project.path)
        wait_for(function()
            buffer = buffer_of(project.path)
            return buffer ~= nil and #lines_of(buffer) > 1
        end, 'the hub did not render')
        return buffer
    end

    ---The number of processes started while `fn` runs. A refresh starts git as
    ---its first step, so a window without one is a window without a refresh.
    ---@param fn fun()
    ---@return integer
    local function spawned(fn)
        return #spawns.commands(fn)
    end

    ---The autocommands the plugin leaves behind, found by the name of its
    ---groups.
    ---@return string[]
    local function leftovers()
        local found = {}
        for _, autocmd in ipairs(vim.api.nvim_get_autocmds({})) do
            local group = autocmd.group_name or ''
            if group:find('^prohub') then
                table.insert(found, autocmd.event .. ' ' .. group)
            end
        end
        return found
    end

    ---The buffer-local mapping of a key, if the hub has one.
    ---@param buffer integer
    ---@param lhs string
    ---@return table? mapping
    local function mapping(buffer, lhs)
        for _, map in ipairs(vim.api.nvim_buf_get_keymap(buffer, 'n')) do
            if map.lhs == lhs then
                return map
            end
        end
    end

    ---Press a key of the hub by calling the callback of its mapping.
    ---@param buffer integer
    ---@param lhs string
    local function press(buffer, lhs)
        local map = mapping(buffer, lhs)
        assert.is_not_nil(map, ('the hub maps no %s'):format(lhs))
        map.callback()
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

    it('renders the hub again on every tick while it is shown', function()
        assert.is_true(config.setup({ refresh_interval = 60 }))
        local project = git.project()
        local feature = project:worktree('feature')
        local buffer = open(project)

        feature:create('untracked.txt', 'untracked')

        wait_for(function()
            return row_counts(buffer, 'feature', 1)
        end, 'the timer did not render the hub again')
        assert.equals(0, #messages)
    end)

    it('renders a workset hub again from the worktrees it holds now', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local fix = project:worktree('fix')
        local key = vim.fn.tempname()
        vim.fn.mkdir(key, 'p')
        key = assert(vim.uv.fs_realpath(key))
        local entries = { feature.path }
        assert.is_true(config.setup({
            refresh_interval = 60,
            worksets = {
                [key] = function()
                    return entries
                end,
            },
        }))

        assert.is_true(hub.open({ cwd = key }))
        local buffer = buffer_of(key)
        wait_for(function()
            buffer = buffer_of(key)
            return buffer ~= nil and #lines_of(buffer) == 2
        end, 'the hub did not render the workset')
        assert.equals('feature', lines_of(buffer)[2]:match('^(%S+)'))

        -- A workset is read again on every render, so a worktree the
        -- workset gained shows up and the ones it holds count again.
        entries = { feature.path, fix.path }
        wait_for(function()
            return #lines_of(buffer) == 3
        end, 'the hub did not render the workset again')
        assert.equals('fix', lines_of(buffer)[3]:match('^(%S+)'))

        fix:create('untracked.txt', 'untracked')
        wait_for(function()
            return row_counts(buffer, 'fix', 1)
        end, 'the timer did not render the hub again')
        assert.equals(0, #messages)
    end)

    it(
        'stops while Neovim is unfocused and renders when it is focused',
        function()
            assert.is_true(config.setup({ refresh_interval = 60 }))
            local project = git.project()
            local feature = project:worktree('feature')
            local buffer = open(project)

            vim.api.nvim_exec_autocmds('FocusLost', {})
            feature:create('untracked.txt', 'untracked')

            -- A tick would start git within the window if the timer still ran.
            vim.wait(120)
            assert.equals(
                0,
                spawned(function()
                    vim.wait(240)
                end)
            )

            assert.is_true(spawned(function()
                vim.api.nvim_exec_autocmds('FocusGained', {})
            end) > 0, 'no refresh started when Neovim gained focus')
            wait_for(function()
                return row_counts(buffer, 'feature', 1)
            end, 'the hub did not show the new file after focus returned')

            feature:create('later.txt', 'later')
            wait_for(function()
                return row_counts(buffer, 'feature', 2)
            end, 'the timer did not run again after focus returned')
        end
    )

    it(
        'stops on another tabpage and renders when it is entered again',
        function()
            assert.is_true(config.setup({ refresh_interval = 60 }))
            local project = git.project()
            local feature = project:worktree('feature')
            local buffer = open(project)
            local hub_tabpage = current()

            vim.cmd('tabnew')
            vim.wait(120)
            assert.equals(
                0,
                spawned(function()
                    vim.wait(240)
                end)
            )

            feature:create('untracked.txt', 'untracked')
            assert.is_true(spawned(function()
                vim.api.nvim_set_current_tabpage(hub_tabpage)
            end) > 0, 'the hub did not render when it was entered')
            wait_for(function()
                return row_counts(buffer, 'feature', 1)
            end, 'the hub did not show the new file after it was entered')

            feature:create('later.txt', 'later')
            wait_for(function()
                return row_counts(buffer, 'feature', 2)
            end, 'the timer did not run again after the hub was entered')
        end
    )

    it(
        'stops when its buffer is hidden and renders when it is shown',
        function()
            assert.is_true(config.setup({ refresh_interval = 60 }))
            local project = git.project()
            local feature = project:worktree('feature')
            local buffer = open(project)
            local window = vim.api.nvim_get_current_win()

            vim.cmd('enew')
            assert.is_false(vim.api.nvim_win_get_buf(window) == buffer)

            vim.wait(120)
            assert.equals(
                0,
                spawned(function()
                    vim.wait(240)
                end)
            )

            feature:create('untracked.txt', 'untracked')
            assert.is_true(
                spawned(function()
                    vim.api.nvim_win_set_buf(window, buffer)
                end) > 0,
                'the hub did not render when its buffer was shown again'
            )
            wait_for(function()
                return row_counts(buffer, 'feature', 1)
            end, 'the hub did not show the new file after it was shown again')

            feature:create('later.txt', 'later')
            wait_for(function()
                return row_counts(buffer, 'feature', 2)
            end, 'the timer did not run again after the buffer was shown')
        end
    )

    it('renders in place when the tabpage is left while git answers', function()
        assert.is_true(config.setup({ refresh_interval = 60000 }))
        local project = git.project()
        local feature = project:worktree('feature')
        local buffer = open(project)
        local hub_tabpage = current()
        local before = tabs()

        feature:create('untracked.txt', 'untracked')

        -- The refresh starts here, and git answers only after the hub tabpage
        -- stops being the current one.
        vim.api.nvim_exec_autocmds('FocusGained', {})
        vim.cmd('tabnew')
        local elsewhere = current()
        assert.is_false(elsewhere == hub_tabpage)

        wait_for(function()
            return row_counts(buffer, 'feature', 1)
        end, 'the refresh did not render the hub')

        assert.equals(elsewhere, current())
        assert.equals(before + 1, tabs())
        assert.equals(hub_tabpage, tab.hub())
    end)

    it('keeps the cursor on its worktree when a row moves', function()
        assert.is_true(config.setup({ refresh_interval = 60 }))
        local project = git.project()
        local feature = project:worktree('feature')
        local buffer = open(project)
        local window = vim.api.nvim_get_current_win()
        local line = row_of(lines_of(buffer), 'feature')
        assert.is_not_nil(line, 'no row of the worktree')
        vim.api.nvim_win_set_cursor(window, { line, 0 })

        project:worktree('aaa')

        wait_for(function()
            return #lines_of(buffer) == 4
                and vim.api.nvim_win_get_cursor(window)[1] ~= line
        end, 'the hub did not render the new worktree')
        local cursor = vim.api.nvim_win_get_cursor(window)[1]
        assert.equals('feature', lines_of(buffer)[cursor]:match('^(%S+)'))
    end)

    it('stops the timer and clears its autocmds when it is closed', function()
        assert.is_true(config.setup({ refresh_interval = 60 }))
        local project = git.project()
        local feature = project:worktree('feature')
        local buffer = open(project)

        local installed = {}
        local group = ('prohub_hub_refresh_%d'):format(buffer)
        for _, autocmd in ipairs(vim.api.nvim_get_autocmds({ group = group })) do
            table.insert(installed, autocmd.event)
        end
        table.sort(installed)
        assert.same(events, installed)

        press(buffer, 'q')

        assert.equals(0, #vim.api.nvim_get_autocmds({ buffer = buffer }))
        assert.same({}, leftovers())

        vim.wait(120)
        feature:create('untracked.txt', 'untracked')
        assert.equals(
            0,
            spawned(function()
                vim.wait(240)
            end)
        )
    end)

    it('logs a failed automatic refresh instead of notifying', function()
        assert.is_true(config.setup({ refresh_interval = 60000 }))
        local project = git.project()
        local buffer = open(project)
        local lines = lines_of(buffer)

        -- The project directory is still there, but git can no longer list it.
        vim.fn.delete(project.path .. '/.git', 'rf')

        vim.api.nvim_exec_autocmds('FocusGained', {})
        vim.wait(200)

        assert.equals(0, #messages)
        assert.same(lines, lines_of(buffer))
    end)
end)
