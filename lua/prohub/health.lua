---The `:checkhealth prohub` report. It checks what prohub needs from the
---editor, from git and from the configured diff viewer, and it reports every
---item as OK, a warning or an error.
---
---The check never throws and opens no window. It runs `git --version` once,
---synchronously, which reads no repository and costs a single process.
---
---    require('prohub.health').check()
---@class prohub.health
local M = {}

local config = require('prohub.config')
local git = require('prohub.git')
local log = require('prohub.log')
local viewer = require('prohub.viewer')

---The oldest Neovim prohub supports.
---@type string
local minimum_neovim = '0.10'

---The oldest git prohub supports. The NUL terminated form of the worktree
---listing, `--porcelain -z`, arrived in git 2.36.0.
---@type string
local minimum_git = '2.36.0'

---Read the version out of what `git --version` prints. The platform may add a
---suffix of its own, such as `(Apple Git-154)`, and a Windows git adds a
---fourth field, so only the first three fields count. A missing patch field
---is zero.
---@param text string
---@return integer[]? version
local function parse_version(text)
    local major, minor, patch = text:match('^git version (%d+)%.(%d+)%.?(%d*)')
    if not major then
        return nil
    end
    return {
        tonumber(major),
        tonumber(minor),
        tonumber(patch) or 0,
    }
end

---The version as the report shows it.
---@param version integer[]
---@return string
local function version_text(version)
    return ('%d.%d.%d'):format(version[1], version[2], version[3])
end

---Whether a parsed version reaches the floor. The first field that differs
---decides, and a version that has all three fields equal reaches it.
---@param version integer[]
---@param floor string
---@return boolean
local function at_least(version, floor)
    local wanted = { floor:match('^(%d+)%.(%d+)%.(%d+)$') }
    for index = 1, 3 do
        local expected = tonumber(wanted[index])
        if version[index] ~= expected then
            return version[index] > expected
        end
    end
    return true
end

---The version of the editor without its prerelease tag. A development build
---of 0.10.0 has the API of 0.10, so the comparison reads the three numeric
---fields and a build tag cannot make a supported editor look too old.
---@param version table The version table that `vim.version` returns.
---@return { major: integer, minor: integer, patch: integer }
local function release_version(version)
    return {
        major = version.major,
        minor = version.minor,
        patch = version.patch,
    }
end

---Report the editor version against the floor of prohub.
local function check_neovim()
    local version = vim.version()
    if vim.version.ge(release_version(version), minimum_neovim) then
        vim.health.ok(('Neovim %s'):format(tostring(version)))
        return
    end

    vim.health.error(
        ('Neovim %s is too old; prohub needs %s or newer'):format(
            tostring(version),
            minimum_neovim
        ),
        ('Upgrade Neovim to %s or newer.'):format(minimum_neovim)
    )
end

---Report the git that runs the commands of prohub. The health check knows no
---worktree, so it asks git from the directory of the editor, which exists
---whenever the editor can run a command at all.
local function check_git()
    local out, err = git.run_sync(vim.fn.getcwd(), { '--version' })
    if not out then
        vim.health.error(err, 'Install git and put it on PATH.')
        return
    end

    local printed = vim.trim(out)
    local version = parse_version(printed)
    if not version then
        vim.health.warn(
            ('git printed a version prohub cannot read: %s'):format(printed),
            ('prohub needs git %s or newer.'):format(minimum_git)
        )
        return
    end

    local text = version_text(version)
    if not at_least(version, minimum_git) then
        vim.health.error(
            ('git %s is too old; prohub needs %s or newer'):format(
                text,
                minimum_git
            ),
            ('Upgrade git to %s or newer.'):format(minimum_git)
        )
        return
    end

    vim.health.ok(('git %s'):format(text))
end

---Report the options, and hand them to the check of the diff viewer, which
---cannot resolve a viewer without them.
---@return prohub.Config? options
local function check_options()
    local options, err = config.get()
    if not options then
        vim.health.error(err)
        return nil
    end

    vim.health.ok('the options are valid')
    return options
end

---Report the configured diff viewer, which is minifugit unless the options
---name another one. A built-in viewer adds its own requirements through
---`prohub.viewer.check`.
---@param options prohub.Config?
local function check_viewer(options)
    if not options then
        vim.health.error(
            'the diff viewer cannot be checked until the options are valid'
        )
        return
    end

    local ok, err, advice = viewer.check(options.diff_viewer)
    if not ok then
        vim.health.error(err, advice)
        return
    end

    local spec = options.diff_viewer
    local name = 'a custom viewer'
    if type(spec) == 'string' then
        name = spec
    end
    vim.health.ok(('diff viewer: %s'):format(name))
end

---Report every item. `check` runs it under `pcall`, so a mistake in one item
---becomes an error in the report instead of a throw from the command.
local function report()
    check_neovim()
    check_git()
    check_viewer(check_options())
end

---Report what prohub needs to work. `:checkhealth prohub` calls it, and it
---never throws, opens no window and reads no repository.
function M.check()
    vim.health.start('prohub')
    local ok, err = pcall(report)
    if not ok then
        log.error('the health check failed: %s', tostring(err))
        vim.health.error(
            ('the prohub health check failed: %s'):format(tostring(err)),
            'Report this as a bug in prohub.'
        )
    end
end

return M
