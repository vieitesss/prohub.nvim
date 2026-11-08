---The health check of prohub, the function `:checkhealth prohub` calls. The
---specs capture the report instead of drawing it, and they fake the editor
---version and the `git` executable so each case runs the same way on every
---Neovim and git the suite meets.
describe('prohub.health', function()
    local health, reported
    local original_health, original_version, original_path
    local fake_git_dir

    ---Capture what the report says.
    local function capture()
        reported = {}
        vim.health = {
            start = function(name)
                table.insert(reported, { kind = 'start', message = name })
            end,
            info = function(message)
                table.insert(reported, { kind = 'info', message = message })
            end,
            ok = function(message)
                table.insert(reported, { kind = 'ok', message = message })
            end,
            warn = function(message, advice)
                table.insert(reported, {
                    kind = 'warn',
                    message = message,
                    advice = advice,
                })
            end,
            error = function(message, advice)
                table.insert(reported, {
                    kind = 'error',
                    message = message,
                    advice = advice,
                })
            end,
        }
    end

    ---The items of one kind that the report holds.
    ---@param kind string
    ---@return table[]
    local function items(kind)
        local found = {}
        for _, item in ipairs(reported) do
            if item.kind == kind then
                table.insert(found, item)
            end
        end
        return found
    end

    ---Make the editor report a version, so a case covers a version floor on
    ---every Neovim the suite runs on. `vim.version` is callable and carries
    ---its comparisons as fields, so the stand-in is a table that answers both.
    ---@param version string
    local function pretend(version)
        local real = original_version
        vim.version = setmetatable({}, {
            __call = function()
                return real.parse(version)
            end,
            __index = real,
        })
    end

    ---Replace `git` on `PATH` with a script that prints a version line, the
    ---way a git of another version would answer `git --version`.
    ---@param text string The line the script prints.
    local function fake_git(text)
        fake_git_dir = vim.fn.tempname()
        vim.fn.mkdir(fake_git_dir, 'p')

        local script = fake_git_dir .. '/git'
        vim.fn.writefile({
            '#!/bin/sh',
            ('printf "%%s\\n" %q'):format(text),
        }, script)
        vim.fn.setfperm(script, 'rwxr-xr-x')

        vim.env.PATH = fake_git_dir .. ':' .. original_path
    end

    ---Leave no `git` on `PATH`, as a machine without git.
    local function remove_git()
        fake_git_dir = vim.fn.tempname()
        vim.fn.mkdir(fake_git_dir, 'p')
        vim.env.PATH = fake_git_dir
    end

    ---A viewer that is configured but is not a built-in one.
    ---@return fun(): true
    local function custom_viewer()
        return function()
            return true
        end
    end

    before_each(function()
        original_health = vim.health
        original_version = vim.version
        original_path = vim.env.PATH
        fake_git_dir = nil

        vim.g.prohub = nil
        package.loaded['minifugit'] = nil
        package.loaded['prohub.config'] = nil
        package.loaded['prohub.viewer'] = nil
        package.loaded['prohub.health'] = nil
        health = require('prohub.health')
        capture()
    end)

    after_each(function()
        package.loaded['minifugit'] = nil
        package.preload['prohub.viewers.minifugit'] = nil
        package.loaded['prohub.viewers.minifugit'] = nil
        vim.health = original_health
        vim.version = original_version
        vim.env.PATH = original_path
        vim.g.prohub = nil
        if fake_git_dir then
            vim.fn.delete(fake_git_dir, 'rf')
        end
    end)

    it('starts the report and reports every item as OK', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        package.loaded['minifugit'] = {
            open = function()
                return true
            end,
        }

        local buffers = #vim.api.nvim_list_bufs()
        local windows = #vim.api.nvim_list_wins()

        health.check()

        assert.equals(0, #items('warn'))
        assert.equals(0, #items('error'))
        assert.equals(1, #items('start'))
        assert.equals('prohub', items('start')[1].message)

        local reported_ok = items('ok')
        assert.equals(4, #reported_ok)
        assert.is_truthy(reported_ok[1].message:find('0.13.0', 1, true))
        assert.is_truthy(reported_ok[2].message:find('2.45.0', 1, true))
        assert.are.equal('the options are valid', reported_ok[3].message)
        assert.are.equal('diff viewer: minifugit', reported_ok[4].message)

        assert.equals(buffers, #vim.api.nvim_list_bufs())
        assert.equals(windows, #vim.api.nvim_list_wins())
    end)

    it('reports an ERROR when Neovim is below 0.10', function()
        pretend('0.9.5')
        fake_git('git version 2.45.0')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(errors[1].message:find('0.9.5', 1, true))
        assert.is_truthy(errors[1].message:find('0.10', 1, true))
        assert.are.equal('Upgrade Neovim to 0.10 or newer.', errors[1].advice)
    end)

    it('accepts a development build of a supported Neovim', function()
        pretend('0.10.0-dev+g27fb62988')
        fake_git('git version 2.45.0')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        assert.equals(0, #items('error'))
        assert.is_truthy(items('ok')[1].message:find('0.10.0-dev', 1, true))
    end)

    it('reports an ERROR when git cannot be run', function()
        pretend('0.13.0')
        remove_git()
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(errors[1].message:find('could not run git', 1, true))
        assert.are.equal('Install git and put it on PATH.', errors[1].advice)
    end)

    it('reports an ERROR when git is below 2.36', function()
        pretend('0.13.0')
        fake_git('git version 2.35.9')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(errors[1].message:find('2.35.9', 1, true))
        assert.is_truthy(errors[1].message:find('2.36.0', 1, true))
        assert.is_truthy(errors[1].advice:find('Upgrade git', 1, true))
    end)

    it('reports git 2.36.0 as OK', function()
        pretend('0.13.0')
        fake_git('git version 2.36.0')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local reported_ok = items('ok')
        assert.equals(0, #items('error'))
        assert.is_truthy(reported_ok[2].message:find('2.36.0', 1, true))
    end)

    it('reads the version of an Apple git', function()
        pretend('0.13.0')
        fake_git('git version 2.39.5 (Apple Git-154)')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local reported_ok = items('ok')
        assert.equals(0, #items('error'))
        assert.is_truthy(reported_ok[2].message:find('2.39.5', 1, true))
    end)

    it('reads the version of a Windows git', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0.windows.1')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local reported_ok = items('ok')
        assert.equals(0, #items('error'))
        assert.is_truthy(reported_ok[2].message:find('2.45.0', 1, true))
    end)

    it('reports a WARNING when the git version cannot be read', function()
        pretend('0.13.0')
        fake_git('git version from the future')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local warnings = items('warn')
        assert.equals(1, #warnings)
        assert.equals(0, #items('error'))
        assert.is_truthy(
            warnings[1].message:find('git version from the future', 1, true)
        )
        assert.is_truthy(warnings[1].advice:find('2.36.0', 1, true))
    end)

    it('reports an ERROR for invalid options', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        vim.g.prohub = 'not a table'

        health.check()

        local errors = items('error')
        assert.equals(2, #errors)
        assert.is_truthy(errors[1].message:find('vim.g.prohub', 1, true))
        assert.is_truthy(errors[2].message:find('options', 1, true))
        assert.equals(2, #items('ok'))
    end)

    it('reports an ERROR for a viewer name that does not exist', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        vim.g.prohub = { diff_viewer = 'no-such-viewer' }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(
            errors[1].message:find(
                'unknown diff viewer: no-such-viewer',
                1,
                true
            )
        )
        assert.is_truthy(errors[1].message:find('minifugit', 1, true))
    end)

    it('reports an ERROR when the viewer module fails to load', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        package.loaded['prohub.viewers.minifugit'] = nil
        package.preload['prohub.viewers.minifugit'] = function()
            error('a broken adapter')
        end
        vim.g.prohub = { diff_viewer = 'minifugit' }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(
            errors[1].message:find('could not load the minifugit', 1, true)
        )
        assert.is_truthy(errors[1].message:find('a broken adapter', 1, true))
    end)

    it('reports an ERROR when minifugit is not installed', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        package.loaded['minifugit'] = nil

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(errors[1].message:find('not installed', 1, true))
        assert.is_truthy(errors[1].advice:find('minifugit', 1, true))
    end)

    it('reports an ERROR when minifugit needs a newer Neovim', function()
        pretend('0.10.0')
        fake_git('git version 2.45.0')
        package.loaded['minifugit'] = {
            open = function()
                return true
            end,
        }

        health.check()

        local errors = items('error')
        assert.equals(1, #errors)
        assert.is_truthy(errors[1].message:find('0.11', 1, true))
        assert.is_truthy(errors[1].advice:find('Upgrade Neovim', 1, true))
        assert.is_truthy(errors[1].advice:find('diff_viewer', 1, true))
    end)

    it('reports a custom viewer as OK', function()
        pretend('0.13.0')
        fake_git('git version 2.45.0')
        vim.g.prohub = { diff_viewer = custom_viewer() }

        health.check()

        local reported_ok = items('ok')
        assert.equals(0, #items('error'))
        assert.are.equal('diff viewer: a custom viewer', reported_ok[4].message)
    end)
end)
