local git = require('helpers.git')

describe('prohub.command', function()
    local command
    local notified
    local origin_cwd = vim.fn.getcwd()
    local origin_home = vim.env.HOME
    local temporary = {}

    ---Create a directory that no other case sees, and remove it afterwards.
    ---@return string
    local function temporary_dir()
        local dir = vim.fn.tempname()
        vim.fn.mkdir(dir, 'p')
        table.insert(temporary, dir)
        return assert(vim.uv.fs_realpath(dir))
    end

    ---Load the plugin again, so every case starts from the default options.
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
        command = require('prohub.command')
    end

    ---Enter a directory, the way a user does before running a command.
    ---@param dir string
    local function enter(dir)
        vim.cmd('cd ' .. vim.fn.fnameescape(dir))
    end

    ---Close every tab but one, so a case never sees the hub or a review of
    ---another one.
    local function close_tabs()
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        pcall(vim.cmd, 'silent! tabonly!')
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

    ---Wait for the hub to render, and return its buffer.
    ---@return integer buffer
    local function wait_for_hub()
        local buffers
        local rendered = vim.wait(5000, function()
            buffers = hub_buffers()
            return #buffers > 0
        end)
        assert.is_true(rendered, 'the hub did not render')
        return buffers[1]
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

    ---Replace `vim.notify` for the case and collect what it receives.
    ---@return table[] messages
    local function collect_notifications()
        local messages = {}
        vim.notify = function(message, level)
            table.insert(messages, { message = message, level = level })
        end
        return messages
    end

    before_each(function()
        reload()
        notified = vim.notify
    end)

    after_each(function()
        vim.notify = notified
        close_tabs()
        for _, buffer in ipairs(hub_buffers()) do
            pcall(vim.api.nvim_buf_delete, buffer, { force = true })
        end
        pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(origin_cwd))
        pcall(vim.cmd, 'silent! bwipeout!')
        vim.env.HOME = origin_home
        for _, dir in ipairs(temporary) do
            vim.fn.delete(dir, 'rf')
        end
        temporary = {}
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('parses no argument as the current directory', function()
        local project = git.project()
        enter(project.path)

        local args, err = command.parse_review({})

        assert.is_nil(err)
        assert.is_not_nil(args)
        assert.equals(project.path, args.path)
        assert.is_nil(args.scope)
    end)

    it(
        'makes a relative path absolute against the current directory',
        function()
            local dir = temporary_dir()
            vim.fn.mkdir(dir .. '/sub', 'p')
            enter(dir)

            local args, err = command.parse_review({ 'sub' })

            assert.is_nil(err)
            assert.equals(dir .. '/sub', args.path)
            assert.is_nil(args.scope)
        end
    )

    it('expands a home directory and the name of the buffer', function()
        local dir = temporary_dir()
        vim.env.HOME = dir
        enter(dir)
        vim.fn.writefile({ 'one' }, dir .. '/a.txt')
        vim.cmd('edit a.txt')

        local home, home_err = command.parse_review({ '~' })
        local buffer, buffer_err = command.parse_review({ '%' })

        assert.is_nil(home_err)
        assert.is_nil(buffer_err)
        assert.equals(dir, home.path)
        assert.equals(dir .. '/a.txt', buffer.path)
    end)

    it('takes one scope name as the scope of the current directory', function()
        local dir = temporary_dir()
        enter(dir)

        local args, err = command.parse_review({ 'unpushed' })

        assert.is_nil(err)
        assert.equals(dir, args.path)
        assert.equals('unpushed', args.scope)
    end)

    it('takes one scope name as a path when that name exists here', function()
        local dir = temporary_dir()
        vim.fn.mkdir(dir .. '/branch', 'p')
        enter(dir)

        local args, err = command.parse_review({ 'branch' })

        assert.is_nil(err)
        assert.equals(dir .. '/branch', args.path)
        assert.is_nil(args.scope)
    end)

    it('takes two arguments as the path and the scope', function()
        local project = git.project()
        enter(project.path)

        local args, err = command.parse_review({ project.path, 'uncommitted' })

        assert.is_nil(err)
        assert.equals(project.path, args.path)
        assert.equals('uncommitted', args.scope)
    end)

    it('names the valid scopes when the scope is unknown', function()
        local project = git.project()
        enter(project.path)

        local args, err = command.parse_review({ project.path, 'everything' })

        assert.is_nil(args)
        assert.is_string(err)
        assert.is_truthy(err:find('unknown scope', 1, true))
        assert.is_truthy(err:find('everything', 1, true))
        assert.is_truthy(err:find('branch', 1, true))
        assert.is_truthy(err:find('unpushed', 1, true))
        assert.is_truthy(err:find('uncommitted', 1, true))
    end)

    it('returns an error for more than two arguments', function()
        enter(temporary_dir())

        local args, err = command.parse_review({ 'one', 'branch', 'two' })

        assert.is_nil(args)
        assert.is_string(err)
        assert.is_truthy(err:find('arguments', 1, true))
    end)

    it(
        'returns an error for arguments that are not a list of strings',
        function()
            enter(temporary_dir())

            local calls = {
                function()
                    return command.parse_review('branch')
                end,
                function()
                    return command.parse_review({ 42 })
                end,
            }

            for _, call in ipairs(calls) do
                local called, args, err = pcall(call)
                assert.is_true(called)
                assert.is_nil(args)
                assert.is_string(err)
            end
        end
    )

    it('opens the review of the path the command names', function()
        local viewer, calls = recording_viewer()
        assert.is_true(require('prohub.config').setup({
            diff_viewer = viewer,
        }))
        local messages = collect_notifications()
        local project = git.project()
        local feature = project:worktree('feature')

        local ok, err = command.review({ feature.path, 'uncommitted' })

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(0, #messages)
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].path)
        assert.equals('uncommitted', calls[1].scope)
    end)

    it('reviews the current directory when no path is given', function()
        local viewer, calls = recording_viewer()
        assert.is_true(require('prohub.config').setup({
            diff_viewer = viewer,
        }))
        collect_notifications()
        local project = git.project()
        enter(project.path)

        local ok, err = command.review({ 'uncommitted' })

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(1, #calls)
        assert.equals(project.path, calls[1].path)
        assert.equals('uncommitted', calls[1].scope)
    end)

    it('notifies once when the review cannot be opened', function()
        assert.is_true(require('prohub.config').setup({
            diff_viewer = function()
                return nil, 'the diff viewer failed'
            end,
        }))
        local messages = collect_notifications()
        local project = git.project()
        local feature = project:worktree('feature')

        local ok, err = command.review({ feature.path, 'uncommitted' })

        assert.is_nil(ok)
        assert.equals('the diff viewer failed', err)
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals('the diff viewer failed', messages[1].message)
        assert.equals(1, #vim.api.nvim_list_tabpages())
    end)

    it('notifies once when the arguments are wrong', function()
        local messages = collect_notifications()
        enter(temporary_dir())

        local ok, err = command.review({ 'one', 'branch', 'two' })

        assert.is_nil(ok)
        assert.is_string(err)
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals(err, messages[1].message)
    end)

    it('opens the hub of the current directory', function()
        local messages = collect_notifications()
        local project = git.project()
        enter(project.path)

        local ok, err = command.prohub({})

        assert.is_nil(err)
        assert.is_true(ok)
        assert.equals(0, #messages)
        local buffer = wait_for_hub()
        assert.is_true(vim.api.nvim_buf_is_valid(buffer))
        assert.equals(2, #vim.api.nvim_list_tabpages())
        assert.equals(
            project.path,
            vim.fn.getcwd(
                -1,
                vim.api.nvim_tabpage_get_number(
                    vim.api.nvim_get_current_tabpage()
                )
            )
        )
    end)

    it('notifies once when the hub cannot be opened', function()
        local messages = collect_notifications()
        local project = git.project()
        enter(project.path)
        vim.g.prohub = { diff_viewer = 42 }

        local ok, err = command.prohub({})

        assert.is_nil(ok)
        assert.is_string(err)
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals(err, messages[1].message)
        assert.equals(1, #vim.api.nvim_list_tabpages())
        assert.equals(0, #hub_buffers())
    end)

    it('notifies once when :Prohub receives an argument', function()
        local messages = collect_notifications()
        enter(temporary_dir())

        local ok, err = command.prohub({ 'extra' })

        assert.is_nil(ok)
        assert.is_string(err)
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals(err, messages[1].message)
    end)

    ---The position of a candidate in a list of completions, if it is there.
    ---@param matches string[]
    ---@param candidate string
    ---@return integer? position
    local function position_of(matches, candidate)
        for index, match in ipairs(matches) do
            if match == candidate then
                return index
            end
        end
    end

    it(
        'completes the worktree paths, the directories and the scopes',
        function()
            local project = git.project()
            local feature = project:worktree('feature')
            vim.fn.mkdir(project.path .. '/sub', 'p')
            enter(project.path)

            local matches = command.complete_review('', 'ProhubReview ', 13)

            assert.is_not_nil(position_of(matches, project.path))
            assert.is_not_nil(position_of(matches, feature.path))
            assert.is_not_nil(position_of(matches, 'sub/'))
            assert.is_not_nil(position_of(matches, 'branch'))
            assert.is_not_nil(position_of(matches, 'unpushed'))
            assert.is_not_nil(position_of(matches, 'uncommitted'))

            local seen = {}
            for _, match in ipairs(matches) do
                assert.is_nil(
                    seen[match],
                    ('%s is completed twice'):format(match)
                )
                seen[match] = true
            end
        end
    )

    it('completes only the scopes for the second argument', function()
        enter(temporary_dir())

        local matches = command.complete_review('', 'ProhubReview foo ', 17)

        assert.are.same({ 'branch', 'uncommitted', 'unpushed' }, matches)
    end)

    it('keeps only the candidates that start with the lead', function()
        local project = git.project()
        vim.fn.mkdir(project.path .. '/sub', 'p')
        vim.fn.mkdir(project.path .. '/subway', 'p')
        enter(project.path)

        local first = command.complete_review('sub', 'ProhubReview sub', 15)
        local second = command.complete_review('unp', 'ProhubReview unp', 15)

        assert.are.same({ 'sub/', 'subway/' }, first)
        assert.are.same({ 'unpushed' }, second)
    end)

    it('completes the directories outside a git project', function()
        local dir = temporary_dir()
        vim.fn.mkdir(dir .. '/one', 'p')
        vim.fn.mkdir(dir .. '/two', 'p')
        enter(dir)

        local matches = command.complete_review('', 'ProhubReview ', 13)

        assert.are.same(
            { 'one/', 'two/', 'branch', 'uncommitted', 'unpushed' },
            matches
        )
        assert.are.same(
            { 'branch', 'uncommitted', 'unpushed' },
            command.complete_review('', 'ProhubReview foo ', 17)
        )
    end)

    it('completes nothing after the second argument', function()
        enter(temporary_dir())

        local matches =
            command.complete_review('', 'ProhubReview foo branch ', 24)

        assert.are.same({}, matches)
    end)

    it('never throws and never notifies while completing', function()
        local messages = collect_notifications()
        local calls = {
            { '', 'ProhubReview ', 13 },
            { '', 'ProhubReview', 12 },
            { '', '', 0 },
            { 'x', 'ProhubReview x', 13 },
            { nil, nil, nil },
        }

        for _, call in ipairs(calls) do
            local called, matches =
                pcall(command.complete_review, call[1], call[2], call[3])
            assert.is_true(called)
            assert.is_true(vim.islist(matches))
        end
        assert.equals(0, #messages)
    end)
end)
