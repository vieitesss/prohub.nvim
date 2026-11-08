---Builds temporary git repositories for the specs. Nothing here touches a real
---repository: every project lives in its own temporary directory, which
---`cleanup` removes.
---
---Every project is a copy of a template git makes once per editor, and so is
---the added worktree and the remote: starting a process costs more than copying
---files, which is what makes the suite fast.
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

---Create a temporary directory. The path is resolved, because git prints
---resolved paths and the temporary directory may be a symlink.
---@return string
local function make_container()
    local container = vim.fn.tempname()
    vim.fn.mkdir(container, 'p')
    return assert(vim.uv.fs_realpath(container))
end

-- The variables that fix the behaviour of git for the fixtures: the git
-- configuration of the user cannot leak in, and every commit has the same
-- author. Git starts a background `git maintenance run --auto` after a commit
-- and a background `git gc --auto` after a push, and those write and remove
-- lock files while a copy of a template is being made, so the fixtures run
-- neither. The template git copies into a new repository is empty, so a
-- repository holds only the files git needs and a copy of one is as small as
-- possible. `vim.system` merges the variables over the environment of the
-- editor.
---@type table<string, string>
local fixed_environment = {
    GIT_CONFIG_GLOBAL = '/dev/null',
    GIT_CONFIG_SYSTEM = '/dev/null',
    GIT_TEMPLATE_DIR = make_container(),
    GIT_CONFIG_COUNT = '2',
    GIT_CONFIG_KEY_0 = 'gc.auto',
    GIT_CONFIG_VALUE_0 = '0',
    GIT_CONFIG_KEY_1 = 'maintenance.auto',
    GIT_CONFIG_VALUE_1 = 'false',
    GIT_AUTHOR_NAME = 'prohub',
    GIT_AUTHOR_EMAIL = 'prohub@example.com',
    GIT_COMMITTER_NAME = 'prohub',
    GIT_COMMITTER_EMAIL = 'prohub@example.com',
}

---The variables of the editor that make git read or write a repository other
---than the one it is given, such as GIT_DIR when the specs run from a git hook.
---The environment is read with `vim.fn.environ()`, because `pairs` on `vim.env`
---yields nothing on Neovim 0.10.0.
---@return string[]
local function inherited_git_environment()
    local names = {}
    for name in pairs(vim.fn.environ()) do
        if name:upper():match('^GIT_') then
            table.insert(names, name)
        end
    end
    table.sort(names)

    return names
end

---Run git in `dir` and return its output without the trailing newline. Raises
---when git fails.
---
---The fixed environment is merged over the environment of the editor, which
---`vim.system` does alone. A variable the editor carries and the fixtures must
---not see, such as the GIT_DIR of a git hook, needs `env` in front: the
---environment of a child can only be added to, never removed from, and
---`clear_env` replaces the environment with nothing on Neovim 0.10.0. A wrapper
---costs a second process, so it only runs for the variables that are there.
---@param dir string
---@param args string[]
---@return string
local function run(dir, args)
    local git = vim.list_extend({ 'git', '-C', dir }, args)

    local unset = {}
    for _, name in ipairs(inherited_git_environment()) do
        table.insert(unset, '-u')
        table.insert(unset, name)
    end

    local cmd = git
    if #unset > 0 then
        cmd = vim.list_extend({ 'env' }, unset)
        vim.list_extend(cmd, git)
    end
    local opts = { text = true, env = fixed_environment }

    local result = vim.system(cmd, opts):wait()
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

---Create the temporary directory of a project, and remove it on `cleanup`.
---@return string
local function new_container()
    local container = make_container()
    table.insert(containers, container)
    return container
end

---@param path string
---@param container string
---@return helpers.git.Tree
local function new_tree(path, container)
    return setmetatable({ path = path, container = container }, Tree)
end

---Write a file, creating its directories.
---@param path string
---@param content string
local function write_file(path, content)
    vim.fn.mkdir(vim.fs.dirname(path), 'p')
    vim.fn.writefile(vim.split(content, '\n'), path)
