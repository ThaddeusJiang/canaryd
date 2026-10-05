# 012 Forgotten Workspace Cleanup

Under ordinary Data-volume pressure, reclaim redundant checkout directories
without stopping current builds or changing VCS registration. The manual
`canaryd clean` command applies the same checks. The emergency round also uses
these checks for workspaces; its relaxed build-output age does not apply to
checkout directories.

## Eligibility

- A JJ candidate is a direct child of `_jj_workspaces` in a colocated JJ/Git
  repository. Its `.jj/repo` pointer must refer to the parent repository, and
  `jj workspace list` must not contain its absolute path. The command reads the
  current operation without snapshotting a working copy, uses a stable path
  template, and must succeed with every listed root resolved.
- A Git candidate has a `.git` file pointing to a missing
  `<repository>/.git/worktrees/<name>` registration. Existing registrations are
  retained. Candidates are discovered only under the current user's home
  development roots.
- The checkout's tracked files must exactly match the parent Git repository's
  current `HEAD`. Only recognized build cache paths and the checkout's own VCS
  marker may be extra. An unknown ignored or untracked file, a nested Git/JJ
  repository, a symlink, a different filesystem, or incomplete inspection
  retains the whole checkout.
- Every entry must be older than the configured build retention, default 24
  hours. Current-user process executable paths and working directories must
  not refer to the checkout. Inspection failures retain it.
- Identity, registration, content, age, and process activity are checked again
  immediately before removal under the native cleanup lock.

## Exclusions

Canaryd does not unregister workspaces, prune Git metadata, remove registered
checkouts, infer completion from a merged PR or branch ancestry, or delete
unique source and user files. A forgotten directory containing an independent
repository is not a checkout of its parent and remains untouched.

## Acceptance

- An old, unregistered checkout with content identical to repository `HEAD`
  is removed while its parent repository remains.
- A checkout with unique files, a nested repository, an active process, or
  unresolved VCS state is retained.
- An unrelated Cargo build may continue while an idle old target is removed;
  a build using the target protects it.
