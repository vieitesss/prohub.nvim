## About the plugin

prohub.nvim is a Neovim plugin, written in Lua, that shows the worktrees of a git project in one buffer (the hub) and opens a review of the worktree the user picks, using an existing diff viewer. It only knows about git.

## Domain language

- Use the terms defined in `GLOSSARY.md` in code, tests, docs and commit messages, and avoid the words it lists under _Avoid_.
- Decisions that are hard to reverse are recorded in `docs/adr/`. Read them before changing the architecture.

## Tests

- Use `plenary.nvim` for creating and managing tests.
- Get information about how to create tests from this URL: https://raw.githubusercontent.com/nvim-lua/plenary.nvim/refs/heads/master/TESTS_README.md
- There should be:
    - Functional tests: only for functions that are part of each module's API. Do NOT create tests for local functions.
    - UI tests: check whether windows and tabpages are created and deleted correctly, ensuring the UI is shown as expected during and after the execution of the plugin.
- Use temporary directories as git repositories for testing, do not use real repositories. Cover a repository with several linked worktrees and a bare layout.

## Formatting

Use `stylua` for formatting.

---

For coding standards, structure, and project practices, see `CODING_STANDARDS.md`.
