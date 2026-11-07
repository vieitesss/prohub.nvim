# Git is the only source of truth about worktrees

prohub reads everything it shows from git: the worktrees come from `git worktree list --porcelain`, the counts and the ahead/behind figures come from `git status` and `git rev-list`, and the changes of each scope come from git diffs. It does not read or write any record of who created a worktree, why, or what is running in it. Because of that, prohub works on any worktree, however it was created, and it has no state of its own to keep in sync with the repository.

The trade-off is that prohub cannot show richer per-worktree information. Anything beyond what git knows has to be handled by other code, which can still drive prohub through its public API (`require('prohub').open()` and `require('prohub').review(path, opts)`).
