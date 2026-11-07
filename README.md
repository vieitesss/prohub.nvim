# prohub.nvim

A Neovim plugin that shows the worktrees of a git project in one buffer, the hub, and opens a review of the worktree you pick in an existing diff viewer. It only knows about git.

> **Status:** work in progress. The hub and the reviews are not implemented yet.

## Requirements

- Neovim 0.10 or newer.
- `git` with support for `git worktree list --porcelain`.
- A diff viewer. The default one is [minifugit.nvim](https://github.com/vieitesss/minifugit.nvim).

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

## License

GPL-3.0. See `LICENSE`.
