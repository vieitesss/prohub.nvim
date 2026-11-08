# prohub.nvim

A Neovim plugin that shows the worktrees of a git project in one buffer, the hub, and opens a review of the worktree you pick in an existing diff viewer. It only knows about git.

The hub has one row per worktree. This is what a hub of four worktrees looks like:

```
name     path           s u ?  a b  c  p
cart     shop           1 1 1  2 0  4  1
71d8a8b  shop-detached  0 0 0  0 0  0
hotfix   shop-hotfix    0 0 0  1 0  1
main     shop-main      0 0 0  0 0  -  0  on the default branch
```

Each row shows the branch of the worktree, or its short commit when HEAD is detached, then the last part of its path, then the counts and a note. The counts describe the worktree:

- `s`, `u` and `?` are the staged, unstaged and untracked files.
- `a` and `b` are the commits the branch has ahead of and behind the default branch.
- `c` is the number of files that differ from the base.
- `p` is the number of unpushed commits. It appears only when the worktree has a remote counterpart.

A dash means that the count does not apply. A row that has no base ends with the reason, such as `on the default branch`.

## Requirements

- Neovim 0.10 or newer.
- `git` 2.36 or newer, for `git worktree list --porcelain -z`.
- A diff viewer. The default one is [minifugit.nvim](https://github.com/vieitesss/minifugit.nvim), which needs Neovim 0.11 or newer.

Run `:checkhealth prohub` to check each requirement.

## Installation

With `vim.pack.add`, which needs Neovim 0.12 or newer:

```lua
vim.pack.add({
    'https://github.com/vieitesss/minifugit.nvim',
    'https://github.com/vieitesss/prohub.nvim',
})
```

With [lazy.nvim](https://lazy.folke.io), from `https://github.com/vieitesss/prohub.nvim`:

```lua
{
    'vieitesss/prohub.nvim',
    dependencies = { 'vieitesss/minifugit.nvim' },
    opts = {},
},
```

lazy.nvim passes `opts` to `require('prohub').setup()`. See [Configuration](#configuration).

## Quick start

1. Run `:checkhealth prohub` and fix what it reports.
2. Run `:Prohub` in a directory of a git project. The hub opens in its own tab, with one row per worktree.
3. Move to a row and press `<CR>`. prohub opens the review of that worktree in a new tab, with the default scope, which is the session changes unless `default_scope` says otherwise.
4. Close the review from the diff viewer. prohub closes the tab of the review and returns to the tab the review was opened from.

## Commands

### `:Prohub`

Opens the hub of the project, or of the workset, that holds the current directory. It takes no argument. When the hub is open already, it renders the hub again and shows it.

### `:ProhubReview [path] [scope]`

Opens the review of a worktree. The path may be any directory of the worktree: prohub asks git for the root of the worktree that holds it, and the review shows that root.

- With no argument, it reviews the current directory with the default scope.
- With one argument that is a scope name (`branch`, `unpushed` or `uncommitted`), it reviews the current directory with that scope. If a file or a directory of that name exists in the current directory, the argument is a path instead.
- With one argument that is anything else, it is the path of the worktree, and the default scope is used.
- With two arguments, the first is the path and the second is the scope.

A relative path is taken from the current directory. `~` and `%` are expanded as Vim expands them. A path must name an existing directory.

Errors are reported to the user:

- `prohub: too many arguments: at most 2, got 3`
- `prohub: unknown scope: nope (valid scopes: branch, uncommitted, unpushed)`
- `prohub: the path does not exist: <path>`
- `prohub: the path is not a directory: <path>`

The first argument completes the worktrees of the current project, then directories and scope names. The second argument completes scope names.

## Hub keys

These keys work in the hub buffer. A key set to `false` in [`keymaps`](#configuration) maps nothing.

| Key    | Action                                                                                                                                                       |
| ------ | ------------------------------------------------------------------------------------------------------------------------------------------------------------ |
| `<CR>` | Open the review of the row under the cursor, with the default scope.                                                                                         |
| `s`    | Ask which changes the review shows (session changes, unpushed changes or uncommitted changes), then open it. Cancelling the question opens nothing.          |
| `r`    | Render the hub again.                                                                                                                                        |
| `q`    | Close the hub. When the hub is the last tabpage, Neovim cannot close it, so prohub replaces the hub with an empty buffer.                                  |
| `?`    | List the keys.                                                                                                                                               |

`<CR>` and `s` on a row whose worktree git reports as missing open no review. They warn `prohub: the worktree of this row is missing: <path>`. On a line that holds no worktree, they warn `prohub: the row under the cursor holds no worktree`.

The hub uses the keymaps configured at the time it opens. Opening the hub again after it was closed replaces its keys: the keys of the earlier opening are removed, and only the configured ones work.

## Scopes

A scope decides which changes a review shows. The three scopes are `branch`, `unpushed` and `uncommitted`.

- `branch` shows the session changes: everything that differs between the base and the worktree, including files git does not track yet. The base is the merge-base of HEAD and the default branch. prohub asks git for it on every call and never stores it.
- `unpushed` shows the unpushed changes: everything that differs between the last commit that HEAD shares with its remote counterpart and the worktree, including uncommitted changes and new files. The remote counterpart is the upstream of the branch when that ref exists, on whichever remote it lives, and `origin/<branch>` otherwise. A worktree with no remote counterpart, and a worktree with a detached HEAD, have the same changes as the session changes.
- `uncommitted` shows the uncommitted changes: the staged, unstaged and untracked files, as `git status` lists them. It needs no base.

The default branch is the first of these that exists: the `default_branch` option, `origin/HEAD`, a local `main`, and a local `master`. The `origin/` ref of a name is used when it exists, and the local branch otherwise.

The `branch` scope needs a base. When it has none, prohub shows the uncommitted changes instead, and warns once with a message of this form:

```
prohub: no base for the branch scope in <path> (on the default branch), showing uncommitted changes
```

The reason in brackets is one of these:

- `no default branch`: prohub finds no default branch in the project.
- `on the default branch`: the worktree is on the default branch, so it has nothing to compare with.
- `no common history`: HEAD and the default branch share no commit.

The `unpushed` scope takes its base from the remote counterpart first. When the branch has no counterpart, or its counterpart shares no history with HEAD, it takes the base of the `branch` scope instead. When there is no base either, it falls back to the uncommitted changes with a warning. The reason in the warning names what is missing:

- A branch with no remote counterpart: `no upstream, no origin/<branch>`.
- A counterpart that shares no history with HEAD: its name, as in `origin/main shares no history with HEAD`.
- A detached HEAD: `a detached HEAD`.

Each of these is followed by `no base` and the reason the base is missing, which is one of the reasons listed for the `branch` scope above.

Any other failure of git stops the review and reports the error.

## Reviews

A review is a diff viewer drawing one scope of one worktree, in its own tab. The tab starts in the root of the worktree.

- `prohub.review()` and `:ProhubReview` take a directory, and prohub asks git for the root of the worktree that holds it. The review shows that root, and the root is what reuses it.
- Reviewing a worktree that already has a review shows that tab again.
- Asking for another scope of an open review shows that scope in the same tab.
- Asking again for the same scope after its base moved shows the new base in the same tab, because prohub computes the base on every call.
- Several reviews can be open at once, one per worktree.
- A directory that is not in a git worktree opens no review, and the error says why.
- When the review closes, prohub returns to the tab it was opened from. When that tab is gone, it returns to the hub, and when there is no hub either, it stays where it is.
- Closing the tab of a review with `:tabclose` forgets the review.

## Configuration

prohub reads its options from three places, each one overriding the one before it:

1. The defaults.
2. The `vim.g.prohub` table.
3. The table passed to `require('prohub').setup()`. Each call keeps the options of the earlier calls and overrides them.

The defaults are:

```lua
vim.g.prohub = {
    default_scope = 'branch',
    diff_viewer = 'minifugit',
    refresh_interval = 5000,
    worksets = {},
    keymaps = {
        review = '<CR>',
        scope = 's',
        refresh = 'r',
        close = 'q',
        help = '?',
    },
}
```

`default_branch` has no default. Set it when the default branch is not `origin/HEAD`, `main` or `master`.

Each option is validated when it is read. An invalid value is an error that names the option, for example `prohub: refresh_interval: expected a positive integer, got 0`. A `setup` call with an invalid value changes nothing, and the options of the earlier calls stay in use.

Options from the layers combine like this: `keymaps` merges key by key, so a layer can change one key. `worksets` is replaced as a whole by a layer that sets it. Every other option is replaced by the layer that sets it.

- `default_scope`: `'branch'`, `'unpushed'` or `'uncommitted'`. The scope of a review that is given none, such as the one of `<CR>` and of `:ProhubReview` without a scope. Default: `'branch'`.
- `default_branch`: the name of the default branch of the projects, such as `'trunk'`. It is used to find the base. A name that is not a branch of the project is written to the log, and the rest of the order is used. Default: none.
- `diff_viewer`: the viewer that draws a review. It is the name of a built-in viewer (`'minifugit'` is the only one), a function, or a table with an `open` function. See [Custom diff viewer](#custom-diff-viewer). Default: `'minifugit'`.
- `refresh_interval`: the number of milliseconds between two renders of the hub, a positive integer. The hub renders again only while its buffer is shown in a window of the current tabpage and Neovim has focus. It also renders at once when you enter the buffer or when Neovim gains focus. Default: `5000`.
- `worksets`: a table of directories and the worktrees they show. See [Worksets](#worksets). Default: `{}`.
- `keymaps`: a table with the keys `review`, `scope`, `refresh`, `close` and `help`. Each value is a key that `vim.keymap.set()` accepts, or `false` to map nothing. See [Hub keys](#hub-keys). Default: as shown above.

## Worksets

Outside a git project, the hub shows the worktrees of a workset. A workset is chosen by the directory the hub is opened from.

`worksets` maps a directory, the key, to a list of entries or to a function that returns that list. An entry is a path, a path relative to the key, or a glob such as `'shop-*'`. Each entry must name one worktree. An entry that is not a worktree is skipped without a message. A key of `'/'` matches every directory.

When the hub is opened from a directory, the key that holds that directory and is the deepest one wins. A directory that no key contains opens no hub, and prohub warns `prohub: no workset matches <dir>`.

```lua
vim.g.prohub = {
    worksets = {
        ['~/code/client'] = {
            '~/code/client/shop',
            '~/code/client/shop-*',
        },
        ['~/work'] = function()
            return { '~/work/api', '~/work/web' }
        end,
    },
}
```

A function is called when the hub is opened. When it fails, prohub reports `prohub: worksets.<key>: <message>`. When it returns anything other than a list of strings, prohub reports `prohub: worksets.<key>: expected a list of strings`. A relative key is taken from the current directory.

## Custom diff viewer

`diff_viewer` takes a function, or a table with an `open` function. Both take one argument, a context, and return `true`, or `nil` and an error message. The context has these fields:

- `path`: the absolute path of the worktree to review.
- `scope`: the scope to draw, `'branch'`, `'unpushed'` or `'uncommitted'`.
- `base`: the revision the changes are shown since. It is `nil` only for the `uncommitted` scope.
- `on_close`: a function. Call it once, when the user closes the review.

A viewer draws into the current tabpage and does not open a tab of its own. prohub has already set the directory of the tab to `path`, but the viewer should use `path` anyway. The error message that a failed viewer returns is passed on as it is. A viewer that throws an error is reported as `prohub: the diff viewer failed: <message>`.

This viewer shows `git diff` of the worktree in a scratch buffer. It closes the review with `q`:

```lua
require('prohub').setup({
    diff_viewer = {
        open = function(ctx)
            local args = { 'git', '-C', ctx.path, 'diff' }
            if ctx.base then
                table.insert(args, ctx.base)
            end

            local result = vim.system(args, { text = true }):wait()
            if result.code ~= 0 then
                return nil, vim.trim(result.stderr)
            end

            local buf = vim.api.nvim_create_buf(false, true)
            vim.api.nvim_buf_set_lines(buf, 0, -1, false, vim.split(result.stdout, '\n'))
            vim.bo[buf].filetype = 'diff'
            vim.bo[buf].modifiable = false
            vim.api.nvim_win_set_buf(0, buf)
            vim.keymap.set('n', 'q', ctx.on_close, { buffer = buf })
            return true
        end,
    },
})
```

This sketch does not show untracked files for the `uncommitted` scope.

## Lua API

```lua
local prohub = require('prohub')

prohub.setup({ refresh_interval = 10000 })
prohub.open({ cwd = vim.fn.expand('~/code/shop') })
prohub.review('/Users/me/code/shop', { scope = 'unpushed' })
```

Each function returns `true` when it succeeds. When it fails, it returns `nil` and an error message, and it never throws. The errors are returned, not shown, so the caller decides how to report them.

- `prohub.setup(opts?)`: `opts` takes the options of [Configuration](#configuration). Every field is optional. Returns `true|nil, string?`.
- `prohub.open(opts?)`: opens the hub. `opts.cwd` is the directory the hub is opened from, and it defaults to the current directory. The rows appear after the function returns. Returns `true|nil, string?`.
- `prohub.review(path, opts?)`: opens the review of the worktree that holds `path`, an absolute path of a directory. `opts.scope` is the scope, and it defaults to `default_scope`. The review is open when the function returns `true`. Returns `true|nil, string?`.

## Health

`:checkhealth prohub` checks the requirements and the configuration:

- The Neovim version. It must be 0.10 or newer.
- The `git` version. It must be 2.36.0 or newer.
- The options. They must be valid.
- The diff viewer. For minifugit, the plugin must be installed, and Neovim must be 0.11 or newer.

The check reads no project and opens no window. A missing viewer, for example, is reported like this:

```
ERROR prohub: the minifugit diff viewer is not installed
ADVICE Install minifugit, or configure another diff viewer with the diff_viewer option.
```

prohub writes its diagnostic messages to the file `prohub.log`, in the directory that `:echo stdpath('log')` shows. Normal use writes little to it.

## Trying it from a worktree

`nvim_test.lua` adds its worktree to the runtime path, so you can run the plugin without installing it:

```sh
nvim -u nvim_test.lua
```

Run the tests with `just test` and check the formatting with `just format-check`.

## Documentation

- `GLOSSARY.md` defines the vocabulary used in the code and the docs.
- `docs/adr/` records the decisions that are hard to reverse.
- `CODING_STANDARDS.md` and `AGENTS.md` describe how to contribute.
- `:help prohub` shows this document in Neovim, from `doc/prohub.txt`.

## License

GPL-3.0. See `LICENSE`.
