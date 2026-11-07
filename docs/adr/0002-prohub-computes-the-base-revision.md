# prohub computes the base revision and the diff viewer only receives it

Every scope except `uncommitted` is a diff from some base revision to the worktree: the merge-base with the default branch for session changes, and the merge-base with the remote counterpart for unpushed changes. prohub computes that revision itself, from git, each time it opens a review or refreshes the hub, and passes it to the diff viewer as a plain revision. The diff viewer only needs to know how to show "the changes since this revision". It does not know about branches, default branches or remotes.

We chose this over letting each diff viewer decide what a scope means, because the meaning of a scope must be the same whichever viewer is configured, and because it keeps the viewer interface small (a revision and a worktree path), which makes writing a new adapter cheap. The base is not stored anywhere: if the default branch moves, the next refresh produces a new base.