end

---Read the first line of a file, or nil when the file is not there.
---@param path string
---@return string?
local function read_line(path)
    local file = io.open(path, 'r')
    if not file then
        return nil
    end

    local line = file:read('*l')
    file:close()

    return line
end

---Copy a directory and everything under it. A copy of a project is a project:
---a repository that has no remote holds no absolute path, and the copies of the
---worktree and of the remote are placed where git expects them.
---@param from string
---@param to string
local function copy(from, to)
    vim.fn.mkdir(to, 'p')
    for name, kind in vim.fs.dir(from, { depth = math.huge }) do
        local source = from .. '/' .. name
        local target = to .. '/' .. name
        if kind == 'directory' then
            vim.fn.mkdir(target, 'p')
        elseif kind == 'file' then
            vim.fn.mkdir(vim.fs.dirname(target), 'p')
            local copied, err = vim.uv.fs_copyfile(source, target)
            if not copied then
                error(('could not copy %s: %s'):format(source, err), 3)
            end
        else
            error(('cannot copy %s, it is a %s'):format(source, kind), 3)
        end
    end
end

---The directory that holds the data a tree shares with its worktrees: the
---`.git` directory of a repository, or the bare repository itself. A linked
---worktree keeps none here, so it has none.
---@param tree helpers.git.Tree
---@return string?
local function common_dir(tree)
    local git = tree.path .. '/.git'
    local stat = vim.uv.fs_stat(git)
    if stat then
        return stat.type == 'directory' and git or nil
    end

    if vim.uv.fs_stat(tree.path .. '/HEAD') then
        return tree.path
    end

    return nil
end

---Read the commit a ref points at, from the loose ref or from `packed-refs`.
---@param dir string
---@param ref string
---@return string?
local function read_ref(dir, ref)
    local loose = read_line(dir .. '/' .. ref)
    if loose then
        local sha = loose:match('^(%x+)$')
        if sha then
            return sha
        end
    end

    local packed = io.open(dir .. '/packed-refs', 'r')
    if not packed then
        return nil
    end

    local found
    for line in packed:lines() do
        local sha, name = line:match('^(%x+) (.+)$')
        if name == ref then
            found = sha
            break
        end
    end
    packed:close()

    return found
end

---Read the commit HEAD points at, without starting a process. Returns nil for
---anything the fixtures do not write, such as a HEAD that is not a ref, and the
---caller then asks git.
---@param dir string
---@return string?
local function head_commit(dir)
    local head = read_line(dir .. '/HEAD')
    local ref = head and head:match('^ref: (.+)$')
    if not ref then
        return head and head:match('^(%x+)$') or nil
    end

    return read_ref(dir, ref)
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
    write_file(self.path .. '/' .. file, content)
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
function Tree:commit(file, content, message)
    self:stage(file, content)
    self:git('commit', '--quiet', '-m', message or ('change ' .. file))
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

-- The repository the projects are copied from, built once per editor. Copying
-- its files starts no process, and it lives in the directory Neovim removes at
-- exit, so it needs no cleanup.
---@type helpers.git.Tree?
local project_template

-- The bare repository the bare layouts are copied from, built the same way.
---@type helpers.git.Tree?
local bare_template

-- A linked worktree git made once, in a copy of the template. It holds the two
-- directories a worktree of a copy of the template is made of, and the commit
-- they are checked out at.
---@type { path: string, metadata: string, commit: string }?
local worktree_template

---The repository every project is copied from.
---@return helpers.git.Tree
local function template_project()
    if not project_template then
        project_template = init_project(make_container(), 'project')
    end
    return project_template
end

---The bare repository every bare layout is copied from.
---@return helpers.git.Tree
local function template_bare()
    if not bare_template then
        local container = make_container()
        local path = container .. '/project.git'
        run(container, {
            'clone',
            '--quiet',
            '--bare',
            template_project().path,
            path,
        })
        bare_template = new_tree(path, container)
    end
    return bare_template
