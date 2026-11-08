local git = require('helpers.git')

describe('prohub hub keymaps', function()
    local config, hub
    local notified, messages, selected
    local origin_cwd = vim.fn.getcwd()

    ---Reload the modules under test. The hub remembers the tabpage and the
    ---buffer of every hub it opened, the review module remembers the reviews
    ---that are open and the status module caches what it collected, so the
    ---whole plugin is loaded again and starts from defaults.
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

    ---Close every tabpage but one, so a case never sees the hub of another one.
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

    ---Press a key of the hub by calling the callback of its mapping, which is
    ---what Neovim runs when the key is typed and which works headless.
    ---@param buffer integer
    ---@param lhs string
    local function press(buffer, lhs)
        local map = mapping(buffer, lhs)
        assert.is_not_nil(map, ('the hub maps no %s'):format(lhs))
        map.callback()
    end

    ---Put the cursor on the row of a worktree.
    ---@param buffer integer
    ---@param name string
    local function put_cursor(buffer, name)
        local line = row_of(lines_of(buffer), name)
        assert.is_not_nil(line, ('no row of %s'):format(name))
        vim.api.nvim_win_set_cursor(0, { line, 0 })
    end

    ---A diff viewer that records its context and shows a scratch buffer in the
    ---tabpage of the review.
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

    ---Answer the question of a scope with `choice`, and record it.
    ---@param choice string? What the user picks, missing when they cancel.
    ---@return table asked The items, the options and the callback.
    local function answer_select(choice)
        local asked = {}
        vim.ui.select = function(items, opts, on_choice)
            asked.items = items
            asked.opts = opts
            asked.on_choice = on_choice
            on_choice(choice)
        end
        return asked
    end

    before_each(function()
        reload()
        notified = vim.notify
        selected = vim.ui.select
        messages = {}
        vim.notify = function(message, level)
            table.insert(messages, { message = message, level = level })
        end
    end)

    after_each(function()
        vim.notify = notified
        vim.ui.select = selected
        close_tabs()
        wipe_hub_buffers()
        pcall(vim.cmd, 'cd ' .. vim.fn.fnameescape(origin_cwd))
        git.cleanup()
        vim.g.prohub = nil
    end)

    it('opens a review of the row under the cursor', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        local buffer = open(project)
        local hub_tabpage = current()
        put_cursor(buffer, 'feature')

        press(buffer, '<CR>')

        assert.equals(3, tabs())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].ctx.path)
        assert.equals('branch', calls[1].ctx.scope)
        assert.is_string(calls[1].ctx.base)
        assert.is_false(calls[1].tabpage == hub_tabpage)
        assert.equals(calls[1].tabpage, current())
        assert.equals(0, #messages)
    end)

    it('only says so on a missing row and on the header row', function()
        local project = git.project()
        local gone = project:worktree('gone')
        gone:delete_dir()
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))

        local buffer = open(project)
        local before = tabs()

        put_cursor(buffer, 'gone')
        press(buffer, '<CR>')

        assert.equals(before, tabs())
        assert.equals(0, #calls)
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.WARN, messages[1].level)
        assert.is_truthy(messages[1].message:find('missing', 1, true))

        vim.api.nvim_win_set_cursor(0, { 1, 0 })
        press(buffer, '<CR>')

        assert.equals(before, tabs())
        assert.equals(0, #calls)
        assert.equals(2, #messages)
        assert.equals(vim.log.levels.WARN, messages[2].level)
    end)

    it('asks for a scope and opens the review of the choice', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local asked = answer_select('unpushed')

        local buffer = open(project)
        local hub_tabpage = current()
        put_cursor(buffer, 'feature')

        press(buffer, 's')

        assert.same({ 'branch', 'unpushed', 'uncommitted' }, asked.items)
        assert.equals('session changes', asked.opts.format_item('branch'))
        assert.equals('unpushed changes', asked.opts.format_item('unpushed'))
        assert.equals(
            'uncommitted changes',
            asked.opts.format_item('uncommitted')
        )
        assert.equals(3, tabs())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].ctx.path)
        assert.equals('unpushed', calls[1].ctx.scope)
        assert.is_string(calls[1].ctx.base)
        assert.is_false(calls[1].tabpage == hub_tabpage)
        assert.equals(0, #messages)
    end)

    it('opens nothing when the scope is cancelled', function()
        local project = git.project()
        project:worktree('feature')
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        answer_select(nil)

        local buffer = open(project)
        local before = tabs()
        put_cursor(buffer, 'feature')

        press(buffer, 's')

        assert.equals(before, tabs())
        assert.equals(0, #calls)
        assert.equals(0, #messages)
    end)

    it('renders the hub again with a change made after it opened', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local buffer = open(project)
        put_cursor(buffer, 'feature')

        local line, text = row_of(lines_of(buffer), 'feature')
        assert.is_truthy(text:match('%s0 0 0%s'))

        feature:create('untracked.txt', 'untracked')
        press(buffer, 'r')

        wait_for(function()
            local now = select(2, row_of(lines_of(buffer), 'feature'))
            return now ~= nil and now:match('%s0 0 1%s') ~= nil
        end, 'the hub did not show the new untracked file')

        assert.equals(line, vim.api.nvim_win_get_cursor(0)[1])
        assert.equals('feature', lines_of(buffer)[line]:match('^(%S+)'))
        assert.equals(0, #messages)
    end)

    it('closes the tabpage of the hub', function()
        local project = git.project()
        local buffer = open(project)
        local hub_tabpage = current()
        local origin = vim.api.nvim_list_tabpages()[1]
        assert.equals(2, tabs())

        press(buffer, 'q')

        assert.equals(1, tabs())
        assert.is_false(vim.api.nvim_tabpage_is_valid(hub_tabpage))
        assert.equals(origin, current())
        assert.equals(0, #messages)
    end)

    it('hides the hub buffer when its tabpage is the last one', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({ diff_viewer = viewer }))
        local buffer = open(project)

        -- The hub alone in one tabpage, as in an editor opened on the hub.
        vim.api.nvim_set_current_tabpage(vim.api.nvim_list_tabpages()[1])
        vim.cmd('tabclose')
        assert.equals(1, tabs())

        press(buffer, 'q')

        assert.equals(1, tabs())
        assert.is_true(vim.api.nvim_buf_is_valid(buffer))
        assert.equals(-1, vim.fn.bufwinid(buffer))
        assert.is_false(vim.api.nvim_get_current_buf() == buffer)
        assert.equals('hide', vim.bo[buffer].bufhidden)

        -- The hub is forgotten, so opening it again makes it new, and its keys
        -- are mapped onto the buffer it finds back.
        assert.equals(0, #messages)
        assert.is_true(hub.open({ cwd = project.path }))
        wait_for(function()
            return vim.api.nvim_get_current_buf() == buffer
                and #lines_of(buffer) > 1
                and vim.api.nvim_buf_get_name(buffer)
                    == 'prohub://' .. project.path
        end, 'the hub was not opened again')
        assert.equals(2, tabs())
        assert.equals('main', lines_of(buffer)[2]:match('^(%S+)'))

        put_cursor(buffer, 'feature')
        press(buffer, '<CR>')

        assert.equals(3, tabs())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].ctx.path)
    end)

    it('lists the keys that are active and leaves the others out', function()
        local project = git.project()
        project:worktree('feature')
        assert.is_true(config.setup({ keymaps = { close = false } }))
        local buffer = open(project)

        press(buffer, '?')

        assert.equals(1, #messages)
        assert.equals(vim.log.levels.INFO, messages[1].level)

        local keys = {}
        local listed = vim.split(messages[1].message, '\n', { plain = true })
        for _, line in ipairs(listed) do
            local lhs, description = line:match('^(%S+)%s+(.+)$')
            assert.is_not_nil(lhs, ('no key starts the line %q'):format(line))
            assert.is_not_nil(description)
            table.insert(keys, lhs)
        end

        assert.same({ '<CR>', 's', 'r', '?' }, keys)
        assert.is_truthy(listed[1]:find('review', 1, true))
        assert.is_truthy(listed[2]:find('scope', 1, true))
    end)

    it('leaves a disabled key unmapped and maps a remapped one', function()
        local project = git.project()
        local feature = project:worktree('feature')
        local viewer, calls = recording_viewer()
        assert.is_true(config.setup({
            diff_viewer = viewer,
            keymaps = { review = 'o', close = false },
        }))

        local buffer = open(project)

        assert.is_nil(mapping(buffer, '<CR>'))
        assert.is_nil(mapping(buffer, 'q'))
        assert.is_not_nil(mapping(buffer, 'o'))
        assert.is_not_nil(mapping(buffer, 's'))
        assert.is_not_nil(mapping(buffer, 'r'))
        assert.is_not_nil(mapping(buffer, '?'))

        put_cursor(buffer, 'feature')
        press(buffer, 'o')

        assert.equals(3, tabs())
        assert.equals(1, #calls)
        assert.equals(feature.path, calls[1].ctx.path)
        assert.equals(0, #messages)
    end)

    it(
        'replaces the keys of a reopened hub with the ones configured now',
        function()
            local project = git.project()
            assert.is_true(config.setup({ keymaps = { close = 'q' } }))
            local buffer = open(project)
            press(buffer, 'q')
            assert.equals(1, tabs())

            assert.is_true(
                config.setup({ keymaps = { close = 'x', help = false } })
            )
            local reopened = open(project)
            -- The buffer keeps the rows of the first open, so the keys of the
            -- reopened hub are mapped once its own render lands.
            wait_for(function()
                return mapping(reopened, 'x') ~= nil
            end, 'the reopened hub did not map its keys')

            assert.equals(buffer, reopened)
            assert.is_nil(mapping(reopened, 'q'))
            assert.is_nil(mapping(reopened, '?'))
            assert.is_not_nil(mapping(reopened, 'x'))
            assert.is_not_nil(mapping(reopened, '<CR>'))
        end
    )

    it('notifies a review that fails and leaves no tab behind', function()
        local project = git.project()
        project:worktree('feature')
        assert.is_true(config.setup({
            diff_viewer = function()
                return nil, 'the diff viewer failed'
            end,
        }))

        local buffer = open(project)
        local before = tabs()
        put_cursor(buffer, 'feature')

        press(buffer, '<CR>')

        assert.equals(before, tabs())
        assert.equals(1, #messages)
        assert.equals(vim.log.levels.ERROR, messages[1].level)
        assert.equals('the diff viewer failed', messages[1].message)
    end)
end)
