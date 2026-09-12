# 009 Stale Build Cleanup

Daily cleanup specification for stale Xcode/Rust artifacts and orphaned Bazel output bases.

## Purpose

Reclaim disk space from reproducible build outputs without deleting source,
archives, developer credentials, Simulator data, or active build artifacts.

## Scope

- In scope:
  - Direct children of `~/Library/Developer/Xcode/DerivedData`.
  - Cargo target directories below the current user's local development
    directories.
  - Bazel output bases under `~/Library/Caches/bazel/_bazel_*` whose recorded
    local workspace no longer exists.
  - A daily launchd calendar schedule at 04:00 local time.
  - A manual `canaryd clean` command.
  - Local event history with counts, reclaimed bytes, and bounded skip reasons.
- Out of scope:
  - Xcode Archives, DeviceSupport, SDKs, UserData, signing identities, and
    certificates.
  - Simulator devices, runtimes, and application data.
  - Cargo registry, git cache, installed binaries, and source files.
  - Build outputs outside the current user's home directory.
  - Bazel shared download/repository caches, install caches, custom output
    roots, and workspaces outside the home directory or `/private/tmp`.
  - Configurable retention periods or arbitrary cleanup paths.

## Discovery

- Xcode candidates are direct child directories of DerivedData. Canaryd never
  treats the DerivedData root itself as a deletion candidate.
- Rust candidates are directories containing both Cargo's standard
  `CACHEDIR.TAG` signature and `.rustc_info.json`.
- Rust discovery scans non-hidden top-level directories in the user's home and
  `~/.codex/worktrees` and `~/.codex/workspace-backups` when present. It does not follow symbolic links and
  prunes dependency, VCS, and unrelated cache directories.
- Bazel candidates are direct output-base directories with a regular
  `DO_NOT_BUILD_HERE` marker of at most 4 KiB. Its absolute normalized workspace
  path must hash to the output-base directory's MD5 name. The candidate must
  belong to the home directory's owner; no cache ancestor may be a symlink.
- A Bazel workspace is missing only after a no-symlink component walk returns
  `enoent` inside the home directory or `/private/tmp`. Other errors, existing
  non-directory entries, dangling symlinks, and unsupported roots retain it.
- A missing or unreadable root is skipped without widening the search.
- Cargo discovery stays on the runtime home filesystem, including at each
  scan root and nested directory. NFS/virtual mounts such as `~/OrbStack` are
  not entered; a stalled container mount must not block local backup cleanup.
- Backup discovery removes only validated Cargo build directories. Backup
  containers, archives, unmerged changes, development data, test evidence, and
  sibling source files are not deletion candidates. Backups use the same full
  seven-day tree retention and active Rust process checks as live projects.
- Revalidate backup path ancestry, markers, tree age, and processes immediately
  before removal. A symlink at any component below the runtime home blocks
  backup discovery and deletion. Remove artifacts incrementally without
  retaining a list of every removed file; only owned directory modes may change.

## Retention and Safety

1. Retain an Xcode/Cargo candidate when the directory or any descendant was modified less
   than seven days ago.
2. Delete an Xcode/Cargo candidate only when every entry in its tree is at least seven days
   old.
3. Skip all Xcode candidates while a current-user `Xcode`, `Simulator`,
   `xcodebuild`, or `xctest` process is active.
4. Skip all Rust candidates while a current-user `cargo` or `rustc` process is
   active.
5. If process inspection is unavailable, delete nothing.
6. Recheck the relevant process class immediately before each deletion.
7. Never follow a symbolic link while discovering, measuring, or deleting a
   candidate.
8. Use a dedicated native exclusive lock so manual and scheduled cleanup
   cannot run concurrently. The lock file may remain on disk; only a live
   holder blocks cleanup. Process termination releases the lock automatically,
   and abandoned lock files from older versions do not block future runs.
9. Bazel orphan cleanup has no age threshold. An existing workspace always
   retains its output base, regardless of cache age.
10. A starting `bazel` or `bazelisk` client blocks the Bazel category. A resident
    named Bazel server protects its own output base via server PID and native lock
    checks; it does not block unrelated orphan cleanup. Missing PID files alone
    do not establish safety; malformed or symlinked server state retains the cache.
11. Each Bazel candidate gets fresh process inspection and workspace validation
    after measurement, after acquiring its native cache lock, and again after
    read-only directory preparation, immediately before removal. The Bazel PID snapshot is limited to five seconds and 8 MiB;
    failures and malformed output fail closed. Lock acquisition is nonblocking, with a five-second helper startup deadline.
    The existing regular `lock` file must be acquired exclusively with macOS `lockf`, without creating or replacing
    it. A missing, symlinked, changed, or busy lock retains the cache.
