# Coding standards

These standards apply to all project changes.

## Project shape

- Keep the public `prohub` entrypoints thin and move behavior into focused modules.
- Separate data collection, formatting, and UI rendering. A good default flow is: git/process output -> parsed data -> renderable lines -> buffer/window updates.
- Prefer small single-purpose modules over catch-all utility files.
- Model stateful UI pieces as table-based objects with `__index`; keep pure transforms and parsers as local helper functions or stateless modules.
- Diff viewers are adapters behind one small interface. Keep viewer-specific code inside its adapter and never draw diffs in prohub itself.

## Lua style

- Follow the repo's Stylua rules (`.stylua.toml`): 4 spaces, 80-column width, Unix line endings, always-parenthesized calls, and a preference for single quotes.
- Use LuaLS annotations for non-trivial modules and APIs: `---@class`, `---@field`, `---@alias`, `---@param`, and `---@return`.
- Default to `local` functions and locals; only export what is part of a module API.
- Prefer early returns and explicit `nil` handling over deeply nested conditionals.
- Validate option tables and constructor inputs with `vim.validate` in its table form, `vim.validate({ name = { value, 'type', optional } })`, because Neovim 0.10 supports no other. Public functions catch the error and return `nil, err`.

## Neovim API usage

- Prefer the Lua Neovim API (`vim.api`, `vim.fn`, `vim.system`) over stringly Vimscript-style code when a Lua API exists.
- Centralize shell/process interactions instead of spawning ad hoc commands from multiple places. Git access goes through one shared helper.
- Every git call receives the worktree path explicitly. Never rely on the editor's current directory, because the hub and several reviews can be open at the same time with different working directories.
- Run git asynchronously (`vim.system` with a callback) for anything triggered by a timer or an autocmd, and apply results to buffers only from the main loop.
- Keep render steps side-effect free until the final buffer/window apply step.
- Reuse existing editor highlight groups first, then provide sensible fallback colors.

## Public API

- Public functions that can fail for expected reasons return `true` or `nil, err`. They never throw for those reasons. Test helpers under `tests/helpers/` are not plugin API: they raise on failure, so that a broken fixture fails the spec.
- Use logging through `prohub.log` for plugin-internal diagnostics. Use `vim.notify` only for failures the user can act on, and put everything else in the log or in `:checkhealth prohub`.

## Good practices

- Keep parsing and formatting logic deterministic and easy to inspect from plain strings/tables.
- Preserve compatibility assumptions: Neovim 0.10+ and a `git` executable that supports `worktree list --porcelain`.
- For UI or git changes, validate against realistic repository states such as modified, untracked, renamed, conflicted, detached HEAD, prunable, and bare worktrees when relevant.
- When creating commits, use the conventional-commit style (`feat:`, `fix:`, `refactor:`, `style:`, `chore:`).