end

---The linked worktree every worktree is copied from.
---@return { path: string, metadata: string, commit: string }
local function template_worktree()
    if not worktree_template then
        local container = make_container()
        local path = container .. '/project'
        copy(template_project().path, path)

        local name = 'template'
        local project = new_tree(path, container)
        project:git(
            'worktree',
            'add',
            '--quiet',
            '-b',
            name,
            container .. '/' .. name
        )

        worktree_template = {
            path = container .. '/' .. name,
            metadata = path .. '/.git/worktrees/' .. name,
            commit = project:git('rev-parse', 'HEAD'),
        }
    end
    return worktree_template
end

---Make the linked worktree of a copy of the template by copying files. Returns
---nil when this tree is not a copy at the commit of the template, when the
---branch is at another commit, or when the HEAD of the tree is a ref the
---fixtures do not read, and the caller then asks git.
---@param tree helpers.git.Tree
---@param branch string
---@return helpers.git.Tree?
local function copy_worktree(tree, branch)
    local dir = common_dir(tree)
    if not dir then
        return nil
    end

    local template = template_worktree()
    if head_commit(dir) ~= template.commit then
        return nil
    end

    local ref = 'refs/heads/' .. branch
    local existing = read_ref(dir, ref)
    if existing and existing ~= template.commit then
        return nil
    end

    local name = branch:gsub('[^%w._-]', '-')
    local path = tree.container .. '/' .. name
    local metadata = dir .. '/worktrees/' .. name
    copy(template.path, path)
    copy(template.metadata, metadata)
    write_file(path .. '/.git', 'gitdir: ' .. metadata)
    write_file(metadata .. '/gitdir', path .. '/.git')
    write_file(metadata .. '/HEAD', 'ref: ' .. ref)
    if not existing then
        write_file(dir .. '/' .. ref, template.commit)
    end

    return new_tree(path, tree.container)
end

---Add a linked worktree on `branch`, created from the current HEAD. The
---branch is made when it does not exist yet.
---@param branch string
---@return helpers.git.Tree
function Tree:worktree(branch)
    local tree = copy_worktree(self, branch)
    if tree then
        return tree
    end

    local path = self.container .. '/' .. branch:gsub('[^%w._-]', '-')
    local dir = common_dir(self)
    if dir and read_ref(dir, 'refs/heads/' .. branch) then
        self:git('worktree', 'add', '--quiet', path, branch)
    else
        self:git('worktree', 'add', '--quiet', '-b', branch, path)
    end

    return new_tree(path, self.container)
end

---Create a bare remote for the project, once, and return its path. The
---remote starts as a copy of the template, so the project starts published and
---pushing the initial commit moves no object. `name` is what the remote is
---called, `origin` when it is missing, and every remote of a project lives in
---the container of the project.
---@param name? string
---@return string
function Tree:remote(name)
    name = name or 'origin'
    local path = self.container .. '/' .. name .. '.git'
    if not vim.uv.fs_stat(path) then
        copy(template_bare().path, path)
        self:git('remote', 'add', name, path)
    end

    return path
end

---Create a repository with one commit on `main`, as a copy of the template.
---@return helpers.git.Tree
function M.project()
    local container = new_container()
    local path = container .. '/project'
    copy(template_project().path, path)
    return new_tree(path, container)
end

---Create a bare repository, with the linked worktree `main` next to it as in
---a bare layout. Add more worktrees with `bare:worktree(branch)`.
---@return helpers.git.Tree bare
---@return helpers.git.Tree main
function M.bare()
    local container = new_container()
    local path = container .. '/project.git'
    copy(template_bare().path, path)

    local bare = new_tree(path, container)

    return bare, bare:worktree('main')
end

---Remove every project the helper created. Call it from `after_each`.
function M.cleanup()
    for _, container in ipairs(containers) do
        vim.fn.delete(container, 'rf')
    end
    containers = {}
end

return M