12. Only owned directories gain owner read/write/search permission when required
    to remove Bazel's read-only runfiles. File modes are never changed, including
    hard-linked artifacts. Symlink targets remain untouched.
13. The native lock protects against concurrent Bazel clients using the same
    lock file. Workspace recreation and filesystem changes by unrelated programs
    remain best-effort observations, not an atomic filesystem transaction.

## Behavior

1. At 04:00 local time, launchd runs `canaryd clean`.
2. Installing the calendar agent does not immediately run cleanup.
3. Canaryd discovers validated candidates within the fixed safe roots.
4. Canaryd checks current-user build processes and the full candidate tree
   activity before deletion.
5. Canaryd measures candidate bytes without following symbolic links.
6. Canaryd removes only validated stale Xcode/Cargo candidates or idle Bazel
   candidates with a missing local workspace.
7. Canaryd prints removed paths, reclaimed bytes, skips, and failures to its
   local launchd log.
8. Canaryd records one `builds` history event containing counts, estimated reclaimed
   bytes, and bounded reasons including `bazel_skip`. Paths are not persisted in DETS.

## BDD Scenarios

### BDD-01 Remove stale reproducible outputs

Given:
- A DerivedData child and a validated Cargo target have no modification in the
  last seven days.
- No protected build process is active.

When:
- The cleanup command runs.

Then:
- Canaryd removes both candidate directories.
- Canaryd reports their paths and reclaimed bytes.
- Source and every out-of-scope location remain unchanged.

### BDD-02 Retain recent or unverifiable data

Given:
- A candidate contains a recently modified descendant, is a symbolic link, or
  lacks the Cargo markers.

When:
- The cleanup command runs.

Then:
- Canaryd does not remove that path.

### BDD-03 Protect active builds

Given:
- A protected Xcode or Rust build process is active, or process inspection is
  unavailable.

When:
- The cleanup command runs.

Then:
- Canaryd skips the affected build class, or all cleanup when inspection is
  unavailable.
- Canaryd records the bounded skip reason.

### BDD-04 Run once daily at 04:00

Given:
- Canaryd installs or self-heals its launchd configuration.

When:
- The launchd agents are rendered.

Then:
- The full health check retains its five-minute interval.
- A separate build-cleanup agent uses `StartCalendarInterval` with hour 4 and
  minute 0.
- The build-cleanup agent does not use `RunAtLoad`.

### BDD-05 Remove orphaned Bazel caches

Given a valid Bazel output base records a missing local workspace, when the
cleanup runs with no activity in that cache, then the output base is removed
regardless of age. Existing workspaces and shared download/install caches stay.

### BDD-06 Retain busy or unverifiable Bazel caches

Given an output base has a live server PID, a held native lock, malformed server
state, a symlinked/malformed marker, or an unsupported workspace root, then it is
retained. Failure to inspect processes retains the category. A resident server
in another output base does not prevent removal of an unrelated orphan.

### BDD-07 Revalidate and handle read-only artifacts

Given a workspace reappears or cache activity begins during inspection, then
removal is skipped. Otherwise read-only runfiles directories can be removed,
while symlink targets and modes of hard-linked files outside the cache stay intact.

## Acceptance Evidence

- `Canaryd.BuildCleanupTest` candidate, retention, process protection, lock,
  and deletion tests.
- `Canaryd.BazelCacheTest` identity, path boundaries, server state, native lock exclusion/release, process-output parsing, command output
  bounds, and timeout tests.
- `Canaryd.SetupTest` interval and calendar schedule tests.
- `Canaryd.RuntimePathsTest` clean-command deletion and bounded history event.
- Relevant CLI, runtime path, naming convention, and full test suite checks.

## Cross-Spec Links

- [003 Thermal Process Monitor](./003-thermal-process-monitor.md)
- [005 Time Unit Convention](./005-time-unit-convention.md)
- [008 Idle Simulator Shutdown](./008-idle-simulator-shutdown.md)

### BDD-08 Remove only stale build artifacts from workspace backups

Given:
- A Codex workspace backup contains a validated Cargo target untouched for
  seven days alongside unmerged changes, an archive, and recent build output.
- No protected Rust process is active.

When:
- The daily `canaryd clean` run discovers its default roots.

Then:
- Only the stale target is removed; the backup and other files remain.
- Active builds, recent descendants, symlinked ancestors, and an ancestry
  change during revalidation prevent deletion.
- Read-only build directories can be removed without changing the permissions
  or content of shared artifact hard links outside the candidate.

Acceptance: `Canaryd.BuildCleanupTest` backup discovery, retention, process,
ancestry, read-only directory, and hard-link scenarios; `Canaryd.RuntimePathsTest`
CLI cleanup and bounded history integration; `Canaryd.SetupTest` daily schedule.
