---Builds temporary git repositories for the specs. Nothing here touches a real
---repository: every project lives in its own temporary directory, which
---`cleanup` removes.
---
---    local git = require('helpers.git')
---    after_each(git.cleanup)
---
---    local project = git.project()
---    local feature = project:worktree('feature')
---    feature:commit('a.txt', 'a', 'add a')
---    project:modify('README.md', 'changed')
---@class helpers.git
local M = {}

---@class helpers.git.Tree
---@field path string Real path of the repository or linked worktree.
---@field container string Temporary directory that holds the whole project.
local Tree = {}
Tree.__index = Tree

---@type string[]
local containers = {}

-- The whole environment git runs in, applied with `env -i`. Nothing else is
-- inherited, so a variable such as GIT_DIR, set when the specs run from a git
-- hook, cannot point git at another project, and the user's git configuration
-- cannot leak in. `vim.system` with `clear_env` is not used: Neovim 0.10.0
-- ignores the environment it is given in that mode.
local env = {
    'PATH=' .. vim.env.PATH,
    'GIT_CONFIG_GLOBAL=/dev/null',
    'GIT_CONFIG_SYSTEM=/dev/null',
    'GIT_AUTHOR_NAME=prohub',
    'GIT_AUTHOR_EMAIL=prohub@example.com',
    'GIT_COMMITTER_NAME=prohub',
    'GIT_COMMITTER_EMAIL=prohub@example.com',
}

---Run git in `dir` and return its output without the trailing newline. Raises
---when git fails.
---@param dir string
---@param args string[]
---@return string
local function run(dir, args)
    local git = vim.list_extend({ 'git', '-C', dir }, args)
    local cmd = vim.list_extend(vim.list_extend({ 'env', '-i' }, env), git)
    local result = vim.system(cmd, { text = true }):wait()
    if result.code ~= 0 then
        error(
            ('%s failed: %s'):format(
                table.concat(git, ' '),
                result.stderr or ''
            ),
            3
        )
    end

    return ((result.stdout or ''):gsub('%s+$', ''))
end

---Create the temporary directory of a project. The path is resolved, because
---git prints resolved paths and the temporary directory may be a symlink.
---@return string
local function new_container()
    local container = vim.fn.tempname()
    vim.fn.mkdir(container, 'p')
    container = assert(vim.uv.fs_realpath(container))
    table.insert(containers, container)
    return container
end

---@param path string
---@param container string
---@return helpers.git.Tree
local function new_tree(path, container)
    return setmetatable({ path = path, container = container }, Tree)
end

---Run git in this repository or worktree.
---@param ... string
---@return string output
function Tree:git(...)
    return run(self.path, { ... })
end

---Write a file, creating its directories.
---@param file string Path relative to the worktree.
---@param content string
function Tree:write(file, content)
    local path = self.path .. '/' .. file
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile(vim.split(content, '\n'), path)
end

---Leave a new file that git does not know yet.
---@param file string
---@param content? string
function Tree:create(file, content)
    self:write(file, content or file)
end

---Leave a staged change to a file.
---@param file string
---@param content? string
function Tree:stage(file, content)
    self:write(file, content or file)
    self:git('add', '--', file)
end

---Leave an unstaged change to a file that is already committed.
---@param file string
---@param content string
function Tree:modify(file, content)
    self:git('ls-files', '--error-unmatch', '--', file)
    self:write(file, content)
end

---Commit a file.
---@param file string
---@param content string
---@param message? string
---@return string sha
function Tree:commit(file, content, message)
    self:stage(file, content)
    self:git('commit', '--quiet', '-m', message or ('change ' .. file))
    return self:git('rev-parse', 'HEAD')
end

---Add a linked worktree on a new branch, created from the current HEAD.
---@param branch string
---@return helpers.git.Tree
function Tree:worktree(branch)
    local path = self.container .. '/' .. branch:gsub('[^%w._-]', '-')
    self:git('worktree', 'add', '--quiet', '-b', branch, path)
    return new_tree(path, self.container)
end

---Create a bare `origin` for the project, once, and return its path.
---@return string
function Tree:remote()
    local path = self.container .. '/origin.git'
    if not vim.uv.fs_stat(path) then
        run(self.container, { 'init', '--quiet', '--bare', '-b', 'main', path })
        self:git('remote', 'add', 'origin', path)
    end

    return path
end

---Push the current branch to `origin` and make it the upstream. Creates the
---remote on first use.
function Tree:push()
    self:remote()
    self:git('push', '--quiet', '--set-upstream', 'origin', 'HEAD')
end

---Detach HEAD at its current commit.
function Tree:detach()
    self:git('checkout', '--quiet', '--detach')
end

---Delete the directory of a linked worktree, leaving it prunable.
function Tree:delete_dir()
    vim.fn.delete(self.path, 'rf')
end

---Create a repository with one commit on `main`, in `container/name`.
---@param container string
---@param name string
---@return helpers.git.Tree
local function init_project(container, name)
    local path = container .. '/' .. name
    vim.fn.mkdir(path, 'p')
    run(path, { 'init', '--quiet', '-b', 'main' })

    local project = new_tree(path, container)
    project:commit('README.md', 'prohub', 'initial commit')

    return project
end

---Create a repository with one commit on `main`.
---@return helpers.git.Tree
function M.project()
    return init_project(new_container(), 'project')
end

---Create a bare repository, with the linked worktree `main` next to it as in
---a bare layout. Add more worktrees with `bare:worktree(branch)`.
---@return helpers.git.Tree bare
---@return helpers.git.Tree main
function M.bare()
    local container = new_container()
    local seed = init_project(container, 'seed')
    local path = container .. '/project.git'

    run(container, { 'clone', '--quiet', '--bare', seed.path, path })
    vim.fn.delete(seed.path, 'rf')

    local bare = new_tree(path, container)
    local main = container .. '/main'
    bare:git('worktree', 'add', '--quiet', main, 'main')

    return bare, new_tree(main, container)
end

---Remove every project the helper created. Call it from `after_each`.
function M.cleanup()
    for _, container in ipairs(containers) do
        vim.fn.delete(container, 'rf')
    end
    containers = {}
end

return M
