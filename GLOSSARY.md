# prohub.nvim

A Neovim plugin that shows the worktrees of a project in one buffer and opens a review of the one the user picks, using an existing diff viewer. It only knows about git.

## Language

**Project**:
All worktrees of one git repository.
_Avoid_: Repo, workspace

**Worktree**:
A working directory of a project, either its main checkout or a linked one, as listed by `git worktree list`.
_Avoid_: Checkout, branch, session

**Workset**:
A user-configured list of worktrees that the hub shows when it is opened outside a git repository, chosen by the directory it is opened from. Each entry is exactly one worktree.
_Avoid_: Workspace, collection

**Hub**:
The buffer that lists the worktrees of one project or one workset, one row per worktree, and from which a review is opened.
_Avoid_: Dashboard, picker

**Base**:
The commit where the branch under review left the project's default branch.
_Avoid_: Target, parent

**Session changes**:
Everything that differs between the base and a worktree, including new files git does not track yet.
_Avoid_: Diff, changeset

**Review**:
A diff viewer opened on one worktree, in its own tab, showing the changes of one scope.
_Avoid_: Diff, inspection

**Unpushed changes**:
Everything that differs between the point where a branch last matched its remote counterpart and the worktree, including uncommitted changes and new files git does not track yet. A branch with no remote counterpart has the same unpushed changes as session changes.
_Avoid_: Local changes, unsynced

**Scope**:
Which changes a review shows: session changes, unpushed changes, or uncommitted changes.
_Avoid_: Mode, range

**Diff viewer**:
An existing plugin that draws a review; minifugit by default. prohub never draws diffs itself.
_Avoid_: Engine, backend
